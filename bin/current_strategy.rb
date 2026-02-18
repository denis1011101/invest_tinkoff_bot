require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require_relative '../lib/trading_logic'
require 'securerandom'
require 'time'
require 'json'
require 'fileutils'
require_relative '../lib/strategy_helpers'

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

# параметры стратегии
TICKERS = (ENV['TICKERS'] || 'SBER,ROSN,VTBR').split(',').map(&:strip)
MAX_LOT_RUB = (ENV['MAX_LOT_RUB'] || '1000.0').to_f
MAX_LOT_COUNT = (ENV['MAX_LOT_COUNT'] || '1').to_i
LOTS_PER_ORDER = (ENV['LOTS_PER_ORDER'] || '2').to_i
DIP_PCT = (ENV['DIP_PCT'] || '0.01').to_f
MIN_RELATIVE_VOLUME = ENV['MIN_RELATIVE_VOLUME']&.to_f
VOLUME_LOOKBACK_DAYS = (ENV['VOLUME_LOOKBACK_DAYS'] || '20').to_i
VOLUME_COMPARE_MODE = (ENV['VOLUME_COMPARE_MODE'] || 'none').strip
DAY = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY

logic = TradingLogic::Runner.new(
  client,
  tickers: TICKERS,
  max_lot_rub: MAX_LOT_RUB,
  max_lot_count: MAX_LOT_COUNT,
  lots_per_order: LOTS_PER_ORDER,
  dip_pct: DIP_PCT,
  min_relative_volume: MIN_RELATIVE_VOLUME,
  volume_lookback_days: VOLUME_LOOKBACK_DAYS,
  volume_compare_mode: VOLUME_COMPARE_MODE,
  telegram_bot_token: ENV['TELEGRAM_BOT_TOKEN'],
  telegram_chat_id: ENV['TELEGRAM_CHAT_ID']
)

STATE_PATH = File.expand_path('../tmp/strategy_state.json', __dir__)
FileUtils.mkdir_p(File.dirname(STATE_PATH))

MARKET_CACHE_PATH = File.expand_path('../tmp/market_instruments_cache.json', __dir__)
MOEX_INDEX_CACHE_PATH = File.expand_path('../tmp/moex_index_cache.json', __dir__)

begin
  accounts = client.grpc_users.accounts
  account_id = accounts.accounts.first.id or abort('no accounts')

  # Индекс IMOEX: пробуем найти напрямую, иначе TMOS/SBMX как прокси
  index_figi = begin
    resp = client.grpc_instruments.find_instrument(query: 'IMOEX')
    resp.instruments.first&.figi
  rescue InvestTinkoff::GRPC::Error
    nil
  end
  if index_figi.nil?
    index_figi = %w[TMOS SBMX].lazy.map { |ticker|
      begin
        r = client.grpc_instruments.find_instrument(query: ticker)
        r.instruments.first&.figi
      rescue InvestTinkoff::GRPC::Error
        nil
      end
    }.find(&:itself)
  end

  puts "DEBUG: index_figi=#{index_figi.inspect}"

  # numeric current index value
  index_value = index_figi ? logic.last_price_for(index_figi) : nil
  puts "DEBUG: index_value=#{index_value.inspect}"

  trend = logic.trend(index_figi)
  puts "DEBUG: trend=#{trend.inspect}"

  universe = logic.rank_universe_by_volume(logic.build_universe)
  puts "DEBUG: universe (count=#{universe.size}):"
  universe.each do |u|
    puts format(
      "  - %-6s  price=%8.2f  lot=%3d  price_per_lot=%8.2f  rvol=%5.2f  turnover=%12.0f",
      (u[:ticker] || ''),
      (u[:price] || 0.0),
      (u[:lot] || 0),
      (u[:price_per_lot] || 0.0),
      (u[:relative_volume] || 0.0),
      (u[:daily_turnover_rub] || 0.0)
    )
  end
  if universe.empty?
    puts "no instruments under limit: max_lot_rub=#{MAX_LOT_RUB}, lots_per_order=#{LOTS_PER_ORDER}"
    exit 0
  end

  figi_cache = TradingLogic::StrategyHelpers.build_figi_ticker_map(MARKET_CACHE_PATH)

  state = TradingLogic::StrategyHelpers.load_state(STATE_PATH)
  TradingLogic::StrategyHelpers.cleanup_pending_orders!(client, account_id, state)
  if ENV.fetch('RESTORE_STATE_FROM_BROKER', '1').to_s.strip.downcase != '0'
    TradingLogic::StrategyHelpers.restore_state_from_broker_if_empty!(client, account_id, state)
  end

  # Принудительная продажа всех лотов при профите >= +10% (до основной логики)
  begin
    port_force = client.grpc_operations.portfolio(account_id: account_id)
    positions_force = port_force.positions
    positions_map = positions_force.each_with_object({}) { |p, h| h[p.figi] = p }

    universe.each do |it|
      p = positions_map[it[:figi]] or next
      qty = p.quantity.units.to_i
      next if qty <= 0
      next unless logic.should_force_exit?(p, it[:figi])

      cur_price = logic.last_price_for(it[:figi])
      resp = logic.confirm_and_place_order(
        account_id: account_id,
        figi: it[:figi],
        quantity: qty, # продаём весь объём
        price: cur_price,
        direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
        order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      if resp
        puts "FORCE SELL +10% #{it[:ticker]} qty=#{qty} @#{cur_price} (order_id=#{resp.order_id})"
        # mark_action! не обязателен: позиция обнулится, повтор не пройдёт
      else
        puts "FORCE SELL #{it[:ticker]} skipped / not confirmed"
      end
    end
  rescue InvestTinkoff::GRPC::Error => e
    puts "Force exit gRPC error: #{e.class} #{e.message}"
  end

  case trend
  when :up
    puts 'Trend: UP — intraday dip BUY (max once per ticker per day)'
    up_portfolio = client.grpc_operations.portfolio(account_id: account_id)
    universe.each do |it|
      cur = logic.last_price_for(it[:figi])
      today_high = logic.today_high(it[:figi]) rescue nil
      puts "DEBUG: #{it[:ticker]} cur=#{cur.inspect} today_high=#{today_high.inspect} dip_threshold=#{(today_high ? (today_high * (1.0 - DIP_PCT)) : nil).inspect} should_buy=#{logic.should_buy?(it)}"
      next if TradingLogic::StrategyHelpers.acted_today?(state, 'last_buy', it[:ticker])
      next unless logic.should_buy?(it)

      buy_value = it[:price] * it[:lot] * LOTS_PER_ORDER
      next unless TradingLogic::StrategyHelpers.position_within_limit?(
        client, account_id, it[:figi],
        planned_buy_value: buy_value, portfolio: up_portfolio
      )

      resp = logic.confirm_and_place_order(
        account_id: account_id,
        figi: it[:figi],
        quantity: it[:lot] * LOTS_PER_ORDER,
        price: it[:price],
        direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY,
        order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      if resp
        puts "BUY #{it[:ticker]} lot=#{it[:lot]} @#{it[:price]} (order_id=#{resp.order_id})"
        TradingLogic::StrategyHelpers.mark_action!(state, 'last_buy', it[:ticker])
      else
        puts "BUY #{it[:ticker]} skipped / not confirmed"
      end
    end

  when :down
    sell_pct = ((logic.sell_threshold_for_trend(:down) - 1) * 100).round(1)
    puts "Trend: DOWN — SELL one lot if >= avg * +#{sell_pct}% (max once per ticker per day)"
    port = client.grpc_operations.portfolio(account_id: account_id)
    positions = port.positions

    universe.each do |it|
      ticker = TradingLogic::StrategyHelpers.resolve_ticker_for_sell(
        client, figi: it[:figi], fallback_ticker: it[:ticker], figi_cache: figi_cache
      )
      unless ticker
        warn "DEBUG: SELL ticker resolution failed payload=#{it.to_json}"
        next
      end

      next if TradingLogic::StrategyHelpers.acted_today?(state, 'last_sell', ticker)
      p = positions.find { |pos| pos.figi == it[:figi] }
      next unless p
      qty_units = p.quantity.units.to_i
      next if qty_units <= 0

      sell_it = it.merge(ticker: ticker)
      next unless logic.should_sell?(p, sell_it, trend: trend)

      sell_qty = [qty_units, it[:lot]].min
      resp = logic.confirm_and_place_order(
        account_id: account_id,
        figi: it[:figi],
        quantity: sell_qty,
        price: logic.last_price_for(it[:figi]),
        direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
        order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      if resp
        puts "SELL #{ticker} qty=#{sell_qty} (order_id=#{resp.order_id})"
        TradingLogic::StrategyHelpers.mark_action!(state, 'last_sell', ticker, figi: it[:figi], reason: 'signal')
      else
        puts "SELL #{ticker} skipped / not confirmed"
      end
    end
    # доп. проход по позициям, чтобы учесть бумаги вне исходного TICKERS
    TradingLogic::StrategyHelpers.try_sell_positions_with_logic!(
      client, logic, account_id, state, figi_cache: figi_cache, trend: trend
    )
    # попытка одной покупки по сигналу "3 дневных закрытия вверх" из пересечения IMOEX∩market
    puts 'DOWN: try momentum(3D up) BUY one per day from IMOEX∩market'
    bought = TradingLogic::StrategyHelpers.buy_one_momentum_from_intersection!(
      client, logic, state,
      market_cache_path: MARKET_CACHE_PATH,
      moex_index_cache_path: MOEX_INDEX_CACHE_PATH,
      max_lot_rub: MAX_LOT_RUB,
      lots_per_order: LOTS_PER_ORDER,
      account_id: account_id
    )
     puts 'DOWN: no momentum candidates' unless bought

  else
    puts 'Trend: SIDE — SELL by same rules, and try momentum(3D up) BUY one per day'
    TradingLogic::StrategyHelpers.try_sell_positions_with_logic!(
      client, logic, account_id, state, figi_cache: figi_cache, trend: trend
    )
    bought = TradingLogic::StrategyHelpers.buy_one_momentum_from_intersection!(
      client, logic, state,
      market_cache_path: MARKET_CACHE_PATH,
      moex_index_cache_path: MOEX_INDEX_CACHE_PATH,
      max_lot_rub: MAX_LOT_RUB,
      lots_per_order: LOTS_PER_ORDER,
      account_id: account_id
    )
     puts 'SIDE: no momentum candidates' unless bought
  end

  TradingLogic::StrategyHelpers.check_sell_consistency!(client, account_id, state)
  TradingLogic::StrategyHelpers.save_state(STATE_PATH, state)

  puts ''
rescue InvestTinkoff::GRPC::Error => e
  puts "gRPC error: #{e.class} #{e.message}"
end
