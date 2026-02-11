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
      telegram_chat_id: nil
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
    end

    def refresh_market_cache(force: false)
      @market_cache.refresh_market_cache(force: force)
    end

    def load_market_cache
      @market_cache.load_market_cache
    end

    def figi_and_lot(ticker, class_code: 'TQBR')
      resp = Utils.safe_share_by_ticker(@client, ticker, class_code: class_code)
      return [nil, nil] unless resp && resp.instrument

      [resp.instrument.figi, resp.instrument.lot]
    end

    def last_price_for(figi)
      lp = @client.grpc_market_data.last_prices(figis: [figi])
      return nil if lp.last_prices.empty?

      Utils.q_to_decimal(lp.last_prices.first.price)
    end

    def prev_close_for(figi)
      resp = Utils.fetch_candles(@client, figi: figi, from: Utils.days_ago(3), to: Utils.now_utc, interval: DAY)
      candles = resp && resp.candles
      return nil unless candles && candles.size >= 2

      Utils.q_to_decimal(candles[-2].close)
    end

    # Сегодняшний intraday максимум по 5-мин свечам
    def today_high(figi)
      from = Utils.today_utc_start
      resp = Utils.fetch_candles(@client, figi: figi, from: from, to: Utils.now_utc, interval: MIN_5)
      highs = resp && resp.candles ? resp.candles.map { |c| Utils.q_to_decimal(c.high) }.compact : []
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

      candles = resp && resp.candles ? resp.candles : []
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
      candle = resp && resp.candles ? resp.candles.last : nil
      return nil unless candle

      close = Utils.q_to_decimal(candle.close)
      volume = candle.volume.to_f
      return nil unless close && volume.positive?

      close * volume
    end

    def volume_spike?(figi)
      return true unless @min_relative_volume && @min_relative_volume.positive?

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
      closes = resp && resp.candles ? resp.candles.map { |c| Utils.q_to_decimal(c.close) }.compact : []
      return :side if closes.size < 4

      # последние 4 закрытия => последние 3 изменения
      a, b, c, d = closes[-4], closes[-3], closes[-2], closes[-1]
      return :up   if a < b && b < c && c < d
      return :down if a > b && b > c && c > d

      :side
    end

    def build_universe
      volume_enabled = volume_features_enabled?

      @tickers.map do |t|
        begin
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
        rescue InvestTinkoff::GRPC::Error
          nil
        end
      end.compact
    end

    # Покупаем на дневной просадке
    def should_buy?(it)
      dip_today?(it[:figi]) && volume_spike?(it[:figi])
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
      (@min_relative_volume && @min_relative_volume.positive?) || %w[relative turnover].include?(@volume_compare_mode)
    end

    # Продаём, если текущая цена >= средней покупки * 1.10 и есть позиция
    def should_sell?(position, it)
      qty_units = position.quantity.units.to_i
      return false if qty_units <= 0

      avg = Utils.q_to_decimal(position.average_position_price)
      cur = last_price_for(it[:figi])
      return false unless avg && cur

      cur >= (avg * 1.10)
    end

    def confirm_and_place_order(account_id:, figi:, quantity:, price:, direction:, order_type:)
      side = (direction == ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY) ? 'BUY' : 'SELL'
      prompt = "*Confirm #{side}*\nfigi: #{figi}\nqty: #{quantity}\nprice: #{price}\naccount: #{account_id}"

      # Если переменная окружения AUTO_CONFIRM установлена в "1" или "true",
      # пропускаем подтверждение и сразу размещаем ордер.
      if ENV['AUTO_CONFIRM'] == '1' || ENV['AUTO_CONFIRM'] == 'true'
        confirmed = true
      elsif @telegram && @telegram.respond_to?(:confirm?)
        confirmed = @telegram.confirm?(prompt, timeout: 120)
      else
        # Если нет Telegram-клиента, и AUTO_CONFIRM не включён — считаем как не подтверждённое.
        confirmed = false
      end

      return nil unless confirmed

      @client.grpc_orders.post_order(
        account_id: account_id,
        figi: figi,
        quantity: quantity,
        price: price,
        direction: direction,
        order_type: order_type,
        order_id: SecureRandom.uuid
      )
    end

    # Мультипликатор профита (текущая / средняя). nil если не вычислить.
    def profit_multiple(position, figi)
      avg = Utils.q_to_decimal(position.average_position_price)
      cur = last_price_for(figi)
      return nil unless avg && cur && avg > 0

      cur / avg
    end

    # Принудительная продажа всего при +10% (>= 1.10)
    def should_force_exit?(position, figi)
      m = profit_multiple(position, figi)
      m && m >= 1.10
    end
  end
end
