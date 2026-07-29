# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'utils'

module TradingLogic
  module StrategyHelpers # rubocop:disable Metrics/ModuleLength
    module_function

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
                                            max_lot_rub:, account_id:, lots_per_order: 1, logger: nil)
      # Не торгуем по протухшим справочникам: устаревший состав IMOEX / рыночный кеш
      # приводит к покупкам недоступных или чужих инструментов.
      # Порог протухания должен быть заметно больше TTL обновления кеша (MarketCache
      # CACHE_TTL_HOURS=24), иначе при ежедневном refresh покупки заблокируются.
      max_age = (ENV['INTERSECTION_CACHE_MAX_AGE_HOURS'] || '72').to_i * 3600
      unless cache_fresh?(market_cache_path, max_age) && cache_fresh?(moex_index_cache_path, max_age)
        logger&.warn('intersection BUY skipped — stale caches ' \
                     "(market updated=#{cache_updated_at(market_cache_path)&.iso8601.inspect}, " \
                     "moex updated=#{cache_updated_at(moex_index_cache_path)&.iso8601.inspect}, " \
                     "max_age_h=#{max_age / 3600})")
        return false
      end

      market = load_cache_normalized(market_cache_path)
      index  = load_cache_normalized(moex_index_cache_path)

      market_tickers = market.map { |i| i['ticker'] }.compact.uniq
      index_tickers  = index.map { |i| i['ticker'] }.compact.uniq

      logger&.debug("market_tickers=#{market_tickers.size} sample=#{market_tickers.sample(5).inspect}")
      logger&.debug("index_tickers=#{index_tickers.size} sample=#{index_tickers.sample(5).inspect}")

      inter = market_tickers & index_tickers
      logger&.debug("intersection candidates=#{inter.size} #{inter.sample(10).inspect}")

      return false if inter.empty?

      preflight = {}
      candidates = inter.filter_map do |ticker|
        build_intersection_candidate(
          client, logic, state, ticker,
          max_lot_rub: max_lot_rub,
          account_id: account_id,
          lots_per_order: lots_per_order,
          preflight: preflight,
          logger: logger
        )
      end

      # Сортируем: кандидаты ближе к support — первыми
      candidates.sort_by! { |c| c[:support_distance] }
      logger&.debug("sorted candidates: #{candidates.map { |c| "#{c[:tk]}(#{c[:support_distance].round(3)})" }.inspect}")

      candidates.each do |candidate|
        return true if execute_intersection_buy_candidate!(
          logic,
          state,
          candidate,
          account_id: account_id,
          logger: logger
        )
      end

      false
    end

    def build_intersection_candidate(client, logic, state, ticker, max_lot_rub:, account_id:, lots_per_order:,
                                     preflight: {}, logger: nil)
      logger&.debug("processing candidate #{ticker}")
      return nil if buy_already_processed_today?(state, ticker)

      # Авторитетный резолв: рублёвая акция TQBR, доступная для торгов через API.
      # Не доверяем строковому совпадению тикера из кеша (защита от "T" -> AT&T).
      share = resolve_tradable_share(client, ticker, logger: logger)
      return nil unless share

      figi = share[:figi]
      lot  = share[:lot]

      if instrument_quarantined?(state, figi)
        logger&.debug("skip #{ticker} (figi=#{figi}) — quarantined after permanent broker reject")
        return nil
      end

      return nil unless valid_momentum_candidate?(client, ticker, figi, logger: logger)

      price = logic.last_price_for(figi)
      price_per_lot = price && lot ? (price * lot) : nil
      logger&.debug("#{ticker} figi=#{figi} lot=#{lot.inspect} price=#{price.inspect} price_per_lot=#{price_per_lot.inspect}")

      unless affordable_candidate?(price, lot, lots_per_order, max_lot_rub)
        logger&.debug("skip #{ticker} — price/lot missing or too expensive")
        return nil
      end

      unless logic.dip_today?(figi)
        logger&.debug("skip #{ticker} — momentum OK but no intraday dip")
        return nil
      end
      logger&.debug("#{ticker} entry_stretch=#{logic.entry_stretch_metrics(figi, price: price).inspect}")

      if pending_order_active?(state, ticker)
        logger&.debug("BUY skipped for #{ticker} — active pending order cooldown")
        return nil
      end

      buy_value = price * lot * lots_per_order
      preflight[:portfolio] = load_portfolio_snapshot(client, account_id, logger: logger) unless preflight.key?(:portfolio)
      portfolio = preflight[:portfolio]
      return nil unless portfolio

      unless position_within_limit?(
        client, account_id, figi, planned_buy_value: buy_value, portfolio: portfolio, logger: logger
      )
        logger&.debug("BUY skipped for #{ticker} — position share limit reached")
        return nil
      end

      unless daily_buy_within_limit?(state, buy_value, logger: logger)
        logger&.debug("BUY skipped for #{ticker} — daily buy budget reached")
        return nil
      end

      preflight[:positions] = load_positions_snapshot(client, account_id, logger: logger) unless preflight.key?(:positions)
      return nil unless preflight[:positions]

      unless cash_sufficient_for_buy?(
        client, account_id, planned_buy_value: buy_value, positions: preflight[:positions], logger: logger
      )
        logger&.debug("BUY skipped for #{ticker} — insufficient cash")
        return nil
      end

      unless shares_share_within_limit?(
        client, account_id, planned_buy_value: buy_value, portfolio: portfolio, logger: logger
      )
        logger&.debug("BUY skipped for #{ticker} — shares exposure guard")
        return nil
      end

      support_distance = support_distance_for_candidate(logic, figi, price)
      logger&.debug("#{ticker} support_distance=#{support_distance.round(4)}")

      { tk: ticker, figi: figi, lot: lot, price: price, lots_per_order: lots_per_order, support_distance: support_distance }
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

    def valid_momentum_candidate?(client, ticker, figi, logger: nil)
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
        return false
      end

      sequence = closes.last(4)
      verdicts = momentum_verdicts(sequence)
      rule = momentum_rule(logger: logger)
      # Shadow-лог: считаем ВСЕ варианты правила из тех же закрытий (ноль лишних
      # вызовов API) и пишем одной разборной строкой. Решение принимает только
      # активный rule; остальные копятся для сравнения на живых данных.
      logger&.debug(
        "momentum_shadow ticker=#{ticker} " \
        "closes=#{sequence.map { |value| value.round(4) }.inspect} " \
        "#{verdicts.map { |name, ok| "#{name}=#{ok ? 1 : 0}" }.join(' ')} " \
        "active=#{rule} pass=#{verdicts.fetch(rule) ? 1 : 0}"
      )
      verdicts.fetch(rule)
    rescue StandardError => e
      logger&.debug("candles request failed for #{ticker}/#{figi}: #{e.class}: #{e.message}")
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

    def execute_intersection_buy_candidate!(logic, state, candidate, account_id:, logger: nil)
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

      sync_pending_order!(state, candidate[:tk], result)
      return handle_successful_intersection_buy!(state, candidate, result, logger: logger) if successful_buy_result?(result)

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
      register_daily_buy!(state, candidate[:price] * candidate[:lot] * candidate[:lots_per_order])
      true
    rescue StandardError
      true
    end

    def buy_execution_result?(result)
      category = result[:category].to_s
      result[:ok] == true || %w[filled partially_filled].include?(category)
    end

    def try_sell_positions_with_logic!(client, logic, account_id, state, figi_cache: {}, trend: :side, logger: nil)
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

        resp = begin
          logic.confirm_and_place_order(
            account_id: account_id,
            figi: figi,
            quantity: sell_qty,
            price: logic.last_price_for(figi),
            direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
            order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
          )
        rescue StandardError
          nil
        end
        if resp
          logger&.info("SELL #{ticker} lots=#{sell_qty} (order_id=#{resp.order_id})")
          mark_action!(state, 'last_sell', ticker, figi: figi, reason: 'signal')
        else
          logger&.info("SELL #{ticker} skipped / not confirmed")
        end
      end
    end

    def try_force_exit_positions_with_logic!(client, logic, account_id, figi_cache: {}, logger: nil)
      port = client.grpc_operations.portfolio(account_id: account_id)
      positions = port.positions
      positions.each do |p|
        try_force_exit_position!(client, logic, account_id, p, figi_cache: figi_cache, logger: logger)
      end
    end

    def try_force_exit_position!(client, logic, account_id, position, figi_cache: {}, logger: nil)
      figi = position.figi

      if position.respond_to?(:instrument_type)
        inst_type = position.instrument_type.to_s.upcase
        return unless inst_type.include?('SHARE')
      end

      qty_units = position.quantity.units.to_i
      return if qty_units <= 0
      return unless logic.should_force_exit?(position, figi)

      ticker = resolve_ticker_for_sell(client, figi: figi, figi_cache: figi_cache, logger: logger) || figi

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
      resp = begin
        logic.confirm_and_place_order(
          account_id: account_id,
          figi: figi,
          quantity: lots,
          price: cur_price,
          direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
          order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
        )
      rescue StandardError
        nil
      end

      if resp
        logger&.info("FORCE SELL +10% #{ticker} lots=#{lots} (#{qty_units} шт) @#{cur_price} (order_id=#{resp.order_id})")
      else
        logger&.info("FORCE SELL #{ticker} skipped / not confirmed")
      end
    end

    def load_state(path)
      return default_state unless File.exist?(path)

      ensure_state_defaults!(JSON.parse(File.read(path)))
    rescue StandardError
      default_state
    end

    def default_state
      { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {}, 'quarantine' => {}, 'daily_buys' => {} }
    end

    def ensure_state_defaults!(state)
      state ||= {}
      state['last_buy'] ||= {}
      state['last_sell'] ||= {}
      state['pending_orders'] ||= {}
      state['quarantine'] ||= {}
      state['daily_buys'] ||= {}
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
        class_code: share_attr(share, :class_code)
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

    # Считаем деньги ЗАНЯТЫМИ в момент отправки ордера, а не исполнения: лимитные
    # заявки исполняются асинхронно, и если ждать факта, за день можно наотправлять
    # заявок далеко за бюджет. Неисполненная заявка «съест» лимит до конца дня —
    # намеренный перекос в безопасную сторону.
    def buy_committed_result?(result)
      successful_buy_result?(result)
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

    def daily_buy_within_limit?(state, planned_buy_value, max_daily_rub: nil, logger: nil)
      max_daily_rub = (max_daily_rub || ENV['MAX_DAILY_BUY_RUB'] || 0).to_f
      return true unless max_daily_rub.positive?

      spent = daily_buy_total(state)
      planned = planned_buy_value.to_f
      return true if (spent + planned) <= max_daily_rub

      logger&.info(
        "daily buy budget reached: spent=#{spent.round(2)} + planned=#{planned.round(2)} " \
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

    def cleanup_pending_orders!(client, account_id, state, logger: nil)
      ensure_state_defaults!(state)
      pending = state['pending_orders']
      return if pending.empty?

      active_orders = fetch_active_orders(client, account_id, logger: logger)
      unless active_orders[:ok]
        logger&.warn(
          'pending cleanup skipped: active orders response is malformed/unavailable ' \
          "(reason=#{active_orders[:reason].inspect})"
        )
        return
      end

      to_delete = []
      pending.each do |ticker, info|
        migrate_pending_order_metadata!(client, ticker, info, active_orders: active_orders, logger: logger)

        unless pending_order_ids_present?(info)
          logger&.warn("pending order for #{ticker} has no known IDs — keeping entry for safety")
          next
        end

        next if active_pending_order?(info, active_orders)

        reconciliation = reconcile_missing_pending_order!(client, account_id, state, ticker, info, logger: logger)
        case reconciliation
        when :executed, :not_executed
          logger&.debug(
            "cleaned up pending order for #{ticker} " \
            "(client_id=#{info['client_order_id'].inspect}, broker_id=#{info['broker_order_id'].inspect})"
          )
          to_delete << ticker
        when :unknown
          logger&.warn("pending order for #{ticker} left untouched — execution status unknown")
        end
      end

      to_delete.each { |ticker| pending.delete(ticker) }
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

      orders.each do |order|
        broker_id = order_broker_id(order)
        client_id = order_request_id(order)

        broker_ids << broker_id if broker_id
        client_ids << client_id if client_id
        broker_by_client[client_id] = broker_id if client_id && broker_id
      end

      {
        ok: true,
        broker_order_ids: broker_ids,
        client_order_ids: client_ids,
        broker_id_by_client_id: broker_by_client
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
      status = pending_buy_execution_state(client, account_id, info, logger: logger)
      return :not_executed if status == :not_executed
      return :unknown if status == :unknown

      logger&.info("pending BUY resolved with execution for #{ticker} — marking last_buy")
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
        return :unknown
      end

      fetched = operations_between(client, account_id, from: from, to: to)
      return :unknown unless fetched[:ok]

      executed = fetched[:operations].any? do |op|
        operation_buy_executed_for_figi?(op, figi)
      end
      return :unknown if !executed && fetched[:has_next]

      executed ? :executed : :not_executed
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

    def sync_pending_order!(state, ticker, result)
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
          'status' => pending_status
        }
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

      operations.each do |op|
        kind = operation_kind(op)
        next unless kind

        figi = op.respond_to?(:figi) ? op.figi.to_s : ''
        next if figi.empty?

        ticker = resolve_ticker_for_sell(client, figi: figi, logger: logger)
        next unless ticker

        ts = operation_ts_iso8601(op)
        if kind == :buy
          state['last_buy'][day] ||= {}
          state['last_buy'][day][ticker] = true
        elsif kind == :sell
          state['last_sell'][ticker] = {
            'figi' => figi,
            'ts' => ts,
            'reason' => 'broker_restore'
          }
        end
      end

      restore_pending_buy_orders!(client, account_id, state, logger: logger)
      state
    rescue StandardError => e
      logger&.error("state restore from broker failed: #{e.class}: #{e.message}")
      state
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
      if order.respond_to?(:execution_report_status)
        order.execution_report_status.to_s.upcase
      elsif order.respond_to?(:status)
        order.status.to_s.upcase
      else
        ''
      end
    end

    def order_figi(order)
      order.respond_to?(:figi) ? order.figi.to_s : ''
    end

    def restored_pending_order_payload(order, ticker, pending_status)
      {
        'client_order_id' => order_request_id(order),
        'broker_order_id' => order_broker_id(order),
        'ticker' => ticker,
        'figi' => order_figi(order),
        'ts' => order_submitted_at(order) || Time.now.utc.iso8601,
        'status' => pending_status
      }
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
      value =
        if order.respond_to?(:lots_executed)
          order.lots_executed
        elsif order.respond_to?(:executed_order_lots)
          order.executed_order_lots
        end
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

    def active_pending_order?(info, active_orders)
      client_order_id = info['client_order_id'].to_s
      broker_order_id = info['broker_order_id'].to_s

      client_match = !client_order_id.empty? && active_orders[:client_order_ids].include?(client_order_id)
      broker_match = !broker_order_id.empty? && active_orders[:broker_order_ids].include?(broker_order_id)
      client_match || broker_match
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
