# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'time'
require_relative 'utils'

module TradingLogic
  module StrategyHelpers # rubocop:disable Metrics/ModuleLength
    module_function

    BUY_FUNNEL_PREFIX = 'buy_funnel'
    BUY_FUNNEL_SCAN_PREFIX = 'buy_funnel_scan'
    BUY_ORDER_LIFECYCLE_PREFIX = 'buy_order_lifecycle'

    # Одна терминальная запись на (scan_id, ticker) показывает, на каком гейте
    # закончилась проверка кандидата. Для кандидатов, дошедших до брокера, stage=order
    # содержит фактическую категорию результата. JSON после префикса позволяет
    # считать воронку без хрупкого разбора человекочитаемых сообщений.
    def log_buy_funnel(logger, scan_id:, ticker:, path:, stage:, outcome:, **details)
      payload = {
        scan_id: scan_id.to_s,
        ticker: ticker.to_s,
        path: path.to_s,
        stage: stage.to_s,
        outcome: outcome.to_s
      }
      details.each { |key, value| payload[key] = value unless value.nil? }
      logger&.debug("#{BUY_FUNNEL_PREFIX} #{JSON.generate(payload)}")
    rescue StandardError
      # Диагностика не должна менять торговое решение, даже если formatter/logger
      # временно недоступен или дополнительное поле нельзя сериализовать.
      nil
    end

    def new_buy_scan_id
      SecureRandom.uuid
    end

    # Scan-level outcomes cover early exits where there is no ticker and therefore
    # no regular buy_funnel record to emit.
    def log_buy_funnel_scan(logger, scan_id:, path:, outcome:, **details)
      payload = {
        scan_id: scan_id.to_s,
        path: path.to_s,
        outcome: outcome.to_s
      }
      details.each { |key, value| payload[key] = value unless value.nil? }
      logger&.debug("#{BUY_FUNNEL_SCAN_PREFIX} #{JSON.generate(payload)}")
    rescue StandardError
      nil
    end

    def log_buy_order_lifecycle(logger, ticker:, info:, event:, **details)
      payload = {
        scan_id: info['scan_id'],
        ticker: ticker.to_s,
        event: event.to_s,
        client_order_id: info['client_order_id'],
        broker_order_id: info['broker_order_id']
      }.compact
      details.each { |key, value| payload[key] = value unless value.nil? }
      logger&.debug("#{BUY_ORDER_LIFECYCLE_PREFIX} #{JSON.generate(payload)}")
    rescue StandardError
      nil
    end

    def reject_buy_funnel(logger, scan_id:, ticker:, path:, stage:, **details)
      log_buy_funnel(
        logger, scan_id: scan_id, ticker: ticker, path: path,
                stage: stage, outcome: 'rejected', **details
      )
      nil
    end

    def load_cache_normalized(path)
      return [] unless File.exist?(path)

      raw = begin
        JSON.parse(File.read(path))
      rescue StandardError
        {}
      end
      arr = raw['instruments'] || raw['instruments_list'] || []
      arr.map do |h|
        # поддерживаем разные форматы: string keys or symbol keys
        hh = h.transform_keys(&:to_s)
        ticker = hh['ticker'] || hh['secid'] || hh['seccode'] || hh['seccode_short']
        figi   = hh['figi'] || hh['FIGI'] || nil
        { 'ticker' => ticker&.to_s, 'figi' => figi, 'raw' => hh }
      end.compact
    end

    def read_json(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      {}
    end

    def extract_market_tickers(json)
      arr =
        if json.is_a?(Hash)
          json['instruments'] || (json['securities'].is_a?(Hash) ? json['securities']['data'] : nil) || json['data'] || []
        elsif json.is_a?(Array)
          json
        else
          []
        end
      tickers = []
      arr.each do |it|
        case it
        when Hash
          t = it['ticker'] || it['secid'] || it['symbol'] || it['code']
          tickers << t if t
        end
      end
      tickers.compact.map { |t| t.to_s.upcase }.uniq
    end

    def extract_index_tickers(json)
      arr = json.is_a?(Hash) ? (json['instruments'] || []) : []
      arr.map { |h| (h['secid'] || h['seccode'] || h['secname']).to_s.upcase }.reject(&:empty?).uniq
    end

    def three_consecutive_up?(client, figi)
      closes = Utils.last_daily_closes(client, figi, days: 5)
      return false unless closes && closes.size >= 3

      a = closes[-3]
      b = closes[-2]
      c = closes[-1]
      a < b && b < c
    end

    def find_instrument_by_ticker(client, ticker)
      resp = client.grpc_instruments.find_instrument(query: ticker.to_s)
      resp.instruments.first
    rescue StandardError
      nil
    end

    def build_figi_ticker_map(cache_path)
      return {} unless File.exist?(cache_path)

      data = begin
        JSON.parse(File.read(cache_path))
      rescue StandardError
        {}
      end
      (data['instruments'] || []).each_with_object({}) do |h, map|
        map[h['figi']] = h['ticker'] if h['figi'] && h['ticker']
      end
    end

    def resolve_ticker_for_sell(client, figi:, fallback_ticker: nil, figi_cache: {}, logger: nil)
      ticker = fallback_ticker.to_s.strip.upcase
      return ticker unless ticker.empty?
      return nil if figi.to_s.strip.empty?

      cached = figi_cache[figi].to_s.strip.upcase
      return cached unless cached.empty?

      # Пробуем get_instrument_by (основной метод)
      begin
        inst = client.grpc_instruments.get_instrument_by(:figi, figi)
        tk = inst&.ticker.to_s.strip.upcase
        return tk unless tk.empty?
      rescue StandardError => e
        logger&.debug("get_instrument_by failed for figi=#{figi}: #{e.class}: #{e.message}")
      end

      # Fallback: find_instrument по FIGI (поиск по строке)
      begin
        resp = client.grpc_instruments.find_instrument(query: figi)
        found = resp&.instruments&.first
        tk = found&.ticker.to_s.strip.upcase
        return tk unless tk.empty?
      rescue StandardError => e
        logger&.debug("find_instrument fallback failed for figi=#{figi}: #{e.class}: #{e.message}")
      end

      nil
    end

    # Возвращает true если купили одну бумагу из пересечения по правилу 3d momentum
    def buy_one_momentum_from_intersection!(client, logic, state, market_cache_path:, moex_index_cache_path:,
                                            max_lot_rub:, account_id:, lots_per_order: 1, logger: nil,
                                            scan_id: nil, trading_schedule_cache_path: nil)
      scan_id ||= new_buy_scan_id
      # Не торгуем по протухшим справочникам: устаревший состав IMOEX / рыночный кеш
      # приводит к покупкам недоступных или чужих инструментов.
      # Порог протухания должен быть заметно больше TTL обновления кеша (MarketCache
      # CACHE_TTL_HOURS=24), иначе при ежедневном refresh покупки заблокируются.
      return false unless intersection_caches_fresh?(
        market_cache_path, moex_index_cache_path, logger: logger, scan_id: scan_id
      )

      market = load_cache_normalized(market_cache_path)
      index  = load_cache_normalized(moex_index_cache_path)

      market_tickers = market.map { |i| i['ticker'] }.compact.uniq
      index_tickers  = index.map { |i| i['ticker'] }.compact.uniq

      logger&.debug("market_tickers=#{market_tickers.size} sample=#{market_tickers.sample(5).inspect}")
      logger&.debug("index_tickers=#{index_tickers.size} sample=#{index_tickers.sample(5).inspect}")

      inter = market_tickers & index_tickers
      logger&.debug("intersection candidates=#{inter.size} #{inter.sample(10).inspect}")

      if inter.empty?
        log_buy_funnel_scan(
          logger, scan_id: scan_id, path: 'intersection', outcome: 'empty_intersection',
                  market_tickers: market_tickers.size, index_tickers: index_tickers.size
        )
        return false
      end

      preflight = {}
      candidates = inter.filter_map do |ticker|
        build_intersection_candidate(
          client, logic, state, ticker,
          max_lot_rub: max_lot_rub,
          account_id: account_id,
          lots_per_order: lots_per_order,
          preflight: preflight,
          logger: logger,
          scan_id: scan_id,
          trading_schedule_cache_path: trading_schedule_cache_path
        )
      end

      # Сортируем: кандидаты ближе к support — первыми
      candidates.sort_by! { |c| c[:support_distance] }
      logger&.debug("sorted candidates: #{candidates.map { |c| "#{c[:tk]}(#{c[:support_distance].round(3)})" }.inspect}")

      candidates.each_with_index do |candidate, index|
        next unless execute_intersection_buy_candidate!(
          logic,
          state,
          candidate,
          account_id: account_id,
          logger: logger,
          scan_id: scan_id
        )

        candidates.drop(index + 1).each do |skipped|
          log_buy_funnel(
            logger,
            scan_id: scan_id,
            ticker: skipped[:tk],
            path: 'intersection',
            stage: 'selection',
            outcome: 'skipped',
            reason: 'earlier_order_committed'
          )
        end
        return true
      end

      false
    end

    def intersection_caches_fresh?(market_cache_path, moex_index_cache_path, logger:, scan_id:)
      max_age = (ENV['INTERSECTION_CACHE_MAX_AGE_HOURS'] || '72').to_i * 3600
      market_updated_at = cache_updated_at(market_cache_path)
      moex_updated_at = cache_updated_at(moex_index_cache_path)
      return true if cache_fresh?(market_cache_path, max_age) && cache_fresh?(moex_index_cache_path, max_age)

      logger&.warn('intersection BUY skipped — stale caches ' \
                   "(market updated=#{market_updated_at&.iso8601.inspect}, " \
                   "moex updated=#{moex_updated_at&.iso8601.inspect}, " \
                   "max_age_h=#{max_age / 3600})")
      log_buy_funnel_scan(
        logger, scan_id: scan_id, path: 'intersection', outcome: 'stale_cache',
                market_updated_at: market_updated_at&.iso8601,
                moex_updated_at: moex_updated_at&.iso8601,
                max_age_hours: max_age / 3600
      )
      false
    end

    def build_intersection_candidate(client, logic, state, ticker, max_lot_rub:, account_id:, lots_per_order:,
                                     preflight: {}, logger: nil, scan_id: nil,
                                     trading_schedule_cache_path: nil)
      scan_id ||= new_buy_scan_id
      candidate = build_intersection_signal_candidate(
        client, logic, state, ticker,
        max_lot_rub: max_lot_rub, lots_per_order: lots_per_order, logger: logger, scan_id: scan_id
      )
      return nil unless candidate

      apply_intersection_risk_gates(
        client, logic, state, candidate,
        account_id: account_id, preflight: preflight, logger: logger, scan_id: scan_id,
        trading_schedule_cache_path: trading_schedule_cache_path
      )
    end

    def build_intersection_signal_candidate(client, logic, state, ticker, max_lot_rub:, lots_per_order:,
                                            logger:, scan_id:)
      logger&.debug("processing candidate #{ticker}")
      if buy_already_processed_today?(state, ticker)
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection', stage: 'already_processed'
        )
      end

      # Авторитетный резолв: рублёвая акция TQBR, доступная для торгов через API.
      # Не доверяем строковому совпадению тикера из кеша (защита от "T" -> AT&T).
      share = resolve_tradable_share(client, ticker, logger: logger)
      unless share
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection', stage: 'instrument_resolution'
        )
      end

      figi = share[:figi]
      lot  = share[:lot]

      if instrument_quarantined?(state, figi)
        logger&.debug("skip #{ticker} (figi=#{figi}) — quarantined after permanent broker reject")
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'quarantine', figi: figi
        )
      end

      momentum_trace = {}
      unless valid_momentum_candidate?(
        client, ticker, figi, logger: logger, scan_id: scan_id, trace: momentum_trace
      )
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'momentum', figi: figi, **momentum_trace
        )
      end

      price = logic.last_price_for(figi)
      price_per_lot = price && lot ? (price * lot) : nil
      logger&.debug("#{ticker} figi=#{figi} lot=#{lot.inspect} price=#{price.inspect} price_per_lot=#{price_per_lot.inspect}")

      unless affordable_candidate?(price, lot, lots_per_order, max_lot_rub)
        logger&.debug("skip #{ticker} — price/lot missing or too expensive")
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'affordability', figi: figi,
                  price: price, lot: lot, lots_per_order: lots_per_order, max_lot_rub: max_lot_rub
        )
      end

      unless logic.dip_today?(figi)
        logger&.debug("skip #{ticker} — momentum OK but no intraday dip")
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'dip', figi: figi, price: price
        )
      end
      logger&.debug("#{ticker} entry_stretch=#{logic.entry_stretch_metrics(figi, price: price).inspect}")

      if pending_order_active?(state, ticker)
        logger&.debug("BUY skipped for #{ticker} — active pending order cooldown")
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'pending_order', figi: figi
        )
      end

      {
        tk: ticker, figi: figi, lot: lot, price: price, lots_per_order: lots_per_order,
        exchange: share[:exchange]
      }
    end

    def apply_intersection_risk_gates(client, logic, state, candidate, account_id:, preflight:, logger:, scan_id:,
                                      trading_schedule_cache_path: nil)
      ticker, figi, price = candidate.values_at(:tk, :figi, :price)
      buy_value = candidate[:price] * candidate[:lot] * candidate[:lots_per_order]
      return unless intersection_submission_gates_pass?(
        client, state, candidate, logger: logger, scan_id: scan_id,
                                  trading_schedule_cache_path: trading_schedule_cache_path
      )

      preflight[:portfolio] = load_portfolio_snapshot(client, account_id, logger: logger) unless preflight.key?(:portfolio)
      portfolio = preflight[:portfolio]
      unless portfolio
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'portfolio_preflight', figi: figi, reason: 'unavailable'
        )
      end

      unless position_within_limit?(
        client, account_id, figi, planned_buy_value: buy_value, portfolio: portfolio, logger: logger
      )
        logger&.debug("BUY skipped for #{ticker} — position share limit reached")
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'position_limit', figi: figi, buy_value: buy_value
        )
      end

      unless daily_buy_within_limit?(state, buy_value, logger: logger)
        logger&.debug("BUY skipped for #{ticker} — daily buy budget reached")
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'daily_budget', figi: figi, buy_value: buy_value,
                  committed_today: daily_buy_committed_total(state)
        )
      end

      preflight[:positions] = load_positions_snapshot(client, account_id, logger: logger) unless preflight.key?(:positions)
      unless preflight[:positions]
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'cash_preflight', figi: figi, reason: 'positions_unavailable'
        )
      end

      unless cash_sufficient_for_buy?(
        client, account_id, planned_buy_value: buy_value, positions: preflight[:positions], logger: logger
      )
        logger&.debug("BUY skipped for #{ticker} — insufficient cash")
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'cash', figi: figi, buy_value: buy_value
        )
      end

      unless shares_share_within_limit?(
        client, account_id, planned_buy_value: buy_value, portfolio: portfolio, logger: logger
      )
        logger&.debug("BUY skipped for #{ticker} — shares exposure guard")
        return reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'shares_exposure', figi: figi, buy_value: buy_value
        )
      end

      support_distance = support_distance_for_candidate(logic, figi, price)
      logger&.debug("#{ticker} support_distance=#{support_distance.round(4)}")

      candidate.merge(support_distance: support_distance)
    end

    def intersection_submission_gates_pass?(client, state, candidate, logger:, scan_id:,
                                            trading_schedule_cache_path: nil)
      ticker = candidate[:tk]
      figi = candidate[:figi]
      unless daily_buy_attempt_within_limit?(state, ticker)
        attempts = daily_buy_attempts(state, ticker)
        reject_buy_funnel(
          logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                  stage: 'attempt_limit', figi: figi, attempts: attempts,
                  max_attempts: max_buy_attempts_per_ticker
        )
        return false
      end

      session = buy_session_status(
        client, exchange: candidate[:exchange], cache_path: trading_schedule_cache_path, logger: logger
      )
      return true if session[:open]

      reject_buy_funnel(
        logger, scan_id: scan_id, ticker: ticker, path: 'intersection',
                stage: 'trading_session', figi: figi, reason: session[:reason],
                exchange: session[:exchange]
      )
      false
    end

    def load_portfolio_snapshot(client, account_id, logger: nil)
      client.grpc_operations.portfolio(account_id: account_id)
    rescue StandardError => e
      logger&.error(
        'BUY HALTED: GetPortfolio preflight unavailable ' \
        "(#{e.class}: #{e.message}) — all BUYs blocked for this run"
      )
      nil
    end

    # REST-клиент библиотеки уже предоставляет GetPositions, тогда как её текущая
    # gRPC-обёртка этого метода не содержит. Ответ нужен для RUB и blocked отдельно.
    def load_positions_snapshot(client, account_id, logger: nil)
      response = client.positions(account_id: account_id)
      if response.respond_to?(:success?) && !response.success?
        raise "GetPositions returned HTTP #{response.respond_to?(:http_code) ? response.http_code : 'error'}"
      end

      response.respond_to?(:payload) ? response.payload : response
    rescue StandardError => e
      logger&.error(
        'BUY HALTED: GetPositions cash preflight unavailable ' \
        "(#{e.class}: #{e.message}) — all BUYs blocked for this run"
      )
      nil
    end

    def buy_already_processed_today?(state, ticker)
      acted_today?(state, 'last_buy', ticker)
    rescue StandardError
      false
    end

    def valid_momentum_candidate?(client, ticker, figi, logger: nil, scan_id: nil, trace: nil)
      response = client.grpc_market_data.candles(
        figi: figi,
        from: (Time.now.utc - (8 * 86_400)),
        to: Time.now.utc,
        interval: ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY
      )
      candles = response&.candles || []
      completed = Utils.completed_daily_candles(candles, now: Time.now.utc)
      closes = completed.map { |c| Utils.q_to_decimal(c.close) }.compact
      logger&.debug("#{ticker} closes_count=#{closes.size} completed=#{completed.size}/#{candles.size} sample_last=#{closes.last(5).inspect}")

      if closes.size < 4
        logger&.debug("skip #{ticker} — not enough daily closes (need 4 for a 3-change window)")
        trace&.merge!(reason: 'not_enough_closes', closes_count: closes.size)
        return false
      end

      sequence = closes.last(4)
      verdicts = momentum_verdicts(sequence)
      rule = momentum_rule(logger: logger)
      passed = verdicts.fetch(rule)
      trace&.merge!(reason: passed ? 'passed' : 'active_rule_failed', active_rule: rule)
      # Shadow-лог: считаем ВСЕ варианты правила из тех же закрытий (ноль лишних
      # вызовов API) и пишем одной разборной строкой. Решение принимает только
      # активный rule; остальные копятся для сравнения на живых данных.
      logger&.debug(
        "momentum_shadow ticker=#{ticker} " \
        "closes=#{sequence.map { |value| value.round(4) }.inspect} " \
        "#{verdicts.map { |name, ok| "#{name}=#{ok ? 1 : 0}" }.join(' ')} " \
        "active=#{rule} pass=#{passed ? 1 : 0} scan_id=#{scan_id}"
      )
      passed
    rescue StandardError => e
      logger&.debug("candles request failed for #{ticker}/#{figi}: #{e.class}: #{e.message}")
      trace&.merge!(reason: 'candles_unavailable', error_class: e.class.to_s)
      false
    end

    # Четыре кандидата на правило входа по дневным закрытиям. sequence — 4 закрытия,
    # то есть 3 изменения. strict3 — исходное поведение и дефолт: менять его вслепую
    # нельзя, пока варианты не сравнены на истории.
    MOMENTUM_RULES = %w[strict3 last2 two_of_three cumulative].freeze
    DEFAULT_MOMENTUM_RULE = 'strict3'

    def momentum_verdicts(sequence)
      ups = sequence.each_cons(2).map { |left, right| left < right }
      {
        'strict3' => ups.all?,
        'last2' => ups.last(2).all?,
        'two_of_three' => ups.count(true) >= 2,
        'cumulative' => sequence.last > sequence.first
      }
    end

    def momentum_rule(logger: nil)
      raw = ENV['MOMENTUM_RULE'].to_s.strip.downcase
      return DEFAULT_MOMENTUM_RULE if raw.empty?
      return raw if MOMENTUM_RULES.include?(raw)

      logger&.warn("unknown MOMENTUM_RULE=#{raw.inspect} — falling back to #{DEFAULT_MOMENTUM_RULE} " \
                   "(known: #{MOMENTUM_RULES.join(', ')})")
      DEFAULT_MOMENTUM_RULE
    end

    def affordable_candidate?(price, lot, lots_per_order, max_lot_rub)
      return false unless price && lot

      (price * lot * lots_per_order) <= (max_lot_rub || 10_000)
    end

    def support_distance_for_candidate(logic, figi, price)
      return 1.0 unless logic.respond_to?(:near_support?) && price

      support = logic.nearest_support(figi, price)
      support ? ((price - support[:price]) / support[:price]) : 1.0
    rescue StandardError
      1.0
    end

    def execute_intersection_buy_candidate!(logic, state, candidate, account_id:, logger: nil, scan_id: nil)
      scan_id ||= new_buy_scan_id
      result = begin
        logic.confirm_and_place_order_with_result(
          account_id: account_id,
          figi: candidate[:figi],
          # quantity измеряется в ЛОТАХ, а не в штуках бумаг.
          quantity: candidate[:lots_per_order],
          price: candidate[:price],
          direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY,
          order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
        )
      rescue StandardError
        { ok: false, category: :api_error, status: 'api_error', reject_reason: 'unexpected error', error_code: 'UNKNOWN' }
      end

      result[:figi] ||= candidate[:figi]

      buy_value = candidate[:price] * candidate[:lot] * candidate[:lots_per_order]
      account_buy_result!(
        state, candidate[:tk], result, planned_value: buy_value, logger: logger, scan_id: scan_id
      )
      category = result[:category].to_s
      committed = successful_buy_result?(result)
      log_buy_funnel(
        logger,
        scan_id: scan_id,
        ticker: candidate[:tk],
        path: 'intersection',
        stage: 'order',
        outcome: committed ? 'committed' : 'rejected',
        reason: category.empty? ? 'unknown' : category,
        figi: candidate[:figi],
        price: candidate[:price],
        buy_value: buy_value,
        client_order_id: pending_client_order_id(result),
        broker_order_id: pending_broker_order_id(result)
      )
      return handle_successful_intersection_buy!(state, candidate, result, logger: logger) if committed

      # Постоянный отказ (инструмент недоступен для торгов, 30079) — в карантин,
      # чтобы не долбить брокера каждую минуту одним и тем же FIGI.
      if permanent_instrument_reject?(result)
        quarantine_instrument!(state, candidate[:figi], reason: result[:error_code] || result[:reject_reason],
                                                        logger: logger)
      end

      logger&.warn(buy_failure_message(candidate[:tk], result))
      false
    end

    def successful_buy_result?(result)
      result[:ok] || %w[filled sent_not_filled partially_filled].include?(result[:category].to_s)
    end

    def handle_successful_intersection_buy!(state, candidate, result, logger: nil)
      response = result[:response]
      category = result[:category].to_s
      logger&.debug("BUY accepted for #{candidate[:tk]} (figi=#{candidate[:figi]}) category=#{category} order_id=#{response&.order_id}")
      mark_action!(state, 'last_buy', candidate[:tk]) if buy_execution_result?(result)
      true
    rescue StandardError
      true
    end

    def buy_execution_result?(result)
      category = result[:category].to_s
      result[:ok] == true || %w[filled partially_filled].include?(category)
    end

    def try_sell_positions_with_logic!(client, logic, account_id, state, figi_cache: {}, trend: :side, logger: nil)
      active_sell_figis = guarded_active_sell_figis(client, account_id, context: 'SELL', logger: logger)
      return false unless active_sell_figis

      port = client.grpc_operations.portfolio(account_id: account_id)
      positions = port.positions
      positions.each do |p| # rubocop:disable Metrics/BlockLength
        figi = p.figi

        # Пропускаем не-акции (валюта, облигации, фонды)
        if p.respond_to?(:instrument_type)
          inst_type = p.instrument_type.to_s.upcase
          unless inst_type.include?('SHARE')
            logger&.debug("SELL skip non-share position figi=#{figi} type=#{inst_type}")
            next
          end
        end

        qty_units = p.quantity.units.to_i
        next if qty_units <= 0

        ticker = resolve_ticker_for_sell(client, figi: figi, figi_cache: figi_cache, logger: logger)
        unless ticker
          logger&.debug("SELL ticker resolution failed (likely non-share) figi=#{figi} qty=#{qty_units}")
          next
        end

        next if acted_today?(state, 'last_sell', ticker)

        if active_sell_figis.include?(figi.to_s)
          logger&.info("SELL #{ticker} skipped — active SELL already exists for figi=#{figi}")
          next
        end

        inst = begin
          client.grpc_instruments.get_instrument_by(:figi, figi)
        rescue StandardError
          nil
        end

        lot = inst&.lot.to_i
        lot = 1 if lot <= 0
        it = { figi: figi, ticker: ticker, lot: lot }
        next unless logic.should_sell?(p, it, trend: trend)

        # Продаём один лот. quantity в ЛОТАХ; ограничиваем числом удерживаемых лотов.
        lots_held = qty_units / lot
        sell_qty = [1, lots_held].min
        next if sell_qty <= 0

        result = begin
          logic.confirm_and_place_order_with_result(
            account_id: account_id,
            figi: figi,
            quantity: sell_qty,
            price: logic.last_price_for(figi),
            direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
            order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
          )
        rescue StandardError
          { ok: false, category: :api_error, response: nil }
        end
        if successful_buy_result?(result)
          resp = result[:response]
          logger&.info("SELL #{ticker} lots=#{sell_qty} (order_id=#{resp.order_id})")
          mark_action!(state, 'last_sell', ticker, figi: figi, reason: 'signal')
          active_sell_figis << figi.to_s
        else
          logger&.info("SELL #{ticker} skipped / not confirmed")
        end
      end
    end

    def try_force_exit_positions_with_logic!(client, logic, account_id, state: nil, figi_cache: {}, logger: nil)
      active_sell_figis = guarded_active_sell_figis(client, account_id, context: 'FORCE SELL', logger: logger)
      return false unless active_sell_figis

      port = client.grpc_operations.portfolio(account_id: account_id)
      positions = port.positions
      positions.each do |p|
        try_force_exit_position!(
          client, logic, account_id, p,
          state: state,
          active_sell_figis: active_sell_figis,
          figi_cache: figi_cache,
          logger: logger
        )
      end
    end

    def try_force_exit_position!(client, logic, account_id, position, state: nil, active_sell_figis: nil,
                                 figi_cache: {}, logger: nil)
      figi = position.figi

      if active_sell_figis.nil?
        active_sell_figis = guarded_active_sell_figis(client, account_id, context: 'FORCE SELL', logger: logger)
        return false unless active_sell_figis
      end

      if position.respond_to?(:instrument_type)
        inst_type = position.instrument_type.to_s.upcase
        return unless inst_type.include?('SHARE')
      end

      qty_units = position.quantity.units.to_i
      return if qty_units <= 0
      return unless logic.should_force_exit?(position, figi)

      ticker = resolve_ticker_for_sell(client, figi: figi, figi_cache: figi_cache, logger: logger) || figi
      if active_sell_figis.include?(figi.to_s)
        logger&.info("FORCE SELL #{ticker} skipped — active SELL already exists for figi=#{figi}")
        return false
      end

      inst = begin
        client.grpc_instruments.get_instrument_by(:figi, figi)
      rescue StandardError
        nil
      end

      lot = inst&.lot.to_i
      if lot <= 0
        logger&.warn("FORCE SELL #{ticker} skipped — unable to resolve positive lot size for figi=#{figi}")
        return
      end

      lots = qty_units / lot
      if lots <= 0
        logger&.info("FORCE SELL #{ticker} skipped — holding #{qty_units} < lot=#{lot}")
        return
      end

      cur_price = logic.last_price_for(figi)
      result = begin
        logic.confirm_and_place_order_with_result(
          account_id: account_id,
          figi: figi,
          quantity: lots,
          price: cur_price,
          direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
          order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
        )
      rescue StandardError
        { ok: false, category: :api_error, response: nil }
      end

      if successful_buy_result?(result)
        resp = result[:response]
        logger&.info("FORCE SELL +10% #{ticker} lots=#{lots} (#{qty_units} шт) @#{cur_price} (order_id=#{resp.order_id})")
        active_sell_figis << figi.to_s
        mark_action!(state, 'last_sell', ticker, figi: figi, reason: 'force_exit') if state
        true
      else
        logger&.info("FORCE SELL #{ticker} skipped / not confirmed")
        false
      end
    end

    # Broker-side guard shared by every SELL path. GetOrders is authoritative for
    # active orders and survives process restarts; if it is unavailable we fail
    # closed because another full-position SELL could otherwise be submitted.
    def fetch_active_sell_figis(client, account_id, logger: nil)
      snapshot = fetch_active_orders(client, account_id, logger: logger)
      return snapshot unless snapshot[:ok]

      figis = Array(snapshot[:orders]).filter_map do |order|
        next unless order_direction(order).include?('SELL')

        figi = order_figi(order)
        figi unless figi.empty?
      end.to_set
      { ok: true, figis: figis }
    end

    def guarded_active_sell_figis(client, account_id, context:, logger: nil)
      snapshot = fetch_active_sell_figis(client, account_id, logger: logger)
      return snapshot[:figis] if snapshot[:ok]

      logger&.error(
        "#{context} HALTED: active orders unavailable " \
        "(reason=#{snapshot[:reason].inspect}) — refusing to risk a duplicate SELL"
      )
      nil
    end

    def load_state(path)
      return default_state unless File.exist?(path)

      ensure_state_defaults!(JSON.parse(File.read(path)))
    rescue StandardError
      default_state
    end

    def default_state
      {
        'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {}, 'quarantine' => {},
        'daily_buys' => {}, 'daily_buy_attempts' => {}
      }
    end

    def ensure_state_defaults!(state)
      state ||= {}
      state['last_buy'] ||= {}
      state['last_sell'] ||= {}
      state['pending_orders'] ||= {}
      state['quarantine'] ||= {}
      state['daily_buys'] ||= {}
      state['daily_buy_attempts'] ||= {}
      state
    end

    # Возвращает время updated_at из кеша (Time) или nil.
    def cache_updated_at(path)
      raw = read_json(path)
      ts = raw['updated_at'] || raw['updatedAt']
      return nil unless ts

      Time.parse(ts.to_s)
    rescue StandardError
      nil
    end

    # true если кеш свежее max_age_seconds. Пустой/битый updated_at => false (протух).
    def cache_fresh?(path, max_age_seconds)
      updated = cache_updated_at(path)
      return false unless updated

      (Time.now.utc - updated.utc) <= max_age_seconds
    end

    # BUY разрешён только внутри фактического торгового интервала, который вернул
    # TradingSchedules. Статус инструмента сам по себе не означает, что площадка
    # сейчас открыта. Кеш нужен на диске, потому что cron каждый раз запускает новый
    # процесс. Любая неоднозначность трактуется fail-closed.
    def buy_session_status(client, exchange:, now: Time.now.utc, cache_path: nil, logger: nil)
      normalized_exchange = exchange.to_s.strip.upcase
      return { open: false, reason: 'exchange_unavailable', exchange: normalized_exchange } if normalized_exchange.empty?

      day = now.utc.strftime('%Y-%m-%d')
      schedule = cached_trading_schedule(cache_path, normalized_exchange, day, now: now)
      schedule ||= fetch_and_cache_trading_schedule(
        client, normalized_exchange, day, cache_path: cache_path, now: now, logger: logger
      )
      return { open: false, reason: 'schedule_unavailable', exchange: normalized_exchange } unless schedule

      trading_day = Array(schedule['days']).find { |entry| entry['date'].to_s == day }
      return { open: false, reason: 'day_unavailable', exchange: normalized_exchange } unless trading_day
      return { open: false, reason: 'non_trading_day', exchange: normalized_exchange } unless trading_day['is_trading_day']

      intervals = Array(trading_day['intervals'])
      is_open = intervals.any? do |interval|
        starts_at = parse_schedule_time(interval['start'])
        ends_at = parse_schedule_time(interval['end'])
        starts_at && ends_at && starts_at <= now.utc && now.utc < ends_at
      end
      reason = intervals.empty? ? 'intervals_unavailable' : 'session_closed'
      { open: is_open, reason: is_open ? 'open' : reason, exchange: normalized_exchange }
    rescue StandardError => e
      logger&.warn("BUY session gate failed for #{normalized_exchange}: #{e.class}: #{e.message}")
      { open: false, reason: 'schedule_error', exchange: normalized_exchange }
    end

    def trading_session_open?(client, exchange:, now: Time.now.utc, cache_path: nil, logger: nil)
      buy_session_status(client, exchange: exchange, now: now, cache_path: cache_path, logger: logger)[:open]
    end

    def cached_trading_schedule(path, exchange, day, now: Time.now.utc)
      return nil if path.to_s.empty? || !File.exist?(path)

      cache = JSON.parse(File.read(path))
      updated_at = Time.parse(cache['updated_at'].to_s).utc
      ttl_seconds = (ENV['TRADING_SCHEDULE_CACHE_TTL_HOURS'] || '24').to_f * 3600
      return nil unless ttl_seconds.positive? && (now.utc - updated_at) <= ttl_seconds

      schedule = (cache['exchanges'] || {})[exchange]
      return nil unless schedule && Array(schedule['days']).any? { |entry| entry['date'].to_s == day }

      schedule
    rescue StandardError
      nil
    end

    def fetch_and_cache_trading_schedule(client, exchange, day, cache_path:, now:, logger: nil)
      unless client.respond_to?(:trading_schedules)
        logger&.warn("BUY blocked: TradingSchedules unavailable for exchange=#{exchange}")
        return nil
      end

      day_start = Time.parse("#{day}T00:00:00Z")
      response = client.trading_schedules(exchange: exchange, from: day_start, to: day_start + 86_400)
      if response.respond_to?(:success?) && !response.success?
        raise "TradingSchedules returned HTTP #{response.respond_to?(:http_code) ? response.http_code : 'error'}"
      end

      payload = response.respond_to?(:payload) ? response.payload : response
      schedule = normalize_trading_schedule(payload, exchange)
      raise 'TradingSchedules response has no requested exchange' unless schedule

      persist_trading_schedule_cache(cache_path, exchange, schedule, now: now) unless cache_path.to_s.empty?
      schedule
    rescue StandardError => e
      logger&.warn("BUY blocked: TradingSchedules failed for exchange=#{exchange}: #{e.class}: #{e.message}")
      nil
    end

    def normalize_trading_schedule(payload, requested_exchange)
      exchanges = schedule_field(payload, :exchanges, 'exchanges')
      source = Array(exchanges).find do |entry|
        schedule_field(entry, :exchange, 'exchange').to_s.upcase == requested_exchange
      end
      return nil unless source

      days = Array(schedule_field(source, :days, 'days')).filter_map do |day|
        normalize_trading_day(day)
      end
      { 'exchange' => requested_exchange, 'days' => days }
    end

    def normalize_trading_day(day)
      date_time = parse_schedule_time(schedule_field(day, :date, 'date'))
      return nil unless date_time

      intervals = Array(schedule_field(day, :intervals, 'intervals')).filter_map do |entry|
        interval = schedule_field(entry, :interval, 'interval') || entry
        normalize_schedule_interval(
          schedule_field(interval, :start_ts, 'startTs', 'start_ts'),
          schedule_field(interval, :end_ts, 'endTs', 'end_ts')
        )
      end

      # Старые ответы API не содержат intervals. В них основная и вечерняя сессии
      # представлены отдельными парами времён.
      if intervals.empty?
        [
          %i[start_time end_time],
          %i[evening_start_time evening_end_time],
          %i[premarket_start_time premarket_end_time]
        ].each do |start_name, end_name|
          normalized = normalize_schedule_interval(
            schedule_field(day, start_name, camelize_lower(start_name)),
            schedule_field(day, end_name, camelize_lower(end_name))
          )
          intervals << normalized if normalized
        end
      end

      {
        'date' => date_time.utc.strftime('%Y-%m-%d'),
        'is_trading_day' => schedule_field(day, :is_trading_day, 'isTradingDay', 'is_trading_day') == true,
        'intervals' => intervals
      }
    end

    def normalize_schedule_interval(raw_start, raw_end)
      starts_at = parse_schedule_time(raw_start)
      ends_at = parse_schedule_time(raw_end)
      return nil unless starts_at && ends_at && starts_at < ends_at

      { 'start' => starts_at.utc.iso8601, 'end' => ends_at.utc.iso8601 }
    end

    def parse_schedule_time(value)
      return nil if value.nil?
      return value.to_time.utc if value.respond_to?(:to_time)

      if value.is_a?(Hash) && (value.key?('seconds') || value.key?(:seconds))
        seconds = value['seconds'] || value[:seconds]
        nanos = value['nanos'] || value[:nanos] || 0
        return Time.at(seconds.to_i, nanos.to_i, :nanosecond).utc
      end

      Time.parse(value.to_s).utc
    rescue StandardError
      nil
    end

    def schedule_field(object, *names)
      names.each do |name|
        if object.is_a?(Hash)
          return object[name] if object.key?(name)

          string_name = name.to_s
          return object[string_name] if object.key?(string_name)

          symbol_name = string_name.to_sym
          return object[symbol_name] if object.key?(symbol_name)
        elsif object.respond_to?(name)
          return object.public_send(name)
        end
      end
      nil
    rescue StandardError
      nil
    end

    def camelize_lower(name)
      parts = name.to_s.split('_')
      parts.first + parts.drop(1).map(&:capitalize).join
    end

    def persist_trading_schedule_cache(path, exchange, schedule, now: Time.now.utc)
      cache = begin
        File.exist?(path) ? JSON.parse(File.read(path)) : {}
      rescue StandardError
        {}
      end
      cache['updated_at'] = now.utc.iso8601
      cache['exchanges'] ||= {}
      cache['exchanges'][exchange] = schedule
      FileUtils.mkdir_p(File.dirname(path))
      temp_path = "#{path}.#{Process.pid}.tmp"
      File.write(temp_path, JSON.pretty_generate(cache))
      File.rename(temp_path, path)
      schedule
    rescue StandardError
      nil
    end

    # Помещён ли инструмент в карантин (после постоянного отказа брокера вроде 30079).
    def instrument_quarantined?(state, figi)
      entry = (state['quarantine'] || {})[figi.to_s]
      return false unless entry.is_a?(Hash)

      ts = begin
        Time.parse(entry['ts'].to_s)
      rescue StandardError
        nil
      end
      return false unless ts

      ttl = (ENV['QUARANTINE_TTL_HOURS'] || '24').to_i * 3600
      (Time.now.utc - ts) < ttl
    end

    def quarantine_instrument!(state, figi, reason:, logger: nil)
      ensure_state_defaults!(state)
      state['quarantine'][figi.to_s] = { 'ts' => Time.now.utc.iso8601, 'reason' => reason.to_s }
      logger&.warn("QUARANTINE figi=#{figi} reason=#{reason}")
    end

    # Постоянный (не временный) отказ брокера: инструмент недоступен для торгов.
    def permanent_instrument_reject?(result)
      text = "#{result[:error_code]} #{result[:reject_reason]}".downcase
      text.include?('30079') ||
        text.include?('not available for trading') ||
        text.include?('недоступен')
    end

    # Авторитетный резолв торгуемой рублёвой акции по тикеру+class_code.
    # Возвращает hash с figi/lot/uid/currency или nil, если инструмент нельзя торговать.
    # Это защищает от подмены тикера иностранным инструментом (например "T" -> AT&T).
    # Резолвим строго по указанному class_code (fail-closed): запрашиваем share_by_ticker
    # ИМЕННО с class_code и затем подтверждаем, что вернувшийся инструмент того же класса.
    # НЕ используем безклассовый fallback — иначе на BUY мог бы пройти чужой рублёвый
    # инструмент с тем же тикером на другой доске.
    def resolve_tradable_share(client, ticker, class_code: 'TQBR', logger: nil)
      resp =
        begin
          client.grpc_instruments.share_by_ticker(ticker: ticker, class_code: class_code)
        rescue StandardError => e
          logger&.debug("share_by_ticker(#{ticker}, #{class_code}) error: #{e.class}: #{e.message}")
          nil
        end
      return nil unless resp

      share = resp.respond_to?(:instrument) ? resp.instrument : nil
      return nil unless share

      unless share_tradable?(share, class_code: class_code)
        logger&.debug("skip #{ticker} — not tradable (class=#{share_attr(share, :class_code)} " \
                      "currency=#{share_attr(share, :currency)} buy=#{share_attr(share, :buy_available_flag)} " \
                      "api=#{share_attr(share, :api_trade_available_flag)} status=#{share_attr(share, :trading_status)})")
        return nil
      end

      {
        figi: share_attr(share, :figi),
        lot: (share_attr(share, :lot) || 1).to_i,
        uid: share_attr(share, :uid),
        currency: share_attr(share, :currency).to_s.downcase,
        class_code: share_attr(share, :class_code),
        exchange: share_attr(share, :exchange).to_s
      }
    end

    def share_tradable?(share, class_code: 'TQBR')
      class_ok = share_attr(share, :class_code).to_s.upcase == class_code.to_s.upcase
      currency_ok = share_attr(share, :currency).to_s.downcase == (ENV['CACHE_CURRENCY'] || 'rub').downcase
      buy_ok = share_attr(share, :buy_available_flag) == true
      api_ok = share_attr(share, :api_trade_available_flag) == true
      status_ok = share_attr(share, :trading_status).to_s.upcase.include?('NORMAL_TRADING')
      class_ok && currency_ok && buy_ok && api_ok && status_ok
    end

    def share_attr(obj, name)
      obj.public_send(name) if obj.respond_to?(name)
    rescue StandardError
      nil
    end

    def pending_order_active?(state, ticker)
      pending = (state['pending_orders'] || {})[ticker]
      return false unless pending.is_a?(Hash)

      status = pending['status'].to_s
      %w[sent_not_filled partially_filled].include?(status)
    end

    # --- Ограничители downside -------------------------------------------------
    # Расширение универсума повышает частоту покупок, поэтому нужны два потолка:
    # сколько рублей в день бот вообще может потратить и какую долю счёта держать
    # в акциях (остаток — «сухой порох» под будущие просадки).

    # Исполненные суммы и открытые резервы храним раздельно, но оба компонента
    # участвуют в preflight. Так несколько асинхронных лимиток не могут превысить
    # дневной бюджет, а подтверждённая отмена освобождает только неисполненный остаток.
    def buy_committed_result?(result)
      successful_buy_result?(result)
    end

    def max_buy_attempts_per_ticker
      (ENV['MAX_BUY_ATTEMPTS_PER_TICKER'] || '2').to_i
    end

    def daily_buy_attempts(state, ticker, day: today_key)
      ensure_state_defaults!(state)
      day_attempts = state['daily_buy_attempts'][day]
      return 0 unless day_attempts.is_a?(Hash)

      day_attempts[ticker.to_s.upcase].to_i
    end

    def daily_buy_attempt_within_limit?(state, ticker, day: today_key, max_attempts: nil)
      max_attempts = max_attempts.nil? ? max_buy_attempts_per_ticker : max_attempts.to_i
      return true unless max_attempts.positive?

      daily_buy_attempts(state, ticker, day: day) < max_attempts
    end

    def register_daily_buy_attempt!(state, ticker, day: today_key, count: 1)
      ensure_state_defaults!(state)
      state['daily_buy_attempts'][day] ||= {}
      normalized_ticker = ticker.to_s.upcase
      attempts = daily_buy_attempts(
        state, normalized_ticker, day: day
      ) + [count.to_i, 0].max
      state['daily_buy_attempts'][day][normalized_ticker] = attempts
      # Как и daily_buys, храним только семь последних UTC-дней.
      state['daily_buy_attempts'] = state['daily_buy_attempts'].sort.last(7).to_h
      attempts
    end

    # not_sent означает, что подтверждение не получено и вызова брокера не было.
    # Все остальные исходы получены после попытки отправки, включая api_error и
    # broker_rejected, поэтому должны расходовать лимит попыток.
    def buy_attempt_result?(result)
      result[:category].to_s != 'not_sent'
    end

    def buy_submission_attempt_count(result)
      return 0 unless buy_attempt_result?(result)

      [result.fetch(:submission_attempts, 1).to_i, 1].max
    end

    def daily_buy_total(state, day: today_key)
      ensure_state_defaults!(state)
      state['daily_buys'][day].to_f
    end

    def register_daily_buy!(state, value, day: today_key)
      ensure_state_defaults!(state)
      state['daily_buys'][day] = daily_buy_total(state, day: day) + value.to_f
      # Держим только недавние дни, иначе state растёт без границы.
      state['daily_buys'] = state['daily_buys'].sort.last(7).to_h
      state['daily_buys'][day]
    end

    def unregister_daily_buy!(state, value, day: today_key)
      ensure_state_defaults!(state)
      state['daily_buys'][day] = [daily_buy_total(state, day: day) - value.to_f, 0.0].max
    end

    def pending_buy_reserved_total(state)
      ensure_state_defaults!(state)
      state['pending_orders'].sum do |_ticker, info|
        next 0.0 unless info.is_a?(Hash)
        next 0.0 unless %w[sent_not_filled partially_filled].include?(info['status'].to_s)

        info['reserved_value'].to_f
      end
    end

    def pending_buy_reservation_unknown?(state)
      ensure_state_defaults!(state)
      state['pending_orders'].any? do |_ticker, info|
        info.is_a?(Hash) &&
          %w[sent_not_filled partially_filled].include?(info['status'].to_s) &&
          !info.key?('reserved_value')
      end
    end

    def daily_buy_committed_total(state, day: today_key)
      daily_buy_total(state, day: day) + pending_buy_reserved_total(state)
    end

    def daily_buy_within_limit?(state, planned_buy_value, max_daily_rub: nil, logger: nil)
      max_daily_rub = (max_daily_rub || ENV['MAX_DAILY_BUY_RUB'] || 0).to_f
      return true unless max_daily_rub.positive?

      if pending_buy_reservation_unknown?(state)
        logger&.warn('daily buy budget blocked: active legacy pending order has unknown reservation')
        return false
      end

      filled = daily_buy_total(state)
      reserved = pending_buy_reserved_total(state)
      committed = filled + reserved
      planned = planned_buy_value.to_f
      return true if (committed + planned) <= max_daily_rub

      logger&.info(
        "daily buy budget reached: filled=#{filled.round(2)} reserved=#{reserved.round(2)} " \
        "committed=#{committed.round(2)} + planned=#{planned.round(2)} " \
        "> MAX_DAILY_BUY_RUB=#{max_daily_rub}"
      )
      false
    end

    # Preflight доступности денег для конкретной BUY-заявки. Это не целевой
    # MIN_CASH_SHARE: после покупки кэш может стать почти нулевым, но заведомо
    # неисполнимая заявка до брокера не дойдёт.
    def cash_sufficient_for_buy?(_client, _account_id, planned_buy_value:, positions:, buffer_rate: nil,
                                 logger: nil)
      buffer_rate = (buffer_rate || ENV['BUY_CASH_BUFFER_RATE'] || '0.01').to_f
      buffer_rate = 0.0 if buffer_rate.negative?
      cash = available_currency_amount(positions, currency: 'rub')
      planned = planned_buy_value.to_f
      required = planned * (1.0 + buffer_rate)
      return true if planned.positive? && cash >= required

      logger&.info(
        "insufficient cash: available=#{cash.round(2)} required=#{required.round(2)} " \
        "planned=#{planned.round(2)} buffer=#{(buffer_rate * 100).round(2)}% — BUY blocked"
      )
      false
    rescue StandardError => e
      logger&.warn("cash preflight failed (#{e.class}: #{e.message}) — BUY blocked (fail-closed)")
      false
    end

    def available_currency_amount(positions, currency:)
      raise 'positions snapshot missing' unless positions
      raise 'positions limits are still loading' if structured_value(positions, :limits_loading_in_progress,
                                                                     :limitsLoadingInProgress)

      money = currency_amount(structured_value(positions, :money), currency)
      blocked = currency_amount(structured_value(positions, :blocked), currency)
      [money - blocked, 0.0].max
    end

    def currency_amount(values, currency)
      Array(values).sum do |value|
        next 0.0 unless structured_value(value, :currency).to_s.casecmp?(currency.to_s)

        units = structured_value(value, :units).to_f
        nano = structured_value(value, :nano).to_f
        units + (nano / 1_000_000_000.0)
      end
    end

    def structured_value(object, *names)
      names.each do |name|
        return object.public_send(name) if object.respond_to?(name)
        return object[name] if object.is_a?(Hash) && object.key?(name)

        string_name = name.to_s
        return object[string_name] if object.is_a?(Hash) && object.key?(string_name)
      end
      nil
    end

    # Потолок суммарной доли акций в счёте (в отличие от MAX_POSITION_SHARE, который
    # ограничивает только одну бумагу).
    def shares_share_within_limit?(client, account_id, planned_buy_value: 0, portfolio: nil, max_share: nil,
                                   logger: nil)
      max_share = (max_share || ENV['MAX_SHARES_SHARE'] || 0).to_f
      return true unless max_share.positive? && max_share < 1.0

      port = portfolio || client.grpc_operations.portfolio(account_id: account_id)
      shares = Utils.q_to_decimal(port.total_amount_shares).to_f
      total = portfolio_total_amount(port)
      unless total.positive?
        logger&.warn('shares exposure guard: portfolio total is non-positive — BUY blocked (fail-closed)')
        return false
      end

      share = (shares + planned_buy_value.to_f) / total
      return true if share <= max_share

      logger&.info(
        "shares exposure guard: post-trade shares share=#{(share * 100).round(1)}% " \
        "> MAX_SHARES_SHARE=#{(max_share * 100).round(1)}%"
      )
      false
    rescue StandardError => e
      # Fail-closed, в отличие от соседнего position_within_limit?: это лимит на общий
      # риск счёта, и «не смогли посчитать» не должно молча означать «разрешено».
      # Счёт боевой, ордера уходят без подтверждения.
      logger&.warn("shares exposure guard: check failed (#{e.class}: #{e.message}) — BUY blocked (fail-closed)")
      false
    end

    def portfolio_total_amount(port)
      if port.respond_to?(:total_amount_portfolio)
        total = Utils.q_to_decimal(port.total_amount_portfolio).to_f
        return total if total.positive?
      end

      cash = port.respond_to?(:total_amount_currencies) ? Utils.q_to_decimal(port.total_amount_currencies).to_f : 0.0
      Utils.q_to_decimal(port.total_amount_shares).to_f + cash
    end

    # Проверяет, не превысит ли позиция по figi долю портфеля после покупки.
    # planned_buy_value — стоимость планируемой покупки (qty * price), включается в расчёт.
    # portfolio — предзагруженный портфель (чтобы не дёргать API повторно).
    def position_within_limit?(client, account_id, figi, max_share: nil, planned_buy_value: 0, portfolio: nil, logger: nil)
      max_share ||= (ENV['MAX_POSITION_SHARE'] || '0.33').to_f
      return true if max_share <= 0 || max_share >= 1.0

      port = portfolio || client.grpc_operations.portfolio(account_id: account_id)
      total = Utils.q_to_decimal(port.total_amount_shares)
      return true unless total&.positive?

      position = port.positions.find { |p| p.figi == figi }
      current_value = 0.0
      if position
        qty = position.quantity.units.to_i
        if qty.positive?
          cur_price = position.respond_to?(:current_price) ? Utils.q_to_decimal(position.current_price) : nil
          cur_price ||= Utils.q_to_decimal(position.average_position_price)
          current_value = qty * cur_price if cur_price&.positive?
        end
      end

      post_trade_value = current_value + planned_buy_value.to_f
      post_trade_total = total + planned_buy_value.to_f
      share = post_trade_value / post_trade_total
      if share >= max_share
        logger&.debug("position limit reached for figi=#{figi} post_trade_share=#{(share * 100).round(1)}% >= #{(max_share * 100).round(1)}%")
        return false
      end
      true
    rescue StandardError
      true
    end

    def cleanup_pending_orders!(client, account_id, state, logger: nil, ttl_minutes: nil)
      ensure_state_defaults!(state)
      pending = state['pending_orders']
      return if pending.empty?

      ttl_minutes = (ttl_minutes.nil? ? ENV.fetch('BUY_ORDER_TTL_MIN', '0') : ttl_minutes).to_f
      active_orders = fetch_active_orders(client, account_id, logger: logger)
      unless active_orders[:ok]
        logger&.warn(
          'pending cleanup skipped: active orders response is malformed/unavailable ' \
          "(reason=#{active_orders[:reason].inspect})"
        )
        return
      end

      to_delete = pending.filter_map do |ticker, info|
        ticker if cleanup_pending_order!(
          client, account_id, state, ticker, info,
          active_orders: active_orders, ttl_minutes: ttl_minutes, logger: logger
        )
      end
      to_delete.each { |ticker| pending.delete(ticker) }
    end

    def cleanup_pending_order!(client, account_id, state, ticker, info, active_orders:, ttl_minutes:, logger:)
      migrate_pending_order_metadata!(client, ticker, info, active_orders: active_orders, logger: logger)
      unless pending_order_ids_present?(info)
        logger&.warn("pending order for #{ticker} has no known IDs — keeping entry for safety")
        return false
      end

      active_order = find_active_pending_order(info, active_orders)
      if active_order
        reconcile_active_pending_accounting!(state, info, active_order, logger: logger)
        request_stale_pending_cancel!(
          client, account_id, ticker, info, ttl_minutes: ttl_minutes, logger: logger
        )
        return false
      end

      explicit_status_required = info['cancel_requested_at'] || info['status'].to_s == 'partially_filled'
      result = if explicit_status_required
                 reconcile_explicit_pending_state!(
                   client, account_id, state, ticker, info,
                   cancel_requested: !info['cancel_requested_at'].to_s.empty?,
                   logger: logger
                 )
               else
                 reconcile_missing_pending_order!(client, account_id, state, ticker, info, logger: logger)
               end
      return log_terminal_pending_cleanup(logger, ticker, info, result) if %i[executed not_executed].include?(result)

      label = explicit_status_required ? 'terminal status' : 'execution status'
      logger&.warn("pending order for #{ticker} left untouched — #{label} unknown")
      false
    end

    def log_terminal_pending_cleanup(logger, ticker, info, outcome)
      log_buy_order_lifecycle(
        logger, ticker: ticker, info: info, event: 'terminal',
                outcome: outcome, filled_value: info['filled_value'],
                released_value: info['reserved_value']
      )
      logger&.debug(
        "cleaned up pending order for #{ticker} " \
        "(client_id=#{info['client_order_id'].inspect}, broker_id=#{info['broker_order_id'].inspect})"
      )
      true
    end

    # Освобождать резерв можно ТОЛЬКО по явному терминальному статусу: CANCELLED,
    # REJECTED или полный FILL. Отсутствие заявки в одной выдаче GetOrders и статус
    # PARTIALLYFILL терминальными не считаются — заявка может быть ещё жива.
    def reconcile_explicit_pending_state!(client, account_id, state, ticker, info, cancel_requested:, logger: nil)
      unless client.respond_to?(:order_state)
        logger&.warn("terminal status unavailable for #{ticker}: client has no order_state")
        return unresolved_explicit_pending_state(logger, ticker, info, cancel_requested: cancel_requested)
      end

      broker_order_id = info['broker_order_id'].to_s
      return unresolved_explicit_pending_state(logger, ticker, info, cancel_requested: cancel_requested) if broker_order_id.empty?

      response = client.order_state(account_id: account_id, order_id: broker_order_id)
      if response.respond_to?(:success?) && !response.success?
        logger&.warn("terminal status lookup failed for #{ticker}: broker response is unsuccessful")
        return unresolved_explicit_pending_state(logger, ticker, info, cancel_requested: cancel_requested)
      end

      order = response.respond_to?(:payload) ? response.payload : response
      status = order_status(order)
      reconcile_active_pending_accounting!(state, info, order, logger: logger)
      fully_filled = status.include?('FILL') && !status.include?('PARTIAL')
      terminal = status.include?('CANCEL') || status.include?('REJECT') || fully_filled
      unless terminal
        return unresolved_explicit_pending_state(
          logger, ticker, info, cancel_requested: cancel_requested, status: status
        )
      end

      return :not_executed unless order_has_executed_lots?(order)

      mark_action!(state, 'last_buy', ticker)
      :executed
    rescue StandardError => e
      logger&.warn("terminal status lookup failed for #{ticker}: #{e.class}: #{e.message}")
      unresolved_explicit_pending_state(logger, ticker, info, cancel_requested: cancel_requested)
    end

    def unresolved_explicit_pending_state(logger, ticker, info, cancel_requested:, status: nil)
      attempts = increment_terminal_confirm_attempts!(info)
      subject = cancel_requested ? 'cancel' : 'terminal status'
      logger&.debug(
        "#{subject} not confirmed for #{ticker} status=#{status.to_s.empty? ? 'unavailable' : status} " \
        "attempt=#{attempts} — reservation kept"
      )
      alert_stuck_pending_order!(logger, ticker, info, cancel_requested: cancel_requested)
      :unknown
    end

    # Older local state may contain cancel_confirm_attempts. Read it as an alias,
    # then continue under the neutral name because terminal checks also happen
    # when automatic cancellation is disabled.
    def terminal_confirm_attempts(info)
      [info['terminal_confirm_attempts'].to_i, info['cancel_confirm_attempts'].to_i].max
    end

    def increment_terminal_confirm_attempts!(info)
      attempts = terminal_confirm_attempts(info) + 1
      info['terminal_confirm_attempts'] = attempts
      attempts
    end

    def fetch_active_orders(client, account_id, logger: nil)
      resp = client.grpc_orders.get_orders(account_id: account_id)
      if resp.nil?
        logger&.warn('get_orders: nil response')
        return { ok: false, reason: 'nil response' }
      end

      unless resp.respond_to?(:orders)
        logger&.warn('get_orders: response missing orders')
        return { ok: false, reason: 'response missing orders' }
      end

      orders = resp.orders
      if orders.nil?
        logger&.warn('get_orders: orders is nil')
        return { ok: false, reason: 'orders is nil' }
      end

      broker_ids = Set.new
      client_ids = Set.new
      broker_by_client = {}
      orders_by_broker = {}
      orders_by_client = {}

      orders.each do |order|
        broker_id = order_broker_id(order)
        client_id = order_request_id(order)

        broker_ids << broker_id if broker_id
        client_ids << client_id if client_id
        broker_by_client[client_id] = broker_id if client_id && broker_id
        orders_by_broker[broker_id] = order if broker_id
        orders_by_client[client_id] = order if client_id
      end

      {
        ok: true,
        orders: orders,
        broker_order_ids: broker_ids,
        client_order_ids: client_ids,
        broker_id_by_client_id: broker_by_client,
        orders_by_broker_id: orders_by_broker,
        orders_by_client_id: orders_by_client
      }
    rescue StandardError => e
      logger&.warn("get_orders exception: #{e.class}: #{e.message}")
      { ok: false, reason: 'get_orders exception' }
    end

    def migrate_pending_order_metadata!(client, ticker, info, active_orders:, logger: nil)
      return unless info.is_a?(Hash)

      if info['broker_order_id'].to_s.empty?
        client_id = info['client_order_id'].to_s
        mapped_broker_id = active_orders[:broker_id_by_client_id][client_id]
        info['broker_order_id'] = mapped_broker_id if mapped_broker_id
      end

      return unless info['figi'].to_s.empty?
      return unless client.respond_to?(:grpc_instruments)

      share = resolve_tradable_share(client, ticker, logger: logger)
      return unless share && share[:figi]

      info['figi'] = share[:figi]
      logger&.debug("pending metadata migrated for #{ticker}: figi=#{share[:figi]}")
    rescue StandardError => e
      logger&.warn("pending metadata migration failed for #{ticker}: #{e.class}: #{e.message}")
    end

    def reconcile_missing_pending_order!(client, account_id, state, ticker, info, logger: nil)
      legacy_accounting = !info.key?('reserved_value')
      execution = pending_buy_execution_state(client, account_id, info, logger: logger)
      return :not_executed if execution[:status] == :not_executed
      return :unknown if execution[:status] == :unknown

      total_filled = execution[:amount]
      total_filled = info['planned_value'].to_f unless total_filled&.positive?
      already_registered = info['filled_value'].to_f
      # Legacy state already included the full submitted amount in daily_buys.
      # If the order disappeared before we could migrate it from active OrderState,
      # keep that conservative amount and avoid registering the execution twice.
      newly_filled = legacy_accounting ? 0.0 : [total_filled.to_f - already_registered, 0.0].max
      register_daily_buy!(state, newly_filled, day: execution[:day]) if newly_filled.positive?

      logger&.info(
        "pending BUY resolved with execution for #{ticker} — marking last_buy " \
        "newly_filled=#{newly_filled.round(2)} released=#{info['reserved_value'].to_f.round(2)}"
      )
      mark_action!(state, 'last_buy', ticker)
      :executed
    rescue StandardError => e
      logger&.warn("pending reconciliation failed for #{ticker}: #{e.class}: #{e.message}")
      :unknown
    end

    def pending_buy_execution_state(client, account_id, pending_info, logger: nil)
      from = pending_order_ts(pending_info) || (Time.now.utc - (2 * 24 * 3600))
      overlap = (ENV['PENDING_RECONCILE_OVERLAP_SECONDS'] || '120').to_i
      from -= overlap if overlap.positive?
      to = Time.now.utc
      figi = pending_info['figi'].to_s
      if figi.empty?
        logger&.warn('pending reconciliation skipped: FIGI is missing')
        return { status: :unknown }
      end

      fetched = operations_between(client, account_id, from: from, to: to)
      return { status: :unknown } unless fetched[:ok]

      matching = fetched[:operations].select do |op|
        operation_buy_executed_for_figi?(op, figi)
      end
      return { status: :unknown } if matching.empty? && fetched[:has_next]
      return { status: :not_executed } if matching.empty?

      amounts = matching.filter_map { |op| operation_payment_abs(op) }
      amount = amounts.sum if amounts.any?
      execution_time = matching.filter_map { |op| operation_time(op) }.max
      { status: :executed, amount: amount, day: (execution_time || Time.now.utc).strftime('%Y-%m-%d') }
    end

    def operation_payment_abs(op)
      payment = structured_value(op, :payment)
      value = Utils.q_to_decimal(payment)
      value&.abs
    rescue StandardError
      nil
    end

    def operation_time(op)
      candidate = structured_value(op, :date, :time, :timestamp)
      return nil unless candidate

      if candidate.respond_to?(:seconds)
        Time.at(candidate.seconds).utc
      elsif candidate.is_a?(Time)
        candidate.utc
      else
        Time.parse(candidate.to_s).utc
      end
    rescue StandardError
      nil
    end

    def operations_between(client, account_id, from:, to:)
      ops = client.grpc_operations
      if ops.respond_to?(:operations_by_cursor)
        resp = ops.operations_by_cursor(account_id: account_id, from: from, to: to)
        return { ok: false, operations: [] } if resp.nil? || !resp.respond_to?(:items)

        operations = resp.items
        return { ok: false, operations: [] } if operations.nil?

        has_next = resp.respond_to?(:has_next) ? resp.has_next : false
      elsif ops.respond_to?(:operations)
        resp = ops.operations(account_id: account_id, from: from, to: to)
        return { ok: false, operations: [] } if resp.nil? || !resp.respond_to?(:operations)

        operations = resp.operations
        return { ok: false, operations: [] } if operations.nil?

        has_next = false
      else
        return { ok: false, operations: [] }
      end
      { ok: true, operations: operations, has_next: has_next }
    rescue StandardError
      { ok: false, operations: [] }
    end

    def operation_buy_executed_for_figi?(op, figi)
      return false unless operation_kind(op) == :buy

      op_figi = op.respond_to?(:figi) ? op.figi.to_s : ''
      return false unless op_figi == figi

      operation_has_execution?(op)
    end

    def operation_has_execution?(op)
      qty = operation_quantity_done(op)
      return true if qty&.positive?

      trades = operation_trades(op)
      return true if trades && !trades.empty?

      status = operation_execution_status(op)
      return true if status.include?('FILL') || status.include?('EXECUTED')

      false
    rescue StandardError
      false
    end

    def operation_quantity_done(op)
      raw =
        if op.respond_to?(:quantity_done)
          op.quantity_done
        elsif op.respond_to?(:lots_executed)
          op.lots_executed
        elsif op.respond_to?(:executed_lots)
          op.executed_lots
        end
      return nil if raw.nil?

      if raw.respond_to?(:units)
        Utils.q_to_decimal(raw)
      else
        raw.to_f
      end
    rescue StandardError
      nil
    end

    def operation_trades(op)
      return op.trades if op.respond_to?(:trades)
      return op.trade_items if op.respond_to?(:trade_items)

      if op.respond_to?(:trades_info)
        info = op.trades_info
        return nil unless info
        return info.trades if info.respond_to?(:trades)
      end

      nil
    end

    def operation_execution_status(op)
      raw =
        if op.respond_to?(:state)
          op.state
        elsif op.respond_to?(:status)
          op.status
        elsif op.respond_to?(:operation_state)
          op.operation_state
        end
      raw.to_s.upcase
    rescue StandardError
      ''
    end

    def pending_order_ts(info)
      Time.parse(info['ts'].to_s).utc
    rescue StandardError
      nil
    end

    def account_buy_result!(state, ticker, result, planned_value:, day: today_key, logger: nil, scan_id: nil)
      submission_attempts = buy_submission_attempt_count(result)
      if submission_attempts.positive?
        attempts = register_daily_buy_attempt!(
          state, ticker, day: day, count: submission_attempts
        )
      end
      accounting = buy_result_accounting(result, planned_value: planned_value)
      register_daily_buy!(state, accounting[:filled_value], day: day) if accounting[:filled_value].positive?
      sync_pending_order!(
        state, ticker, result, accounting: accounting, reservation_day: day, scan_id: scan_id
      )
      logger&.debug(
        "BUY accounting ticker=#{ticker} filled=#{accounting[:filled_value].round(2)} " \
        "reserved=#{accounting[:reserved_value].round(2)} planned=#{planned_value.to_f.round(2)} " \
        "attempts_today=#{attempts || daily_buy_attempts(state, ticker, day: day)}"
      )
      accounting
    end

    def buy_result_accounting(result, planned_value:)
      planned = planned_value.to_f
      return { filled_value: 0.0, reserved_value: 0.0, planned_value: planned } unless successful_buy_result?(result)

      fully_filled = result[:category].to_s == 'filled' || result[:ok] == true
      order_fill_split(result[:response], planned_value: planned, fully_filled: fully_filled)
    end

    # Единственный источник правды о том, какая часть заявки уже исполнена, а какая
    # ещё держит бюджет. Считаем ТОЛЬКО по лотам: total_order_amount — это
    # «итоговая стоимость заявки, включающая все комиссии» (orders.proto), она
    # положительна и у неисполненного лимитника, поэтому как объём исполнения
    # непригодна. executed_order_price тоже не годится: в PostOrderResponse это
    # средняя цена ОДНОГО инструмента, а в OrderState — уже произведение на лоты.
    # reserved считаем вычитанием, чтобы filled + reserved == planned по построению.
    def order_fill_split(order, planned_value:, fully_filled: false)
      planned = planned_value.to_f
      return { filled_value: planned, reserved_value: 0.0, planned_value: planned } if fully_filled

      requested = order_numeric_field(order, :lots_requested)
      executed = order_numeric_field(order, :lots_executed)
      executed = order_numeric_field(order, :executed_order_lots) if executed.nil?

      unless requested&.positive? && executed && executed >= 0
        # Старый/неполный ответ брокера: весь planned остаётся обязательством.
        # Это менее точно, но не позволяет превысить дневной лимит.
        return { filled_value: 0.0, reserved_value: planned, planned_value: planned }
      end

      filled = planned * ([executed, requested].min / requested)
      { filled_value: filled, reserved_value: [planned - filled, 0.0].max, planned_value: planned }
    rescue StandardError
      { filled_value: 0.0, reserved_value: planned_value.to_f, planned_value: planned_value.to_f }
    end

    def order_numeric_field(order, field)
      raw = structured_order_value(order, field)
      return nil if raw.nil?

      raw.respond_to?(:units) ? Utils.q_to_decimal(raw).to_f : raw.to_f
    rescue StandardError
      nil
    end

    def order_money_field(order, field)
      raw = structured_order_value(order, field)
      return nil if raw.nil?

      value = if raw.respond_to?(:units)
                Utils.q_to_decimal(raw)
              elsif raw.is_a?(Hash)
                units = structured_value(raw, :units).to_f
                nano = structured_value(raw, :nano).to_f
                units + (nano / 1_000_000_000.0)
              end
      value&.abs
    rescue StandardError
      nil
    end

    def structured_order_value(order, field)
      camel = field.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }
      structured_value(order, field, camel.to_sym)
    end

    def sync_pending_order!(state, ticker, result, accounting: nil, reservation_day: today_key, scan_id: nil)
      ensure_state_defaults!(state)
      category = result[:category].to_s
      pending_status =
        case category
        when 'sent_not_filled' then 'sent_not_filled'
        when 'partially_filled' then 'partially_filled'
        end

      if pending_status
        broker_order_id = pending_broker_order_id(result)
        client_order_id = pending_client_order_id(result)
        submitted_at = pending_submitted_at(result)
        state['pending_orders'][ticker] = {
          'client_order_id' => client_order_id,
          'broker_order_id' => broker_order_id,
          'ticker' => ticker,
          'figi' => result[:figi],
          'ts' => submitted_at || Time.now.utc.iso8601,
          'status' => pending_status,
          'planned_value' => accounting && accounting[:planned_value],
          'filled_value' => accounting && accounting[:filled_value],
          'reserved_value' => accounting && accounting[:reserved_value],
          'reservation_day' => reservation_day,
          'scan_id' => scan_id
        }
        state['pending_orders'][ticker].compact!
      else
        state['pending_orders'].delete(ticker)
      end
    end

    def buy_failure_message(ticker, result)
      category = result[:category].to_s
      reason = result[:reject_reason]
      code = result[:error_code]
      tail = "reject_reason=#{reason.inspect} error_code=#{code.inspect}"

      case category
      when 'not_sent'
        "DEBUG: BUY not sent for #{ticker} (confirmation missing) #{tail}"
      when 'broker_rejected'
        "DEBUG: BUY rejected by broker for #{ticker} #{tail}"
      when 'sent_not_filled'
        "DEBUG: BUY sent but not filled for #{ticker} #{tail}"
      when 'partially_filled'
        "DEBUG: BUY partially filled for #{ticker} #{tail}"
      else
        "DEBUG: BUY failed for #{ticker} (category=#{category}) #{tail}"
      end
    end

    def save_state(path, state)
      File.write(path, JSON.pretty_generate(state))
    end

    def restore_state_from_broker_if_empty!(client, account_id, state, day: today_key, logger: nil)
      ensure_state_defaults!(state)
      has_actions = state['last_buy'].any? || state['last_sell'].any?
      has_pending = state['pending_orders'].any?
      return state if has_actions || has_pending

      from = Time.parse("#{day}T00:00:00Z")
      to = Time.parse("#{day}T23:59:59Z")
      operations = []

      ops = client.grpc_operations
      if ops.respond_to?(:operations_by_cursor)
        resp = ops.operations_by_cursor(account_id: account_id, from: from, to: to)
        operations = resp.respond_to?(:items) ? resp.items : []
      elsif ops.respond_to?(:operations)
        resp = ops.operations(account_id: account_id, from: from, to: to)
        operations = resp.respond_to?(:operations) ? resp.operations : []
      end

      operations.each { |op| restore_broker_operation!(client, state, op, day: day, logger: logger) }

      restore_pending_buy_orders!(client, account_id, state, logger: logger)
      state
    rescue StandardError => e
      logger&.error("state restore from broker failed: #{e.class}: #{e.message}")
      state
    end

    def restore_broker_operation!(client, state, operation, day:, logger: nil)
      kind = operation_kind(operation)
      return unless kind

      if kind == :buy
        payment = operation_payment_abs(operation)
        register_daily_buy!(state, payment, day: day) if payment&.positive?
      end

      figi = operation.respond_to?(:figi) ? operation.figi.to_s : ''
      return if figi.empty?

      ticker = resolve_ticker_for_sell(client, figi: figi, logger: logger)
      return unless ticker

      if kind == :buy
        state['last_buy'][day] ||= {}
        state['last_buy'][day][ticker] = true
      else
        state['last_sell'][ticker] = {
          'figi' => figi,
          'ts' => operation_ts_iso8601(operation),
          'reason' => 'broker_restore'
        }
      end
    end

    def today_key
      Time.now.utc.strftime('%Y-%m-%d')
    end

    def acted_today?(state, action, ticker)
      day = today_key
      if action.to_s == 'last_sell'
        sell = state[action] || {}
        entry = sell[ticker]
        return true if entry.is_a?(Hash) && entry['ts'].to_s.start_with?(day)

        # backward compatibility with legacy format { day => { ticker => true } }
        return (sell[day] || {})[ticker] == true
      end

      ((state[action] || {})[day] || {})[ticker] == true
    end

    def mark_action!(state, action, ticker, figi: nil, reason: nil, ts: Time.now.utc.iso8601)
      day = today_key
      state[action] ||= {}

      if action.to_s == 'last_sell'
        state[action][ticker] = {
          'figi' => figi,
          'ts' => ts,
          'reason' => reason || 'signal'
        }
        return
      end

      state[action][day] ||= {}
      state[action][day][ticker] = true
    end

    def state_last_sell_count_for_day(state, day: today_key)
      sell = state['last_sell'] || {}
      return (sell[day] || {}).keys.size if sell[day].is_a?(Hash) && sell.values.none? { |v| v.is_a?(Hash) && v['ts'] }

      sell.values.count { |v| v.is_a?(Hash) && v['ts'].to_s.start_with?(day) }
    end

    def broker_sell_orders_count_for_day(client, account_id, day: today_key, logger: nil)
      from = Time.parse("#{day}T00:00:00Z")
      to = Time.parse("#{day}T23:59:59Z")
      operations = []

      ops = client.grpc_operations
      if ops.respond_to?(:operations_by_cursor)
        resp = ops.operations_by_cursor(account_id: account_id, from: from, to: to)
        operations = resp.respond_to?(:items) ? resp.items : []
      elsif ops.respond_to?(:operations)
        resp = ops.operations(account_id: account_id, from: from, to: to)
        operations = resp.respond_to?(:operations) ? resp.operations : []
      end

      operations.count do |op|
        value = if op.respond_to?(:type) then op.type
                elsif op.respond_to?(:operation_type) then op.operation_type
                elsif op.respond_to?(:state) then op.state
                end
        value.to_s.upcase.include?('SELL')
      end
    rescue StandardError => e
      logger&.error("broker sell consistency check failed: #{e.class}: #{e.message}")
      nil
    end

    def check_sell_consistency!(client, account_id, state, logger: nil)
      broker_count = broker_sell_orders_count_for_day(client, account_id, logger: logger)
      return if broker_count.nil?

      state_count = state_last_sell_count_for_day(state)
      return if broker_count == state_count

      logger&.error("sell consistency mismatch broker=#{broker_count} state_last_sell=#{state_count}")
    end

    def restore_pending_buy_orders!(client, account_id, state, logger: nil)
      ensure_state_defaults!(state)
      return unless client.respond_to?(:grpc_orders)

      resp = client.grpc_orders.get_orders(account_id: account_id)
      return if resp.nil? || !resp.respond_to?(:orders)

      orders = resp.orders
      return if orders.nil?
      return if orders.empty?

      orders.each do |ord|
        next unless buy_order?(ord)

        pending_status = pending_status_for_order(ord)
        next unless pending_status

        figi = order_figi(ord)
        next if figi.empty?

        ticker = resolve_ticker_for_sell(client, figi: figi, logger: logger)
        next unless ticker

        state['pending_orders'][ticker] = restored_pending_order_payload(ord, ticker, pending_status)
        mark_action!(state, 'last_buy', ticker) if order_has_executed_lots?(ord)
      end
    rescue StandardError => e
      logger&.error("pending orders restore failed: #{e.class}: #{e.message}")
    end

    def buy_order?(order)
      order_direction(order).include?('BUY')
    end

    def order_direction(order)
      return '' unless order.respond_to?(:direction)

      order.direction.to_s.upcase
    end

    def pending_status_for_order(order)
      status = order_status(order)
      return 'partially_filled' if status.include?('PARTIALLYFILL')
      return 'sent_not_filled' if status.include?('NEW') || status.include?('ACTIVE') || status.include?('FILL')

      nil
    end

    def order_status(order)
      structured_order_value(order, :execution_report_status).to_s.upcase.then do |status|
        status.empty? ? structured_order_value(order, :status).to_s.upcase : status
      end
    end

    def order_figi(order)
      order.respond_to?(:figi) ? order.figi.to_s : ''
    end

    def restored_pending_order_payload(order, ticker, pending_status)
      planned = order_money_field(order, :initial_order_price)
      # initial_order_price = запрошенные лоты × цена, поэтому это корректный planned.
      # Долю исполнения берём тем же общим методом, что и для свежего ответа брокера.
      split = planned && order_fill_split(order, planned_value: planned)
      payload = {
        'client_order_id' => order_request_id(order),
        'broker_order_id' => order_broker_id(order),
        'ticker' => ticker,
        'figi' => order_figi(order),
        'ts' => order_submitted_at(order) || Time.now.utc.iso8601,
        'status' => pending_status,
        'planned_value' => planned,
        'filled_value' => split && split[:filled_value],
        'reserved_value' => split && split[:reserved_value],
        'reservation_day' => today_key
      }
      payload.compact
    end

    def order_submitted_at(order)
      candidate =
        if order.respond_to?(:order_date) then order.order_date
        elsif order.respond_to?(:created_at) then order.created_at
        elsif order.respond_to?(:date) then order.date
        end
      return nil unless candidate

      parse_time_candidate(candidate)&.iso8601
    rescue StandardError
      nil
    end

    def parse_time_candidate(candidate)
      if candidate.respond_to?(:seconds)
        Time.at(candidate.seconds).utc
      elsif candidate.is_a?(Time)
        candidate.utc
      else
        Time.parse(candidate.to_s).utc
      end
    rescue StandardError
      nil
    end

    def order_has_executed_lots?(order)
      value = structured_order_value(order, :lots_executed)
      value = structured_order_value(order, :executed_order_lots) if value.nil?
      numeric =
        if value.respond_to?(:units)
          Utils.q_to_decimal(value)
        else
          value.to_f
        end
      numeric.positive?
    rescue StandardError
      false
    end

    def order_broker_id(order)
      return nil unless order.respond_to?(:order_id)

      value = order.order_id.to_s
      value.empty? ? nil : value
    rescue StandardError
      nil
    end

    def order_request_id(order)
      return nil unless order.respond_to?(:order_request_id)

      value = order.order_request_id.to_s
      value.empty? ? nil : value
    rescue StandardError
      nil
    end

    def pending_order_ids_present?(info)
      info['client_order_id'].to_s != '' || info['broker_order_id'].to_s != ''
    end

    def find_active_pending_order(info, active_orders)
      client_order_id = info['client_order_id'].to_s
      broker_order_id = info['broker_order_id'].to_s

      by_client = active_orders[:orders_by_client_id] || {}
      by_broker = active_orders[:orders_by_broker_id] || {}
      by_client[client_order_id] || by_broker[broker_order_id]
    end

    def active_pending_order?(info, active_orders)
      !find_active_pending_order(info, active_orders).nil?
    end

    def reconcile_active_pending_accounting!(state, info, order, logger: nil)
      migrate_legacy_pending_accounting!(state, info, order, logger: logger)
      planned = info['planned_value'].to_f
      return unless planned.positive?

      status = pending_status_for_order(order) || info['status'].to_s
      accounting = buy_result_accounting(
        { category: status, response: order },
        planned_value: planned
      )
      registered = info['filled_value'].to_f
      newly_filled = [accounting[:filled_value] - registered, 0.0].max
      register_daily_buy!(state, newly_filled) if newly_filled.positive?

      effective_filled = [registered, accounting[:filled_value]].max
      info['status'] = status
      info['filled_value'] = effective_filled
      # Broker snapshots may be stale or omit lot counters. Never move an already
      # observed fill back into the reservation; preserve the split invariant.
      info['reserved_value'] = [planned - effective_filled, 0.0].max
      logger&.debug(
        "pending BUY accounting ticker=#{info['ticker']} newly_filled=#{newly_filled.round(2)} " \
        "filled=#{info['filled_value'].to_f.round(2)} reserved=#{info['reserved_value'].to_f.round(2)}"
      )
    end

    def migrate_legacy_pending_accounting!(state, info, order, logger: nil)
      return if info.key?('reserved_value')

      planned = order_money_field(order, :initial_order_price)
      return unless planned&.positive?

      reservation_day = pending_order_ts(info)&.strftime('%Y-%m-%d') || today_key
      unregister_daily_buy!(state, planned, day: reservation_day)
      info['planned_value'] = planned
      info['filled_value'] = 0.0
      info['reserved_value'] = planned
      info['reservation_day'] = reservation_day
      logger&.info(
        "migrated legacy pending BUY accounting ticker=#{info['ticker']} " \
        "planned=#{planned.round(2)} day=#{reservation_day}"
      )
    end

    # Отмена может не дойти до брокера или не примениться, поэтому её повторяем с
    # экспоненциальным backoff. Резерв при этом НЕ освобождается: единственный
    # источник правды о судьбе заявки — терминальный статус из GetOrderState.
    def cancel_retry_due?(info, now: Time.now.utc)
      last_attempt = begin
        Time.parse(info['cancel_requested_at'].to_s).utc
      rescue StandardError
        nil
      end
      return true unless last_attempt

      attempts = info['cancel_attempts'].to_i
      base = (ENV['BUY_CANCEL_RETRY_MIN'] || '5').to_f
      return false unless base.positive?

      backoff = base * (2**[attempts - 1, 0].max)
      backoff = [backoff, 60.0].min
      (now - last_attempt) >= (backoff * 60)
    end

    def cancel_max_attempts
      value = (ENV['BUY_CANCEL_MAX_ATTEMPTS'] || '5').to_i
      value.positive? ? value : 5
    end

    # Один ERROR на застрявшую заявку — тем же каналом, что и BUY HALTED. Резерв
    # продолжает держать бюджет: это состояние требует ручного разбора, а не
    # автоматического освобождения денег.
    def alert_stuck_pending_order!(logger, ticker, info, cancel_requested: nil)
      return false if info['cancel_alerted']

      attempts = info['cancel_attempts'].to_i
      confirms = terminal_confirm_attempts(info)
      return false if attempts < cancel_max_attempts && confirms < cancel_max_attempts

      cancel_flow = if cancel_requested.nil?
                      attempts.positive? || !info['cancel_requested_at'].to_s.empty?
                    else
                      cancel_requested
                    end
      event = cancel_flow ? 'cancel_stuck' : 'terminal_status_stuck'
      alert = cancel_flow ? 'BUY CANCEL STUCK' : 'BUY PENDING STUCK'
      info['cancel_alerted'] = true
      log_buy_order_lifecycle(
        logger, ticker: ticker, info: info, event: event,
                cancel_attempts: attempts, terminal_confirm_attempts: confirms,
                reserved_value: info['reserved_value']
      )
      logger&.error(
        "#{alert} #{ticker} order_id=#{info['broker_order_id']} " \
        "cancel_attempts=#{attempts} terminal_confirm_attempts=#{confirms} " \
        "reserved=#{info['reserved_value'].to_f.round(2)} — reservation kept, manual check required"
      )
      true
    end

    def request_stale_pending_cancel!(client, account_id, ticker, info, ttl_minutes:, logger: nil)
      return false unless ttl_minutes.positive?
      return false unless cancel_retry_due?(info)

      submitted_at = pending_order_ts(info)
      return false unless submitted_at
      return false if (Time.now.utc - submitted_at) < (ttl_minutes * 60)

      broker_order_id = info['broker_order_id'].to_s
      if broker_order_id.empty?
        logger&.warn("stale pending BUY #{ticker} cannot be cancelled: broker_order_id is missing")
        return false
      end
      unless client.respond_to?(:cancel_order)
        logger&.warn("stale pending BUY #{ticker} cannot be cancelled: client has no cancel_order")
        return false
      end

      info['cancel_requested_at'] = Time.now.utc.iso8601
      info['cancel_attempts'] = info['cancel_attempts'].to_i + 1
      attempt = info['cancel_attempts']

      response = client.cancel_order(account_id: account_id, order_id: broker_order_id)
      if response.respond_to?(:success?) && !response.success?
        log_buy_order_lifecycle(
          logger, ticker: ticker, info: info, event: 'cancel_failed',
                  reserved_value: info['reserved_value'], ttl_minutes: ttl_minutes,
                  attempt: attempt, reason: 'broker_response_unsuccessful'
        )
        logger&.warn("stale pending BUY cancel failed for #{ticker}: broker response is unsuccessful")
        alert_stuck_pending_order!(logger, ticker, info)
        return false
      end

      log_buy_order_lifecycle(
        logger, ticker: ticker, info: info, event: 'cancel_requested',
                reserved_value: info['reserved_value'], ttl_minutes: ttl_minutes,
                attempt: attempt
      )
      logger&.info(
        "stale pending BUY cancel requested for #{ticker} order_id=#{broker_order_id} " \
        "attempt=#{attempt} " \
        "age_min=#{((Time.now.utc - submitted_at) / 60).round(1)} ttl_min=#{ttl_minutes}"
      )
      alert_stuck_pending_order!(logger, ticker, info)
      true
    rescue StandardError => e
      if defined?(attempt) && attempt
        log_buy_order_lifecycle(
          logger, ticker: ticker, info: info, event: 'cancel_failed',
                  reserved_value: info['reserved_value'], ttl_minutes: ttl_minutes,
                  attempt: attempt, reason: e.class.to_s
        )
        alert_stuck_pending_order!(logger, ticker, info)
      end
      logger&.warn("stale pending BUY cancel failed for #{ticker}: #{e.class}: #{e.message}")
      false
    end

    def pending_broker_order_id(result)
      response = result[:response]
      return result[:broker_order_id].to_s if result[:broker_order_id].to_s != ''

      if response.respond_to?(:order_id)
        value = response.order_id.to_s
        return value unless value.empty?
      end

      nil
    end

    def pending_client_order_id(result)
      response = result[:response]
      if response.respond_to?(:order_request_id)
        value = response.order_request_id.to_s
        return value unless value.empty?
      end

      fallback = result[:client_order_id].to_s
      fallback.empty? ? nil : fallback
    end

    def pending_submitted_at(result)
      value = result[:submitted_at].to_s
      return nil if value.empty?

      Time.parse(value).utc.iso8601
    rescue StandardError
      nil
    end

    def operation_kind(op)
      raw = if op.respond_to?(:type) then op.type
            elsif op.respond_to?(:operation_type) then op.operation_type
            elsif op.respond_to?(:state) then op.state
            end
      val = raw.to_s.upcase
      return :buy if val.include?('BUY')
      return :sell if val.include?('SELL')

      nil
    end

    def operation_ts_iso8601(op)
      candidate =
        if op.respond_to?(:date) then op.date
        elsif op.respond_to?(:time) then op.time
        elsif op.respond_to?(:timestamp) then op.timestamp
        end
      t = begin
        Time.parse(candidate.to_s).utc
      rescue StandardError
        Time.now.utc
      end
      t.iso8601
    end
  end
end
