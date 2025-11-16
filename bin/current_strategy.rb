require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require_relative '../lib/trading_logic'
require 'securerandom'
require 'time'
require 'json'
require 'fileutils'
require_relative '../lib/strategy_helpers'
include TradingLogic::StrategyHelpers

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

# параметры стратегии
TICKERS = %w[SBER ROSN VTBR]
MAX_LOT_RUB = 500.0
MAX_LOT_COUNT = 1
DIP_PCT = 0.01
DAY = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY

logic = TradingLogic::Runner.new(
  client,
  tickers: TICKERS,
  max_lot_rub: MAX_LOT_RUB,
  max_lot_count: MAX_LOT_COUNT,
  dip_pct: DIP_PCT,
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

  universe = logic.build_universe
  puts "DEBUG: universe (count=#{universe.size}):"
  universe.each do |u|
    puts format("  - %-6s  price=%8.2f  lot=%3d  price_per_lot=%8.2f", (u[:ticker] || ''), (u[:price] || 0.0), (u[:lot] || 0), (u[:price_per_lot] || 0.0))
  end
  if universe.empty?
    puts 'no instruments under 1000 RUB per lot'
    exit 0
  end

  state = load_state(STATE_PATH)

  # Принудительная продажа всех лотов при профите >= +30% (до основной логики)
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
        puts "FORCE SELL +30% #{it[:ticker]} qty=#{qty} @#{cur_price} (order_id=#{resp.order_id})"
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
    universe.each do |it|
      cur = logic.last_price_for(it[:figi])
      today_high = logic.today_high(it[:figi]) rescue nil
      puts "DEBUG: #{it[:ticker]} cur=#{cur.inspect} today_high=#{today_high.inspect} dip_threshold=#{(today_high ? (today_high * (1.0 - DIP_PCT)) : nil).inspect} should_buy=#{logic.should_buy?(it)}"
      next if acted_today?(state, 'last_buy', it[:ticker])
      next unless logic.should_buy?(it)

      resp = logic.confirm_and_place_order(
        account_id: account_id,
        figi: it[:figi],
        quantity: it[:lot],
        price: it[:price],
        direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY,
        order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      if resp
        puts "BUY #{it[:ticker]} lot=#{it[:lot]} @#{it[:price]} (order_id=#{resp.order_id})"
        mark_action!(state, 'last_buy', it[:ticker])
      else
        puts "BUY #{it[:ticker]} skipped / not confirmed"
      end
    end

  when :down
    puts 'Trend: DOWN — SELL one lot if >= avg * 1.10 (max once per ticker per day)'
    port = client.grpc_operations.portfolio(account_id: account_id)
    positions = port.positions

    universe.each do |it|
      next if acted_today?(state, 'last_sell', it[:ticker])
      p = positions.find { |pos| pos.figi == it[:figi] }
      next unless p
      qty_units = p.quantity.units.to_i
      next if qty_units <= 0
      next unless logic.should_sell?(p, it)

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
        puts "SELL #{it[:ticker]} qty=#{sell_qty} (order_id=#{resp.order_id})"
        mark_action!(state, 'last_sell', it[:ticker])
      else
        puts "SELL #{it[:ticker]} skipped / not confirmed"
      end
    end
    # доп. проход по позициям, чтобы учесть бумаги вне исходного TICKERS
    try_sell_positions_with_logic!(client, logic, account_id, state)
    # попытка одной покупки по сигналу "3 дневных закрытия вверх" из пересечения IMOEX∩market
    puts 'DOWN: try momentum(3D up) BUY one per day from IMOEX∩market'
    bought = TradingLogic::StrategyHelpers.buy_one_momentum_from_intersection!(
      client, logic, state,
      market_cache_path: MARKET_CACHE_PATH,
      moex_index_cache_path: MOEX_INDEX_CACHE_PATH,
      max_lot_rub: MAX_LOT_RUB,
      account_id: account_id
    )
     puts 'DOWN: no momentum candidates' unless bought

  else
    puts 'Trend: SIDE — SELL by same rules, and try momentum(3D up) BUY one per day'
    try_sell_positions_with_logic!(client, logic, account_id, state)
    bought = TradingLogic::StrategyHelpers.buy_one_momentum_from_intersection!(
      client, logic, state,
      market_cache_path: MARKET_CACHE_PATH,
      moex_index_cache_path: MOEX_INDEX_CACHE_PATH,
      max_lot_rub: MAX_LOT_RUB,
      account_id: account_id
    )
     puts 'SIDE: no momentum candidates' unless bought
  end

  save_state(STATE_PATH, state)

  puts ''
rescue InvestTinkoff::GRPC::Error => e
  puts "gRPC error: #{e.class} #{e.message}"
end
