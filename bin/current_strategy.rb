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
LOGGER.formatter = proc do |severity, datetime, _progname, message|
  "#{datetime.utc.iso8601} #{severity}: #{message}\n"
end

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

# параметры стратегии
TICKERS = (ENV['TICKERS'] || 'SBER,ROSN,VTBR').split(',').map(&:strip)
# Универсум растущего тренда. Раньше UP торговал теми же 3 бумагами, что и всё
# остальное, тогда как SIDE/DOWN работали по всему IMOEX∩Tinkoff — бот системно
# недоинвестировал именно в благоприятном тренде (24.07 и 27.07.2026: два UP-дня,
# ноль сделок). Список курируемый: ликвидные бумаги индекса, без расписок и новых
# размещений. Пусто → падаем на TICKERS.
UP_TICKERS = (ENV['UP_TICKERS'] || '').split(',').map(&:strip).reject(&:empty?)
UP_UNIVERSE = UP_TICKERS.empty? ? TICKERS : UP_TICKERS
MAX_LOT_RUB = (ENV['MAX_LOT_RUB'] || '1000.0').to_f
# 0/пусто — ограничитель выключен (рублёвого потолка MAX_LOT_RUB достаточно).
MAX_LOT_COUNT = (ENV['MAX_LOT_COUNT'] || '0').to_i
LOTS_PER_ORDER = (ENV['LOTS_PER_ORDER'] || '2').to_i
DIP_PCT = (ENV['DIP_PCT'] || '0.01').to_f
MIN_RELATIVE_VOLUME = ENV['MIN_RELATIVE_VOLUME']&.to_f
min_rvol_session_fraction = ENV.fetch('MIN_RVOL_SESSION_FRACTION', '').strip
MIN_RVOL_SESSION_FRACTION = if min_rvol_session_fraction.empty?
                              TradingLogic::Runner::MIN_SESSION_FRACTION
                            else
                              min_rvol_session_fraction.to_f
                            end
VOLUME_LOOKBACK_DAYS = (ENV['VOLUME_LOOKBACK_DAYS'] || '20').to_i
# Активное правило momentum-входа (MOMENTUM_RULE). Резолвим один раз при старте,
# чтобы неизвестное значение дало ровно одно предупреждение за прогон.
MOMENTUM_RULE = TradingLogic::StrategyHelpers.momentum_rule(logger: LOGGER)
VOLUME_COMPARE_MODE = (ENV['VOLUME_COMPARE_MODE'] || 'none').strip
DAY = Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY

USE_LEVELS           = ENV.fetch('USE_LEVELS', '1').strip != '0'
LEVELS_LOOKBACK_DAYS = (ENV['LEVELS_LOOKBACK_DAYS'] || '120').to_i
LEVEL_PROXIMITY_PCT  = (ENV['LEVEL_PROXIMITY_PCT'] || '0.02').to_f
LEVEL_SELL_MIN_PROFIT = (ENV['LEVEL_SELL_MIN_PROFIT'] || '1.005').to_f
LEVEL_PIVOT_WINDOW   = (ENV['LEVEL_PIVOT_WINDOW'] || '5').to_i
LEVEL_CLUSTER_PCT    = (ENV['LEVEL_CLUSTER_PCT'] || '0.015').to_f

# Вход в растущем тренде: near_support? заменён на «выше SMA и не у сопротивления».
# UP_REQUIRE_SUPPORT=1 возвращает прежнее поведение.
UP_REQUIRE_SUPPORT = ENV.fetch('UP_REQUIRE_SUPPORT', '0').strip == '1'
UP_ENTRY_MA_DAYS   = (ENV['UP_ENTRY_MA_DAYS'] || '5').to_i
# Shadow-режим: считаем и логируем сделки, но не отправляем ордера.
SHADOW_BUYS = ENV.fetch('SHADOW_BUYS', '0').strip == '1'
SCAN_ID = TradingLogic::StrategyHelpers.new_buy_scan_id
LOGGER.debug("scan_id=#{SCAN_ID}")

logic = TradingLogic::Runner.new(
  client,
  tickers: TICKERS,
  max_lot_rub: MAX_LOT_RUB,
  max_lot_count: MAX_LOT_COUNT,
  lots_per_order: LOTS_PER_ORDER,
  dip_pct: DIP_PCT,
  min_relative_volume: MIN_RELATIVE_VOLUME,
  min_rvol_session_fraction: MIN_RVOL_SESSION_FRACTION,
  volume_lookback_days: VOLUME_LOOKBACK_DAYS,
  volume_compare_mode: VOLUME_COMPARE_MODE,
  telegram_bot_token: ENV.fetch('TELEGRAM_BOT_TOKEN', nil),
  telegram_chat_id: ENV.fetch('TELEGRAM_CHAT_ID', nil),
  use_levels: USE_LEVELS,
  levels_lookback_days: LEVELS_LOOKBACK_DAYS,
  level_proximity_pct: LEVEL_PROXIMITY_PCT,
  level_sell_min_profit: LEVEL_SELL_MIN_PROFIT,
  level_pivot_window: LEVEL_PIVOT_WINDOW,
  level_cluster_pct: LEVEL_CLUSTER_PCT,
  up_require_support: UP_REQUIRE_SUPPORT,
  up_entry_ma_days: UP_ENTRY_MA_DAYS
)

STATE_PATH = File.expand_path('../tmp/strategy_state.json', __dir__)
FileUtils.mkdir_p(File.dirname(STATE_PATH))

MARKET_CACHE_PATH = File.expand_path('../tmp/market_instruments_cache.json', __dir__)
MOEX_INDEX_CACHE_PATH = File.expand_path('../tmp/moex_index_cache.json', __dir__)

state = nil

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

  # В UP торгуем по расширенному whitelist'у, в остальных трендах — по базовому
  # TICKERS (широкий пул там и так приходит из intersection-ветки).
  universe_tickers = trend == :up ? UP_UNIVERSE : TICKERS
  universe = logic.rank_universe_by_volume(logic.build_universe(tickers: universe_tickers))
  LOGGER.debug("universe (count=#{universe.size}, source=#{trend == :up ? 'UP_TICKERS' : 'TICKERS'}):")
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
      client, logic, account_id, state: state, figi_cache: figi_cache, logger: LOGGER
    )
  rescue InvestTinkoff::GRPC::Error => e
    LOGGER.error("Force exit gRPC error: #{e.class} #{e.message}")
  end

  case trend
  when :up
    LOGGER.info('Trend: UP — intraday dip BUY (max once per ticker per day)')
    up_portfolio = TradingLogic::StrategyHelpers.load_portfolio_snapshot(client, account_id, logger: LOGGER)
    # Портфель читается один раз за проход, поэтому лимиты доли акций сами по себе не
    # увидят предыдущие заявки этого же прохода. Накапливаем занятые рубли вручную.
    run_committed = 0.0
    up_positions = nil
    up_positions_loaded = false
    universe.each do |it| # rubocop:disable Metrics/BlockLength
      helpers = TradingLogic::StrategyHelpers
      if helpers.acted_today?(state, 'last_buy', it[:ticker])
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'already_processed', outcome: 'rejected'
        )
        next
      end
      if helpers.pending_order_active?(state, it[:ticker])
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'pending_order', outcome: 'rejected', figi: it[:figi]
        )
        next
      end

      cur = logic.last_price_for(it[:figi])
      intraday = begin
        logic.intraday_price_stats(it[:figi])
      rescue StandardError
        {}
      end
      today_high = intraday[:high]
      dip_thr = today_high ? (today_high * (1.0 - DIP_PCT)) : nil
      it_live = cur ? it.merge(price: cur) : it
      # buy_gate считает все подусловия за один проход по API и заодно даёт shadow-лог:
      # видно, какой именно гейт отсёк кандидата. Цену и максимум передаём внутрь —
      # решение и цена лимитной заявки должны считаться по одному снимку.
      gate = logic.buy_gate(
        it_live, trend: trend, price: cur, high: today_high, session_vwap: intraday[:vwap]
      )
      LOGGER.debug("#{it[:ticker]} cur=#{cur.inspect} today_high=#{today_high.inspect} " \
                   "dip_threshold=#{dip_thr.inspect} gate=#{gate.inspect}")
      # При аварии портфельного API сохраняем полную диагностику сигналов, но
      # fail-closed блокируем любые действия и портфельные гейты.
      unless up_portfolio
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'portfolio_preflight', outcome: 'rejected', figi: it[:figi],
                  reason: 'unavailable', gate: gate
        )
        next
      end
      unless gate[:should_buy]
        failed_stage = if !gate[:dip]
                         'dip'
                       elsif !gate[:volume_ok]
                         'volume'
                       else
                         'trend_entry'
                       end
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: failed_stage, outcome: 'rejected', figi: it[:figi], gate: gate
        )
        next
      end

      buy_value = (cur || it[:price]) * it[:lot] * LOTS_PER_ORDER
      unless helpers.position_within_limit?(
        client, account_id, it[:figi],
        planned_buy_value: buy_value, portfolio: up_portfolio, logger: LOGGER
      )
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'position_limit', outcome: 'rejected', figi: it[:figi], buy_value: buy_value
        )
        next
      end
      unless helpers.daily_buy_within_limit?(state, buy_value, logger: LOGGER)
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'daily_budget', outcome: 'rejected', figi: it[:figi], buy_value: buy_value,
                  committed_today: helpers.daily_buy_committed_total(state)
        )
        next
      end
      unless helpers.shares_share_within_limit?(
        client, account_id,
        planned_buy_value: buy_value + run_committed, portfolio: up_portfolio, logger: LOGGER
      )
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'shares_exposure', outcome: 'rejected', figi: it[:figi], buy_value: buy_value
        )
        next
      end

      if SHADOW_BUYS
        LOGGER.info("SHADOW BUY #{it[:ticker]} lots=#{LOTS_PER_ORDER} @#{cur || it[:price]} " \
                    "value=#{buy_value.round(2)} gate=#{gate.inspect}")
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'shadow_order', outcome: 'eligible', figi: it[:figi],
                  price: cur || it[:price], buy_value: buy_value
        )
        next
      end

      unless up_positions_loaded
        up_positions = TradingLogic::StrategyHelpers.load_positions_snapshot(
          client, account_id, logger: LOGGER
        )
        up_positions_loaded = true
      end
      unless up_positions
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'cash_preflight', outcome: 'rejected', figi: it[:figi],
                  reason: 'positions_unavailable'
        )
        next
      end

      unless helpers.cash_sufficient_for_buy?(
        client, account_id,
        planned_buy_value: buy_value + run_committed, positions: up_positions, logger: LOGGER
      )
        helpers.log_buy_funnel(
          LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                  stage: 'cash', outcome: 'rejected', figi: it[:figi], buy_value: buy_value
        )
        next
      end

      result = logic.confirm_and_place_order_with_result(
        account_id: account_id,
        figi: it[:figi],
        quantity: LOTS_PER_ORDER, # в ЛОТАХ, не в штуках
        price: cur || it[:price],
        direction: Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY,
        order_type: Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      result[:figi] ||= it[:figi]
      helpers.account_buy_result!(
        state, it[:ticker], result, planned_value: buy_value, logger: LOGGER, scan_id: SCAN_ID
      )
      category = result[:category].to_s
      committed = helpers.buy_committed_result?(result)
      helpers.log_buy_funnel(
        LOGGER, scan_id: SCAN_ID, ticker: it[:ticker], path: 'up',
                stage: 'order', outcome: committed ? 'committed' : 'rejected',
                reason: category.empty? ? 'unknown' : category, figi: it[:figi],
                price: cur || it[:price], buy_value: buy_value,
                client_order_id: helpers.pending_client_order_id(result),
                broker_order_id: helpers.pending_broker_order_id(result)
      )
      run_committed += buy_value if committed

      if helpers.buy_execution_result?(result)
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
    # Единый проход по всем позициям, включая бумаги вне исходного TICKERS. Внутри
    # действует broker-side guard активных SELL и fail-closed поведение GetOrders.
    TradingLogic::StrategyHelpers.try_sell_positions_with_logic!(
      client, logic, account_id, state, figi_cache: figi_cache, trend: trend, logger: LOGGER
    )
    # попытка одной покупки по momentum-сигналу из пересечения IMOEX∩market
    LOGGER.info("DOWN: try momentum(#{MOMENTUM_RULE}) BUY one per day from IMOEX∩market")
    bought = TradingLogic::StrategyHelpers.buy_one_momentum_from_intersection!(
      client, logic, state,
      market_cache_path: MARKET_CACHE_PATH,
      moex_index_cache_path: MOEX_INDEX_CACHE_PATH,
      max_lot_rub: MAX_LOT_RUB,
      lots_per_order: LOTS_PER_ORDER,
      account_id: account_id,
      logger: LOGGER,
      scan_id: SCAN_ID
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
    LOGGER.info("Trend: SIDE — SELL by same rules, and try momentum(#{MOMENTUM_RULE}) BUY one per day")
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
      logger: LOGGER,
      scan_id: SCAN_ID
    )
    LOGGER.info('SIDE: no momentum candidates') unless bought
  end

  TradingLogic::StrategyHelpers.check_sell_consistency!(client, account_id, state, logger: LOGGER)

  LOGGER.debug('---')
rescue InvestTinkoff::GRPC::Error => e
  LOGGER.error("gRPC error: #{e.class} #{e.message}")
ensure
  # Сохраняем ВСЕГДА, а не только на успешном пути. Если ошибка прилетит после отправки
  # заявки (следующий кандидат, портфель, любой API-вызов), потерянный state означает
  # забытый pending_order — то есть риск дубля покупки на следующем запуске — и
  # обнулённый дневной бюджет.
  if state
    begin
      TradingLogic::StrategyHelpers.save_state(STATE_PATH, state)
    rescue StandardError => e
      LOGGER.error("save_state failed: #{e.class} #{e.message}")
    end
  end
end
