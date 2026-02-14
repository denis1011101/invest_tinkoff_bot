# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'utils'

module TradingLogic
  module StrategyHelpers
    module_function

    def load_cache_normalized(path)
      return [] unless File.exist?(path)

      raw = JSON.parse(File.read(path)) rescue {}
      arr = raw['instruments'] || raw['instruments_list'] || []
      arr.map do |h|
        # поддерживаем разные форматы: string keys or symbol keys
        hh = h.transform_keys(&:to_s)
        ticker = hh['ticker'] || hh['secid'] || hh['seccode'] || hh['seccode_short']
        figi   = hh['figi'] || hh['FIGI'] || nil
        { 'ticker' => ticker && ticker.to_s, 'figi' => figi, 'raw' => hh }
      end.compact
    end

    def read_json(path)
      return {} unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue
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

      a, b, c = closes[-3], closes[-2], closes[-1]
      a < b && b < c
    end

    def find_instrument_by_ticker(client, ticker)
      resp = client.grpc_instruments.find_instrument(query: ticker.to_s)
      resp.instruments.first
    rescue
      nil
    end

    # Возвращает true если купили одну бумагу из пересечения по правилу 3d momentum
    def buy_one_momentum_from_intersection!(client, logic, state, market_cache_path:, moex_index_cache_path:, max_lot_rub:, lots_per_order: 1, account_id:)
      market = load_cache_normalized(market_cache_path)
      index  = load_cache_normalized(moex_index_cache_path)

      market_tickers = market.map { |i| i['ticker'] }.compact.uniq
      index_tickers  = index.map { |i| i['ticker'] }.compact.uniq

      warn "DEBUG: market_tickers=#{market_tickers.size} sample=#{market_tickers.sample(5).inspect}"
      warn "DEBUG: index_tickers=#{index_tickers.size} sample=#{index_tickers.sample(5).inspect}"

      inter = market_tickers & index_tickers
      warn "DEBUG: intersection candidates=#{inter.size} #{inter.sample(10).inspect}"

      return false if inter.empty?

      inter.each do |tk|
        warn "DEBUG: processing candidate #{tk}"
        next if acted_today?(state, 'last_buy', tk) rescue (warn("DEBUG: acted_today? failed for #{tk}"); false)

        item = market.find { |m| m['ticker'] == tk } || {}
        warn "DEBUG: market item for #{tk} => #{item.keys.inspect}"

        figi = item['figi']
        if figi.nil?
          begin
            r = client.grpc_instruments.find_instrument(query: tk) rescue nil
            figi = r&.instruments&.first&.figi
            warn "DEBUG: resolved figi for #{tk} => #{figi.inspect}"
          rescue => e
            warn "DEBUG: find_instrument(#{tk}) error: #{e.class}: #{e.message}"
            figi = nil
          end
        else
          warn "DEBUG: item already contains figi=#{figi}"
        end

        unless figi
          warn "DEBUG: skip #{tk} — no figi"
          next
        end

        # проверка 3 последовательных дневных закрытий вверх (нужны 4 закрытия для 3 приростов)
        begin
          resp = client.grpc_market_data.candles(
            figi: figi,
            from: (Time.now.utc - 8 * 86_400),
            to: Time.now.utc,
            interval: ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY
          )
        rescue => e
          warn "DEBUG: candles request failed for #{tk}/#{figi}: #{e.class}: #{e.message}"
          next
        end

        closes = (resp&.candles || []).map { |c| Utils.q_to_decimal(c.close) }.compact
        warn "DEBUG: #{tk} closes_count=#{closes.size} sample_last=#{closes.last(5).inspect}"

        if closes.size < 4
          warn "DEBUG: skip #{tk} — not enough daily closes (need 4 for 3 consecutive increases)"
          next
        end

        a, b, c, d = closes[-4], closes[-3], closes[-2], closes[-1]
        unless a < b && b < c && c < d
          warn "DEBUG: skip #{tk} — not 3-day momentum (#{[a,b,c,d].map { |v| v.round(2) }.inspect})"
          next
        end

        lot = item['raw'] && (item['raw']['lot'] || item['raw']['LOT']) || 1
        price = logic.last_price_for(figi) || (item['raw'] && item['raw']['price'])
        warn "DEBUG: #{tk} lot=#{lot.inspect} price=#{price.inspect} price_per_lot=#{(price && lot ? price * lot : nil).inspect}"

        unless price && lot && (price * lot * lots_per_order <= (max_lot_rub || 1_0_000))
          warn "DEBUG: skip #{tk} — price/lot missing or too expensive"
          next
        end

        if pending_order_active?(state, tk)
          warn "DEBUG: BUY skipped for #{tk} — active pending order cooldown"
          next
        end

        result = logic.confirm_and_place_order_with_result(
          account_id: account_id,
          figi: figi,
          quantity: lot * lots_per_order,
          price: price,
          direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY,
          order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
        ) rescue { ok: false, category: :api_error, status: 'api_error', reject_reason: 'unexpected error', error_code: 'UNKNOWN' }

        sync_pending_order!(state, tk, result)

        successful_buy = result[:ok] || %w[filled sent_not_filled partially_filled].include?(result[:category].to_s)
        if successful_buy
          resp_order = result[:response]
          warn "DEBUG: BUY accepted for #{tk} (figi=#{figi}) order_id=#{resp_order&.order_id}"
          mark_action!(state, 'last_buy', tk) rescue nil
          return true
        end

        warn buy_failure_message(tk, result)
      end

      false
    end

    def try_sell_positions_with_logic!(client, logic, account_id, state)
      port = client.grpc_operations.portfolio(account_id: account_id)
      positions = port.positions
      positions.each do |p|
        figi = p.figi
        qty_units = p.quantity.units.to_i
        next if qty_units <= 0

        inst = begin
          client.grpc_instruments.get_instrument_by(:figi, figi)
        rescue
          nil
        end
        ticker = (inst&.ticker || 'UNKNOWN').to_s.upcase
        next if acted_today?(state, 'last_sell', ticker)

        lot = inst&.lot.to_i
        lot = 1 if lot <= 0
        it = { figi: figi, ticker: ticker, lot: lot }
        next unless logic.should_sell?(p, it)

        sell_qty = [qty_units, lot].min
        resp = logic.confirm_and_place_order(
          account_id: account_id,
          figi: figi,
          quantity: sell_qty,
          price: logic.last_price_for(figi),
          direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
          order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
        ) rescue nil
        if resp
          puts "SELL #{ticker} qty=#{sell_qty} (order_id=#{resp.order_id})"
          mark_action!(state, 'last_sell', ticker)
        else
          puts "SELL #{ticker} skipped / not confirmed"
        end
      end
    end

    def load_state(path)
      return default_state unless File.exist?(path)

      ensure_state_defaults!(JSON.parse(File.read(path)))
    rescue
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

      ts = Time.parse(pending['ts'].to_s) rescue nil
      return false unless ts

      cooldown = (ENV['BUY_PENDING_COOLDOWN_MIN'] || '10').to_i * 60
      (Time.now.utc - ts) < cooldown
    end

    def sync_pending_order!(state, ticker, result)
      ensure_state_defaults!(state)
      category = result[:category].to_s
      pending_status =
        case category
        when 'sent_not_filled' then 'sent_not_filled'
        when 'partially_filled' then 'partially_filled'
        else nil
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

    def today_key
      Time.now.utc.strftime('%Y-%m-%d')
    end

    def acted_today?(state, action, ticker)
      day = today_key
      ((state[action] || {})[day] || {})[ticker] == true
    end

    def mark_action!(state, action, ticker)
      day = today_key
      state[action] ||= {}
      state[action][day] ||= {}
      state[action][day][ticker] = true
    end
  end
end
