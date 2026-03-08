# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'net/http'
require 'json'
require_relative 'telegram_confirm'
require_relative 'market_cache'
require_relative 'strategy_helpers'
require_relative 'utils'

module TradingLogic
  class Runner
    DAY = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY
    MIN_5 = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_5_MIN

    TECHNICAL_ERROR_PATTERNS = [
      /deadline/i,
      /timeout/i,
      /temporar/i,
      /unavailable/i,
      /internal/i,
      /resource[_\s-]?exhausted/i,
      /connection\s+reset/i
    ].freeze

    def initialize(
      client,
      tickers:,
      max_lot_rub: 500.0,
      max_lot_count: 1,
      lots_per_order: 1,
      dip_pct: 0.01,
      min_relative_volume: nil,
      volume_lookback_days: 20,
      volume_compare_mode: 'none',
      telegram_bot_token: nil,
      telegram_chat_id: nil,
      use_levels: true,
      levels_lookback_days: 120,
      level_proximity_pct: 0.02,
      level_sell_min_profit: 1.005,
      level_pivot_window: 5,
      level_cluster_pct: 0.015
    )
      @client = client
      @tickers = tickers
      @max_lot = max_lot_rub
      @max_lot_count = max_lot_count
      @lots_per_order = lots_per_order
      @dip_pct = dip_pct
      @min_relative_volume = min_relative_volume
      @volume_lookback_days = volume_lookback_days
      @volume_compare_mode = volume_compare_mode
      @telegram = TelegramConfirm.new(bot_token: telegram_bot_token, chat_id: telegram_chat_id)
      @market_cache = MarketCache.new(@client)
      @use_levels = use_levels
      @levels_lookback_days = levels_lookback_days
      @level_proximity_pct = level_proximity_pct
      @level_sell_min_profit = level_sell_min_profit
      @level_pivot_window = level_pivot_window
      @level_cluster_pct = level_cluster_pct
      @levels_cache = {}
    end

    def refresh_market_cache(force: false)
      @market_cache.refresh_market_cache(force: force)
    end

    def load_market_cache
      @market_cache.load_market_cache
    end

    def q_to_decimal(q)
      Utils.q_to_decimal(q)
    end

    def figi_and_lot(ticker, class_code: 'TQBR')
      resp = Utils.safe_share_by_ticker(@client, ticker, class_code: class_code)
      return [nil, nil] unless resp&.instrument

      [resp.instrument.figi, resp.instrument.lot]
    end

    def last_price_for(figi)
      lp = @client.grpc_market_data.last_prices(figis: [figi])
      return nil if lp.last_prices.empty?

      Utils.q_to_decimal(lp.last_prices.first.price)
    end

    def prev_close_for(figi)
      resp = Utils.fetch_candles(@client, figi: figi, from: Utils.days_ago(3), to: Utils.now_utc, interval: DAY)
      candles = resp&.candles
      return nil unless candles && candles.size >= 2

      Utils.q_to_decimal(candles[-2].close)
    end

    # Сегодняшний intraday максимум по 5-мин свечам
    def today_high(figi)
      from = Utils.today_utc_start
      resp = Utils.fetch_candles(@client, figi: figi, from: from, to: Utils.now_utc, interval: MIN_5)
      highs = resp&.candles ? resp.candles.map { |c| Utils.q_to_decimal(c.high) }.compact : []
      return nil if highs.empty?

      highs.max
    end

    # Оценка относительного дневного объёма:
    # rvol = текущий дневной объём / средний объём предыдущих N дней
    def relative_daily_volume(figi, lookback_days: @volume_lookback_days)
      lookback = [lookback_days.to_i, 1].max
      # Берём заметно больший календарный диапазон, чтобы после выходных/праздников
      # осталось не меньше lookback торговых свечей в истории.
      calendar_days = [lookback * 3, lookback + 10].max
      resp = Utils.fetch_candles(
        @client,
        figi: figi,
        from: Utils.days_ago(calendar_days),
        to: Utils.now_utc,
        interval: DAY
      )

      candles = resp&.candles ? resp.candles : []
      return nil if candles.size < (lookback + 1)

      volumes = candles.map { |c| c.volume.to_f }.compact
      return nil if volumes.size < (lookback + 1)

      current = volumes[-1]
      history = volumes[0...-1].last(lookback)
      return nil if history.size < lookback

      avg = history.sum / history.size
      return nil if avg <= 0

      current / avg
    end

    # Денежный объём за текущий день по дневной свече: close * volume
    def daily_turnover_rub(figi)
      resp = Utils.fetch_candles(@client, figi: figi, from: Utils.days_ago(3), to: Utils.now_utc, interval: DAY)
      candle = resp&.candles&.last
      return nil unless candle

      close = Utils.q_to_decimal(candle.close)
      volume = candle.volume.to_f
      return nil unless close && volume.positive?

      close * volume
    end

    def volume_spike?(figi)
      return true unless @min_relative_volume&.positive?

      rvol = relative_daily_volume(figi)
      rvol && rvol >= @min_relative_volume
    end

    # Покупать только на «дневной просадке»: текущая цена <= (сегодняшний максимум * (1 - @dip_pct))
    def dip_today?(figi)
      cur = last_price_for(figi)
      th = today_high(figi)
      return false unless cur && th

      cur <= th * (1.0 - @dip_pct)
    end

    # Тренд индекса: «стабильно больше 2 дней» = 3 последовательных дневных закрытия
    # Возвращает :up, :down или :side
    def trend(index_figi)
      return :side unless index_figi

      resp = Utils.fetch_candles(@client, figi: index_figi, from: Utils.days_ago(6), to: Utils.now_utc, interval: DAY)
      closes = resp&.candles ? resp.candles.map { |c| Utils.q_to_decimal(c.close) }.compact : []
      return :side if closes.size < 4

      # последние 4 закрытия => последние 3 изменения
      a = closes[-4]
      b = closes[-3]
      c = closes[-2]
      d = closes[-1]
      return :up   if a < b && b < c && c < d
      return :down if a > b && b > c && c > d

      :side
    end

    def build_universe
      volume_enabled = volume_features_enabled?

      @tickers.map do |t|
        figi, lot = figi_and_lot(t)
        # skip if API lot count exceeds configured max_lot_count
        if @max_lot_count && lot.to_i > @max_lot_count.to_i
          warn "build_universe: skipping #{t} — lot=#{lot} > max_lot_count=#{@max_lot_count}"
          next
        end
        price = last_price_for(figi)
        next unless price && lot

        h = {
          ticker: t,
          figi: figi,
          lot: lot.to_i,
          price: price,
          price_per_lot: price * lot.to_i
        }

        if volume_enabled
          h[:relative_volume] = relative_daily_volume(figi)
          h[:daily_turnover_rub] = daily_turnover_rub(figi)
        end

        # фильтр по цене лота, если нужен
        if @max_lot
          total_price = h[:price_per_lot] * (@lots_per_order || 1)
          h if total_price <= @max_lot
        else
          h
        end
      rescue StandardError
        nil
      end.compact
    end

    # Покупаем на дневной просадке.
    # trend: — если :up и уровни включены, применяем hard filter по near_support?.
    # Graceful degradation: если уровней нет — покупаем по старым правилам.
    def should_buy?(it, trend: :side)
      return false unless dip_today?(it[:figi]) && volume_spike?(it[:figi])
      return true unless @use_levels && trend == :up

      levels = levels_for(it[:figi])
      return true if levels.empty?

      near_support?(it[:figi], it[:price])
    end

    # Сортировка кандидатов по объёмам между бумагами
    def rank_universe_by_volume(universe)
      case @volume_compare_mode
      when 'relative'
        universe.sort_by { |u| -(u[:relative_volume] || 0.0) }
      when 'turnover'
        universe.sort_by { |u| -(u[:daily_turnover_rub] || 0.0) }
      else
        universe
      end
    end

    def volume_features_enabled?
      @min_relative_volume&.positive? || %w[relative turnover].include?(@volume_compare_mode)
    end

    # Продаём, если текущая цена >= средней покупки * порог.
    # Порог зависит от тренда: UP=+10%, SIDE=+4%, DOWN=+2%.
    # Можно переопределить через ENV: SELL_THRESHOLD_UP, SELL_THRESHOLD_SIDE, SELL_THRESHOLD_DOWN.
    # Доп. триггер: если уровни включены и цена у сопротивления (с min profit).
    def should_sell?(position, it, trend: :side)
      qty_units = position.quantity.units.to_i
      return false if qty_units <= 0

      avg = Utils.q_to_decimal(position.average_position_price)
      cur = last_price_for(it[:figi])
      return false unless avg && cur && avg.positive?

      threshold = sell_threshold_for_trend(trend)
      return true if (cur / avg) >= threshold

      if @use_levels && (cur / avg) >= @level_sell_min_profit
        levels = levels_for(it[:figi])
        return true if !levels.empty? && near_resistance?(it[:figi], cur)
      end

      false
    end

    def sell_threshold_for_trend(trend)
      case trend
      when :up
        (ENV['SELL_THRESHOLD_UP'] || '1.10').to_f
      when :down
        (ENV['SELL_THRESHOLD_DOWN'] || '1.02').to_f
      else
        (ENV['SELL_THRESHOLD_SIDE'] || '1.04').to_f
      end
    end

    def confirm_and_place_order(account_id:, figi:, quantity:, price:, direction:, order_type:)
      result = confirm_and_place_order_with_result(
        account_id: account_id,
        figi: figi,
        quantity: quantity,
        price: price,
        direction: direction,
        order_type: order_type
      )
      result[:response]
    end

    def confirm_and_place_order_with_result(account_id:, figi:, quantity:, price:, direction:, order_type:,
                                            max_retries: 2, retry_delay_seconds: 1)
      side = direction == ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY ? 'BUY' : 'SELL'
      prompt = "*Confirm #{side}*\nfigi: #{figi}\nqty: #{quantity}\nprice: #{price}\naccount: #{account_id}"

      # Если переменная окружения AUTO_CONFIRM установлена в "1" или "true",
      # пропускаем подтверждение и сразу размещаем ордер.
      confirmed = if %w[1 true].include?(ENV['AUTO_CONFIRM'])
                    true
                  elsif @telegram.respond_to?(:confirm?)
                    @telegram.confirm?(prompt, timeout: 120)
                  else
                    # Если нет Telegram-клиента, и AUTO_CONFIRM не включён — считаем как не подтверждённое.
                    false
                  end

      return { ok: false, category: :not_sent, status: 'not_sent', response: nil } unless confirmed

      client_order_id = SecureRandom.uuid
      attempts = 0

      begin
        attempts += 1
        response = @client.grpc_orders.post_order(
          account_id: account_id,
          figi: figi,
          quantity: quantity,
          price: price,
          direction: direction,
          order_type: order_type,
          order_id: client_order_id
        )

        status = normalize_order_status(response)
        reject_reason = extract_response_field(response, :reject_reason)
        error_code = extract_response_field(response, :error_code)

        category, ok = categorize_order_status(status)
        {
          ok: ok,
          category: category,
          status: status,
          response: response,
          client_order_id: client_order_id,
          reject_reason: reject_reason,
          error_code: error_code
        }
      rescue StandardError => e
        technical = technical_api_error?(e)
        if technical && attempts <= max_retries
          warn "post_order retry ##{attempts} due to technical API error: #{e.class}: #{e.message}"
          sleep retry_delay_seconds
          retry
        end

        {
          ok: false,
          category: :api_error,
          status: 'api_error',
          response: nil,
          client_order_id: client_order_id,
          reject_reason: e.message,
          error_code: e.class.to_s,
          technical_error: technical
        }
      end
    end

    # Кэшированный доступ к уровням поддержки/сопротивления для figi.
    def levels_for(figi)
      @levels_cache[figi] ||= compute_support_resistance(figi)
    end

    # Рассчитывает уровни поддержки и сопротивления по дневным свечам.
    # Возвращает [] при недостатке данных или ошибке.
    def compute_support_resistance(figi)
      calendar_days = [@levels_lookback_days * 2, @levels_lookback_days + 30].max
      resp = Utils.fetch_candles(
        @client,
        figi: figi,
        from: Utils.days_ago(calendar_days),
        to: Utils.now_utc,
        interval: DAY
      )
      candles = resp&.candles.to_a
      today_str = Utils.now_utc.strftime('%Y-%m-%d')
      # только закрытые свечи (без текущей незавершённой)
      candles = candles.reject { |c| Time.at(c.time.seconds).utc.strftime('%Y-%m-%d') == today_str }
      candles = candles.last(@levels_lookback_days)

      w = @level_pivot_window
      return [] if candles.size < (w * 2 + 1)

      lows = candles.map { |c| Utils.q_to_decimal(c.low) }
      highs = candles.map { |c| Utils.q_to_decimal(c.high) }

      support_prices = []
      resistance_prices = []

      (w...(candles.size - w)).each do |i|
        l = lows[i]
        h = highs[i]

        left_lows  = lows[(i - w)...i]
        right_lows = lows[(i + 1)..(i + w)]
        support_prices << l if l && left_lows.all? { |v| v > l } && right_lows.all? { |v| v > l }

        left_highs  = highs[(i - w)...i]
        right_highs = highs[(i + 1)..(i + w)]
        resistance_prices << h if h && left_highs.all? { |v| v < h } && right_highs.all? { |v| v < h }
      end

      supports   = cluster_levels(support_prices,   @level_cluster_pct).map { |p, s| { price: p, type: :support,    strength: s } }
      resistances = cluster_levels(resistance_prices, @level_cluster_pct).map { |p, s| { price: p, type: :resistance, strength: s } }

      (supports + resistances).sort_by { |l| l[:price] }
    rescue StandardError
      []
    end

    # Ближайший support-уровень <= price, или nil. Возвращает nil если уровни отключены.
    def nearest_support(figi, price)
      return nil unless @use_levels

      levels_for(figi).select { |l| l[:type] == :support && l[:price] <= price }.max_by { |l| l[:price] }
    end

    # Ближайший resistance-уровень >= price, или nil. Возвращает nil если уровни отключены.
    def nearest_resistance(figi, price)
      return nil unless @use_levels

      levels_for(figi).select { |l| l[:type] == :resistance && l[:price] >= price }.min_by { |l| l[:price] }
    end

    # Цена в пределах level_proximity_pct от ближайшего support?
    def near_support?(figi, price)
      lvl = nearest_support(figi, price)
      return false unless lvl

      distance = (price - lvl[:price]) / lvl[:price]
      distance <= @level_proximity_pct
    end

    # Цена в пределах level_proximity_pct от ближайшего resistance?
    def near_resistance?(figi, price)
      lvl = nearest_resistance(figi, price)
      return false unless lvl

      distance = (lvl[:price] - price) / lvl[:price]
      distance <= @level_proximity_pct
    end

    # Отладочная информация по уровням для тикера
    def level_debug_info(figi, price)
      return 'levels disabled' unless @use_levels

      levels = levels_for(figi)
      return 'no levels computed' if levels.empty?

      sup = nearest_support(figi, price)
      res = nearest_resistance(figi, price)
      sup_str = sup ? "support=#{sup[:price].round(2)} dist=#{((price - sup[:price]) / sup[:price] * 100).round(2)}% str=#{sup[:strength]}" : 'no support'
      res_str = res ? "resistance=#{res[:price].round(2)} dist=#{((res[:price] - price) / res[:price] * 100).round(2)}% str=#{res[:strength]}" : 'no resistance'
      "#{sup_str} | #{res_str} (total levels: #{levels.size})"
    end

    private

    # Кластеризует массив цен: группирует точки в пределах cluster_pct друг от друга.
    # Возвращает массив [средняя_цена, количество_точек].
    def cluster_levels(prices, cluster_pct)
      sorted = prices.compact.sort
      clusters = []
      sorted.each do |p|
        added = false
        clusters.each do |cluster|
          center = cluster.sum / cluster.size
          if (p - center).abs / center <= cluster_pct
            cluster << p
            added = true
            break
          end
        end
        clusters << [p] unless added
      end
      clusters.map { |cluster| [cluster.sum / cluster.size, cluster.size] }
    end

    def technical_api_error?(error)
      text = "#{error.class} #{error.message}"
      TECHNICAL_ERROR_PATTERNS.any? { |pattern| text.match?(pattern) }
    end

    def normalize_order_status(response)
      raw = extract_response_field(response, :execution_report_status)
      str = raw.to_s.downcase

      return 'fill' if str.include?('fill') && !str.include?('partial')
      return 'partially_fill' if str.include?('partially') || str.include?('partial')
      return 'rejected' if str.include?('reject')
      return 'cancelled' if str.include?('cancel')
      return 'new' if str.include?('new') || str.include?('accepted')

      str.empty? ? 'unknown' : str
    end

    def categorize_order_status(status)
      case status
      when 'fill'
        [:filled, true]
      when 'rejected', 'cancelled'
        [:broker_rejected, false]
      when 'partially_fill'
        [:partially_filled, false]
      else
        [:sent_not_filled, false]
      end
    end

    def extract_response_field(response, field)
      return nil unless response

      return response.public_send(field) if response.respond_to?(field)

      key = field.to_s
      if response.respond_to?(:to_h)
        hash = response.to_h
        return hash[field] if hash.key?(field)
        return hash[key] if hash.key?(key)
      end
      nil
    end

    public

    # Мультипликатор профита (текущая / средняя). nil если не вычислить.
    def profit_multiple(position, figi)
      avg = Utils.q_to_decimal(position.average_position_price)
      cur = last_price_for(figi)
      return nil unless avg && cur && avg.positive?

      cur / avg
    end

    # Принудительная продажа всего при +10% (>= 1.10)
    def should_force_exit?(position, figi)
      m = profit_multiple(position, figi)
      m && m >= 1.10
    end
  end
end
