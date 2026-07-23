# frozen_string_literal: true

require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require_relative '../lib/trading_logic'
require 'securerandom'
require 'time'
require 'json'
require 'fileutils'
require 'logger'
require_relative '../lib/strategy_helpers'

log_level_name = ENV.fetch('LOG_LEVEL', 'DEBUG').upcase
log_level = Logger.const_defined?(log_level_name) ? Logger.const_get(log_level_name) : Logger::DEBUG

LOGGER = Logger.new($stdout)
LOGGER.level = log_level
LOGGER.formatter = proc do |severity, _datetime, _progname, message|
  "#{severity}: #{message}\n"
end

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
DAY = Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY

USE_LEVELS           = ENV.fetch('USE_LEVELS', '1').strip != '0'
LEVELS_LOOKBACK_DAYS = (ENV['LEVELS_LOOKBACK_DAYS'] || '120').to_i
LEVEL_PROXIMITY_PCT  = (ENV['LEVEL_PROXIMITY_PCT'] || '0.02').to_f
LEVEL_SELL_MIN_PROFIT = (ENV['LEVEL_SELL_MIN_PROFIT'] || '1.005').to_f
LEVEL_PIVOT_WINDOW   = (ENV['LEVEL_PIVOT_WINDOW'] || '5').to_i
LEVEL_CLUSTER_PCT    = (ENV['LEVEL_CLUSTER_PCT'] || '0.015').to_f

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
  telegram_bot_token: ENV.fetch('TELEGRAM_BOT_TOKEN', nil),
  telegram_chat_id: ENV.fetch('TELEGRAM_CHAT_ID', nil),
  use_levels: USE_LEVELS,
  levels_lookback_days: LEVELS_LOOKBACK_DAYS,
  level_proximity_pct: LEVEL_PROXIMITY_PCT,
  level_sell_min_profit: LEVEL_SELL_MIN_PROFIT,
  level_pivot_window: LEVEL_PIVOT_WINDOW,
  level_cluster_pct: LEVEL_CLUSTER_PCT
)

STATE_PATH = File.expand_path('../tmp/strategy_state.json', __dir__)
FileUtils.mkdir_p(File.dirname(STATE_PATH))

MARKET_CACHE_PATH = File.expand_path('../tmp/market_instruments_cache.json', __dir__)
MOEX_INDEX_CACHE_PATH = File.expand_path('../tmp/moex_index_cache.json', __dir__)

begin
  accounts = client.grpc_users.accounts
  account_id = accounts.accounts.first.id or abort('no accounts')

  # Индекс IMOEX: приоритетно через Indicatives (UID индекса — свечи по instrument_id).
  # Индексы не отдаются last_prices и не имеют торгуемого figi, поэтому UID обязателен.
  index_uid = logic.resolve_index_uid(ticker: ENV.fetch('INDEX_TICKER', 'IMOEX'))
  LOGGER.debug("index_uid=#{index_uid.inspect}")

  # Fallback на figi ETF-прокси (TMOS/SBMX), если UID индекса недоступен.
  index_figi = nil
  if index_uid.nil?
    index_figi = %w[TMOS SBMX].lazy.map do |ticker|
      r = client.grpc_instruments.find_instrument(query: ticker)
      r.instruments.first&.figi
    rescue InvestTinkoff::GRPC::Error
      nil
    end.find(&:itself)
    LOGGER.debug("index UID unavailable — using proxy figi=#{index_figi.inspect}")
  end

  index_closes = logic.index_daily_closes(figi: index_figi, instrument_id: index_uid)
  index_value = index_closes.last
  LOGGER.debug("index_value=#{index_value.inspect} (closes=#{index_closes.size})")

  trend = logic.trend_from_closes(index_closes)
  LOGGER.debug("trend=#{trend.inspect}")
  LOGGER.warn('index closes < 4 — trend UNKNOWN; проверь резолв индекса (rake index:check)') if index_closes.size < 4

  universe = logic.rank_universe_by_volume(logic.build_universe)
  LOGGER.debug("universe (count=#{universe.size}):")
  universe.each do |u|
    LOGGER.debug(format(
                   '  - %-6s  price=%8.2f  lot=%3d  price_per_lot=%8.2f  rvol=%5.2f  turnover=%12.0f',
                   u[:ticker] || '',
                   u[:price] || 0.0,
                   u[:lot] || 0,
                   u[:price_per_lot] || 0.0,
                   u[:relative_volume] || 0.0,
                   u[:daily_turnover_rub] || 0.0
                 ))
  end
  LOGGER.info("no buy instruments under limit: max_lot_rub=#{MAX_LOT_RUB}, lots_per_order=#{LOTS_PER_ORDER}") if universe.empty?

  if USE_LEVELS
    LOGGER.debug("levels (lookback=#{LEVELS_LOOKBACK_DAYS}d, proximity=#{(LEVEL_PROXIMITY_PCT * 100).round(1)}%):")
    universe.each do |u|
      LOGGER.debug("  - #{u[:ticker]}: #{logic.level_debug_info(u[:figi], u[:price])}")
    end
  end

  figi_cache = TradingLogic::StrategyHelpers.build_figi_ticker_map(MARKET_CACHE_PATH)

  state = TradingLogic::StrategyHelpers.load_state(STATE_PATH)
  TradingLogic::StrategyHelpers.cleanup_pending_orders!(client, account_id, state, logger: LOGGER)
  if ENV.fetch('RESTORE_STATE_FROM_BROKER', '1').to_s.strip.downcase != '0'
    TradingLogic::StrategyHelpers.restore_state_from_broker_if_empty!(client, account_id, state, logger: LOGGER)
  end

  # Принудительная продажа всех лотов при профите >= +10% (до основной логики)
  begin
    TradingLogic::StrategyHelpers.try_force_exit_positions_with_logic!(
      client, logic, account_id, figi_cache: figi_cache, logger: LOGGER
    )
  rescue InvestTinkoff::GRPC::Error => e
    LOGGER.error("Force exit gRPC error: #{e.class} #{e.message}")
  end

  case trend
  when :up
    LOGGER.info('Trend: UP — intraday dip BUY (max once per ticker per day)')
    up_portfolio = client.grpc_operations.portfolio(account_id: account_id)
    universe.each do |it|
      cur = logic.last_price_for(it[:figi])
      today_high = begin
        logic.today_high(it[:figi])
      rescue StandardError
        nil
      end
      dip_thr = today_high ? (today_high * (1.0 - DIP_PCT)) : nil
      it_live = cur ? it.merge(price: cur) : it
      LOGGER.debug("#{it[:ticker]} cur=#{cur.inspect} today_high=#{today_high.inspect} " \
                   "dip_threshold=#{dip_thr.inspect} should_buy=#{logic.should_buy?(it_live, trend: trend)}")
      next if TradingLogic::StrategyHelpers.acted_today?(state, 'last_buy', it[:ticker])
      next if TradingLogic::StrategyHelpers.pending_order_active?(state, it[:ticker])
      next unless logic.should_buy?(it_live, trend: trend)

      buy_value = (cur || it[:price]) * it[:lot] * LOTS_PER_ORDER
      next unless TradingLogic::StrategyHelpers.position_within_limit?(
        client, account_id, it[:figi],
        planned_buy_value: buy_value, portfolio: up_portfolio, logger: LOGGER
      )

      result = logic.confirm_and_place_order_with_result(
        account_id: account_id,
        figi: it[:figi],
        quantity: LOTS_PER_ORDER, # в ЛОТАХ, не в штуках
        price: cur || it[:price],
        direction: Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY,
        order_type: Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      result[:figi] ||= it[:figi]
      TradingLogic::StrategyHelpers.sync_pending_order!(state, it[:ticker], result)

      if TradingLogic::StrategyHelpers.buy_execution_result?(result)
        resp = result[:response]
        LOGGER.info(
          "BUY #{it[:ticker]} lots=#{LOTS_PER_ORDER} lot_size=#{it[:lot]} " \
          "@#{it[:price]} category=#{result[:category]} (order_id=#{resp&.order_id})"
        )
        TradingLogic::StrategyHelpers.mark_action!(state, 'last_buy', it[:ticker])
      else
        LOGGER.info(TradingLogic::StrategyHelpers.buy_failure_message(it[:ticker], result))
      end
    end

  when :down
    sell_pct = ((logic.sell_threshold_for_trend(:down) - 1) * 100).round(1)
    LOGGER.info("Trend: DOWN — SELL one lot if >= avg * +#{sell_pct}% (max once per ticker per day)")
    port = client.grpc_operations.portfolio(account_id: account_id)
    positions = port.positions

    universe.each do |it|
      ticker = TradingLogic::StrategyHelpers.resolve_ticker_for_sell(
        client, figi: it[:figi], fallback_ticker: it[:ticker], figi_cache: figi_cache, logger: LOGGER
      )
      unless ticker
        LOGGER.debug("SELL ticker resolution failed payload=#{it.to_json}")
        next
      end

      next if TradingLogic::StrategyHelpers.acted_today?(state, 'last_sell', ticker)

      p = positions.find { |pos| pos.figi == it[:figi] }
      next unless p

      qty_units = p.quantity.units.to_i
      next if qty_units <= 0

      sell_it = it.merge(ticker: ticker)
      next unless logic.should_sell?(p, sell_it, trend: trend)

      # Продаём один лот. quantity в ЛОТАХ; ограничиваем числом удерживаемых лотов.
      lot_size = [it[:lot].to_i, 1].max
      lots_held = qty_units / lot_size
      sell_qty = [1, lots_held].min
      next if sell_qty <= 0

      resp = logic.confirm_and_place_order(
        account_id: account_id,
        figi: it[:figi],
        quantity: sell_qty,
        price: logic.last_price_for(it[:figi]),
        direction: Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
        order_type: Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      if resp
        LOGGER.info("SELL #{ticker} lots=#{sell_qty} (order_id=#{resp.order_id})")
        TradingLogic::StrategyHelpers.mark_action!(state, 'last_sell', ticker, figi: it[:figi], reason: 'signal')
      else
        LOGGER.info("SELL #{ticker} skipped / not confirmed")
      end
    end
    # доп. проход по позициям, чтобы учесть бумаги вне исходного TICKERS
    TradingLogic::StrategyHelpers.try_sell_positions_with_logic!(
      client, logic, account_id, state, figi_cache: figi_cache, trend: trend, logger: LOGGER
    )
    # попытка одной покупки по сигналу "3 дневных закрытия вверх" из пересечения IMOEX∩market
    LOGGER.info('DOWN: try momentum(3D up) BUY one per day from IMOEX∩market')
    bought = TradingLogic::StrategyHelpers.buy_one_momentum_from_intersection!(
      client, logic, state,
      market_cache_path: MARKET_CACHE_PATH,
      moex_index_cache_path: MOEX_INDEX_CACHE_PATH,
      max_lot_rub: MAX_LOT_RUB,
      lots_per_order: LOTS_PER_ORDER,
      account_id: account_id,
      logger: LOGGER
    )
    LOGGER.info('DOWN: no momentum candidates') unless bought

  when :unknown
    # Нет/мало данных по индексу — не путаем с боковиком. Новые покупки запрещаем,
    # защитные продажи (в т.ч. force-exit выше) оставляем.
    LOGGER.warn('Trend: UNKNOWN (нет данных по индексу) — только защитные продажи, без новых покупок')
    TradingLogic::StrategyHelpers.try_sell_positions_with_logic!(
      client, logic, account_id, state, figi_cache: figi_cache, trend: :side, logger: LOGGER
    )

  else
    LOGGER.info('Trend: SIDE — SELL by same rules, and try momentum(3D up) BUY one per day')
    TradingLogic::StrategyHelpers.try_sell_positions_with_logic!(
      client, logic, account_id, state, figi_cache: figi_cache, trend: trend, logger: LOGGER
    )
    bought = TradingLogic::StrategyHelpers.buy_one_momentum_from_intersection!(
      client, logic, state,
      market_cache_path: MARKET_CACHE_PATH,
      moex_index_cache_path: MOEX_INDEX_CACHE_PATH,
      max_lot_rub: MAX_LOT_RUB,
      lots_per_order: LOTS_PER_ORDER,
      account_id: account_id,
      logger: LOGGER
    )
    LOGGER.info('SIDE: no momentum candidates') unless bought
  end

  TradingLogic::StrategyHelpers.check_sell_consistency!(client, account_id, state, logger: LOGGER)
  TradingLogic::StrategyHelpers.save_state(STATE_PATH, state)

  LOGGER.debug('---')
rescue InvestTinkoff::GRPC::Error => e
  LOGGER.error("gRPC error: #{e.class} #{e.message}")
end
