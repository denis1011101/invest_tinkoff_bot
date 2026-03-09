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
      market = load_cache_normalized(market_cache_path)
      index  = load_cache_normalized(moex_index_cache_path)

      market_tickers = market.map { |i| i['ticker'] }.compact.uniq
      index_tickers  = index.map { |i| i['ticker'] }.compact.uniq

      logger&.debug("market_tickers=#{market_tickers.size} sample=#{market_tickers.sample(5).inspect}")
      logger&.debug("index_tickers=#{index_tickers.size} sample=#{index_tickers.sample(5).inspect}")

      inter = market_tickers & index_tickers
      logger&.debug("intersection candidates=#{inter.size} #{inter.sample(10).inspect}")

      return false if inter.empty?

      candidates = inter.filter_map do |ticker|
        build_intersection_candidate(
          client, logic, state, market, ticker,
          max_lot_rub: max_lot_rub,
          account_id: account_id,
          lots_per_order: lots_per_order,
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

    def build_intersection_candidate(client, logic, state, market, ticker, max_lot_rub:, account_id:, lots_per_order:,
                                     logger: nil)
      logger&.debug("processing candidate #{ticker}")
      return nil if buy_already_processed_today?(state, ticker)

      item = market.find { |market_item| market_item['ticker'] == ticker } || {}
      logger&.debug("market item for #{ticker} => #{item.keys.inspect}")

      figi = resolve_candidate_figi(client, ticker, item, logger: logger)
      return nil unless figi
      return nil unless valid_momentum_candidate?(client, ticker, figi, logger: logger)

      lot = (item.dig('raw', 'lot') || item.dig('raw', 'LOT') || 1).to_i
      price = logic.last_price_for(figi) || item.dig('raw', 'price')
      price_per_lot = price && lot ? (price * lot) : nil
      logger&.debug("#{ticker} lot=#{lot.inspect} price=#{price.inspect} price_per_lot=#{price_per_lot.inspect}")

      unless affordable_candidate?(price, lot, lots_per_order, max_lot_rub)
        logger&.debug("skip #{ticker} — price/lot missing or too expensive")
        return nil
      end

      unless logic.dip_today?(figi)
        logger&.debug("skip #{ticker} — momentum OK but no intraday dip")
        return nil
      end

      if pending_order_active?(state, ticker)
        logger&.debug("BUY skipped for #{ticker} — active pending order cooldown")
        return nil
      end

      buy_value = price * lot * lots_per_order
      unless position_within_limit?(client, account_id, figi, planned_buy_value: buy_value, logger: logger)
        logger&.debug("BUY skipped for #{ticker} — position share limit reached")
        return nil
      end

      support_distance = support_distance_for_candidate(logic, figi, price)
      logger&.debug("#{ticker} support_distance=#{support_distance.round(4)}")

      { tk: ticker, figi: figi, lot: lot, price: price, lots_per_order: lots_per_order, support_distance: support_distance }
    end

    def buy_already_processed_today?(state, ticker)
      acted_today?(state, 'last_buy', ticker)
    rescue StandardError
      false
    end

    def resolve_candidate_figi(client, ticker, item, logger: nil)
      figi = item['figi']
      if figi
        logger&.debug("item already contains figi=#{figi}")
        return figi
      end

      response = client.grpc_instruments.find_instrument(query: ticker)
      figi = response&.instruments&.first&.figi
      logger&.debug("resolved figi for #{ticker} => #{figi.inspect}")
      logger&.debug("skip #{ticker} — no figi") unless figi
      figi
    rescue StandardError => e
      logger&.debug("find_instrument(#{ticker}) error: #{e.class}: #{e.message}")
      nil
    end

    def valid_momentum_candidate?(client, ticker, figi, logger: nil)
      response = client.grpc_market_data.candles(
        figi: figi,
        from: (Time.now.utc - (8 * 86_400)),
        to: Time.now.utc,
        interval: ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY
      )
      closes = (response&.candles || []).map { |c| Utils.q_to_decimal(c.close) }.compact
      logger&.debug("#{ticker} closes_count=#{closes.size} sample_last=#{closes.last(5).inspect}")

      if closes.size < 4
        logger&.debug("skip #{ticker} — not enough daily closes (need 4 for 3 consecutive increases)")
        return false
      end

      sequence = closes.last(4)
      return true if sequence.each_cons(2).all? { |left, right| left < right }

      logger&.debug("skip #{ticker} — not 3-day momentum (#{sequence.map { |value| value.round(2) }.inspect})")
      false
    rescue StandardError => e
      logger&.debug("candles request failed for #{ticker}/#{figi}: #{e.class}: #{e.message}")
      false
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
          quantity: candidate[:lot] * candidate[:lots_per_order],
          price: candidate[:price],
          direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY,
          order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
        )
      rescue StandardError
        { ok: false, category: :api_error, status: 'api_error', reject_reason: 'unexpected error', error_code: 'UNKNOWN' }
      end

      sync_pending_order!(state, candidate[:tk], result)
      return handle_successful_intersection_buy!(state, candidate, result, logger: logger) if successful_buy_result?(result)

      logger&.warn(buy_failure_message(candidate[:tk], result))
      false
    end

    def successful_buy_result?(result)
      result[:ok] || %w[filled sent_not_filled partially_filled].include?(result[:category].to_s)
    end

    def handle_successful_intersection_buy!(state, candidate, result, logger: nil)
      response = result[:response]
      logger&.debug("BUY accepted for #{candidate[:tk]} (figi=#{candidate[:figi]}) order_id=#{response&.order_id}")
      mark_action!(state, 'last_buy', candidate[:tk])
      true
    rescue StandardError
      true
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

        sell_qty = [qty_units, lot].min
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
          logger&.info("SELL #{ticker} qty=#{sell_qty} (order_id=#{resp.order_id})")
          mark_action!(state, 'last_sell', ticker, figi: figi, reason: 'signal')
        else
          logger&.info("SELL #{ticker} skipped / not confirmed")
        end
      end
    end

    def load_state(path)
      return default_state unless File.exist?(path)

      ensure_state_defaults!(JSON.parse(File.read(path)))
    rescue StandardError
      default_state
    end

    def default_state
      { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {} }
    end

    def ensure_state_defaults!(state)
      state ||= {}
      state['last_buy'] ||= {}
      state['last_sell'] ||= {}
      state['pending_orders'] ||= {}
      state
    end

    def pending_order_active?(state, ticker)
      pending = (state['pending_orders'] || {})[ticker]
      return false unless pending.is_a?(Hash)

      status = pending['status'].to_s
      return false unless %w[sent_not_filled partially_filled].include?(status)

      ts = begin
        Time.parse(pending['ts'].to_s)
      rescue StandardError
        nil
      end
      return false unless ts

      cooldown = (ENV['BUY_PENDING_COOLDOWN_MIN'] || '10').to_i * 60
      (Time.now.utc - ts) < cooldown
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

      active_order_ids = begin
        resp = client.grpc_orders.get_orders(account_id: account_id)
        orders = resp.respond_to?(:orders) ? resp.orders : []
        Set.new(orders.filter_map do |o|
          o.respond_to?(:order_id) ? o.order_id.to_s : nil
        end)
      rescue StandardError
        nil
      end
      return unless active_order_ids

      pending.delete_if do |ticker, info|
        order_id = info['client_order_id'].to_s
        next false if order_id.empty?

        unless active_order_ids.include?(order_id)
          logger&.debug("cleaned up pending order for #{ticker} (order_id=#{order_id})")
          true
        end
      end
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
        state['pending_orders'][ticker] = {
          'client_order_id' => result[:client_order_id],
          'ticker' => ticker,
          'ts' => Time.now.utc.iso8601,
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
      orders = resp.respond_to?(:orders) ? resp.orders : []
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
        'client_order_id' => restored_order_id(order),
        'ticker' => ticker,
        'ts' => Time.now.utc.iso8601,
        'status' => pending_status
      }
    end

    def restored_order_id(order)
      if order.respond_to?(:order_id)
        order.order_id
      elsif order.respond_to?(:order_request_id)
        order.order_request_id
      end
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
