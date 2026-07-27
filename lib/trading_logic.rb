# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'net/http'
require 'json'
require_relative 'telegram_confirm'
require_relative 'market_cache'
require_relative 'strategy_helpers'
require_relative 'level_analysis'
require_relative 'utils'

module TradingLogic
  class Runner # rubocop:disable Metrics/ClassLength
    include LevelAnalysis

    DAY = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY
    MIN_5 = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_5_MIN
    DEFAULT_OPTIONS = {
      max_lot_rub: 500.0,
      max_lot_count: nil,
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
      level_cluster_pct: 0.015,
      levels_cache_ttl_seconds: 300,
      up_require_support: false,
      up_entry_ma_days: 5
    }.freeze

    # Нижняя граница доли сессии при нормировке rvol: до открытия торгов делить
    # на ~0 нельзя, а объём там и так near-zero → rvol выйдет низким, что верно.
    MIN_SESSION_FRACTION = 0.05

    TECHNICAL_ERROR_PATTERNS = [
      /deadline/i,
      /timeout/i,
      /temporar/i,
      /unavailable/i,
      /internal/i,
      /resource[_\s-]?exhausted/i,
      /connection\s+reset/i
    ].freeze

    def initialize(client, tickers:, **options)
      settings = DEFAULT_OPTIONS.merge(options)
      validate_level_settings!(settings)

      @client = client
      @tickers = tickers
      @max_lot = settings[:max_lot_rub]
      @max_lot_count = settings[:max_lot_count]
      @lots_per_order = settings[:lots_per_order]
      @dip_pct = settings[:dip_pct]
      @min_relative_volume = settings[:min_relative_volume]
      @volume_lookback_days = settings[:volume_lookback_days]
      @volume_compare_mode = settings[:volume_compare_mode]
      @telegram = TelegramConfirm.new(
        bot_token: settings[:telegram_bot_token],
        chat_id: settings[:telegram_chat_id]
      )
      @market_cache = MarketCache.new(@client)
      @use_levels = settings[:use_levels]
      @levels_lookback_days = settings[:levels_lookback_days]
      @level_proximity_pct = settings[:level_proximity_pct]
      @level_sell_min_profit = settings[:level_sell_min_profit]
      @level_pivot_window = settings[:level_pivot_window]
      @level_cluster_pct = settings[:level_cluster_pct]
      @levels_cache_ttl_seconds = settings[:levels_cache_ttl_seconds]
      @up_require_support = settings[:up_require_support]
      @up_entry_ma_days = settings[:up_entry_ma_days]
      @levels_cache = {}
      @volume_stats_cache = {}
    end

    def refresh_market_cache(force: false)
      @market_cache.refresh_market_cache(force: force)
    end

    def load_market_cache
      @market_cache.load_market_cache
    end

    def figi_and_lot(ticker, class_code: 'TQBR')
      share = StrategyHelpers.resolve_tradable_share(@client, ticker, class_code: class_code)
      return [nil, nil] unless share

      [share[:figi], share[:lot]]
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
    # rvol = текущий дневной объём / средний объём предыдущих N дней.
    #
    # ВАЖНО: дневная свеча текущего дня накапливает объём по ходу сессии, а история —
    # это ПОЛНЫЕ дни. Без поправки метрика механически растёт к вечеру (факт по логу
    # 27.07.2026, SBER: 0.43 → 0.52 → 0.68 → 0.83 → 0.94 → 1.18 → 1.32 к закрытию),
    # и порог вроде 1.5 недостижим до последнего часа торгов.
    # Поэтому при незакрытом дне делим на ожидаемую к этому моменту долю сессии.
    # normalize: false возвращает сырое отношение (для диагностики/сравнения).
    def relative_daily_volume(figi, lookback_days: @volume_lookback_days, normalize: true)
      stats = daily_volume_stats(figi, lookback_days: lookback_days)
      return nil unless stats

      normalize ? stats[:normalized] : stats[:raw]
    end

    # Сырое и нормированное отношение за один запрос свечей — чтобы решение о покупке
    # и его лог не удваивали обращения к API. Кеш живёт в пределах процесса, а каждый
    # запуск по cron — новый процесс, поэтому протухнуть не может.
    def daily_volume_stats(figi, lookback_days: @volume_lookback_days)
      key = [figi, lookback_days]
      return @volume_stats_cache[key] if @volume_stats_cache.key?(key)

      @volume_stats_cache[key] = compute_daily_volume_stats(figi, lookback_days: lookback_days)
    end

    def compute_daily_volume_stats(figi, lookback_days: @volume_lookback_days)
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

      raw = current / avg
      { raw: raw, normalized: raw / partial_day_fraction(candles[-1]) }
    end

    # Доля дневного объёма, которую можно ожидать к текущему моменту.
    # 1.0 для завершённого дня (последняя свеча — не сегодняшняя): поправка не нужна.
    def partial_day_fraction(last_candle)
      return 1.0 unless Utils.candle_of_today?(last_candle)

      [Utils.session_volume_fraction, MIN_SESSION_FRACTION].max
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
      volume_ok?(daily_volume_stats(figi))
    end

    def volume_ok?(stats)
      return true unless @min_relative_volume&.positive?

      !stats.nil? && stats[:normalized] >= @min_relative_volume
    end

    # Покупать только на «дневной просадке»: текущая цена <= (сегодняшний максимум * (1 - @dip_pct))
    def dip_today?(figi)
      cur = last_price_for(figi)
      th = today_high(figi)
      return false unless cur && th

      cur <= th * (1.0 - @dip_pct)
    end

    # Индекс через Indicatives: возвращает UID индекса по тикеру (например IMOEX) или nil.
    # У индексов нет торгуемого figi, поэтому свечи берутся по instrument_id=UID.
    def resolve_index_uid(ticker: 'IMOEX')
      list = @client.grpc_instruments.indicatives
      match = list.find { |i| i.respond_to?(:ticker) && i.ticker.to_s.upcase == ticker.to_s.upcase }
      match&.uid
    rescue StandardError
      nil
    end

    # Дневные закрытия индекса. Предпочитаем instrument_id (UID) — figi для индексов не работает.
    def index_daily_closes(figi: nil, instrument_id: nil)
      return [] unless figi || instrument_id

      resp = Utils.fetch_candles(
        @client,
        figi: instrument_id ? nil : figi,
        instrument_id: instrument_id,
        from: Utils.days_ago(14), to: Utils.now_utc, interval: DAY
      )
      candles = resp&.candles || []
      Utils.completed_daily_candles(candles, now: Utils.now_utc)
           .map { |c| Utils.q_to_decimal(c.close) }
           .compact
    end

    def trend_from_closes(closes)
      return :unknown if closes.size < 4

      # последние 4 закрытия => последние 3 изменения
      a = closes[-4]
      b = closes[-3]
      c = closes[-2]
      d = closes[-1]
      return :up   if a < b && b < c && c < d
      return :down if a > b && b > c && c > d

      :side
    end

    # Тренд индекса: «стабильно больше 2 дней» = 3 последовательных дневных закрытия
    # Возвращает :up, :down, :side или :unknown.
    # :unknown — данных по индексу нет/недостаточно (нельзя путать с настоящим боковиком).
    def trend(index_figi, instrument_id: nil)
      return :unknown unless index_figi || instrument_id

      trend_from_closes(index_daily_closes(figi: index_figi, instrument_id: instrument_id))
    end

    # tickers: — позволяет собрать универсум не из @tickers (в UP используется
    # отдельный расширенный whitelist, см. UP_TICKERS в bin/current_strategy.rb).
    def build_universe(tickers: @tickers)
      volume_enabled = volume_features_enabled?

      tickers.map do |t|
        figi, lot = figi_and_lot(t)
        next unless figi && lot

        # Отсев по числу акций в лоте. Ограничитель избыточен, когда задан max_lot_rub
        # (рублёвый потолок и так режет дорогие лоты), а с max_lot_count=1 он выбрасывал
        # половину ликвидного IMOEX: GAZP, SNGSP, IRAO, RUAL, NLMK, RTKM, ALRS, MAGN.
        # Выключается пустым/нулевым MAX_LOT_COUNT.
        if @max_lot_count&.positive? && lot.to_i > @max_lot_count.to_i
          warn "build_universe: skipping #{t} — lot=#{lot} > max_lot_count=#{@max_lot_count}"
          next
        end
        price = last_price_for(figi)
        next unless price

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
    # trend: — если :up и уровни включены, применяем трендовый гейт (см. up_entry_ok?).
    # Graceful degradation: если уровней нет — покупаем по старым правилам.
    def should_buy?(it, trend: :side)
      buy_gate(it, trend: trend)[:should_buy]
    end

    # Единая точка решения о покупке + разложение на подусловия (для shadow-логов:
    # видно, какой именно гейт отсекает кандидата). Каждое обращение к API — по
    # одному разу: метод зовётся каждые 5 минут по всему универсуму.
    def buy_gate(it, trend: :side)
      stats = daily_volume_stats(it[:figi])
      gate = {
        dip: dip_today?(it[:figi]),
        rvol: stats && stats[:normalized].round(2),
        rvol_raw: stats && stats[:raw].round(2),
        volume_ok: volume_spike?(it[:figi])
      }
      gate[:should_buy] = gate[:dip] && gate[:volume_ok] && up_entry_gate(gate, it, trend)
      gate
    end

    # Гейт входа в растущем тренде. Применяется только при trend=:up и включённых
    # уровнях; свои подусловия пишет в gate для логов.
    #
    # Раньше здесь стоял near_support? — но в UP цена по определению уходит от поддержки
    # (27.07.2026: дистанции 11.8% / 14.8% / 17.2% при proximity 1.5%), поэтому условие
    # читалось как «покупаем только после обвала» и блокировало ~все входы.
    # Трендовая замена: бумага участвует в росте (выше своей SMA) и не упирается
    # в сопротивление. UP_REQUIRE_SUPPORT=1 возвращает прежнее поведение.
    def up_entry_gate(gate, it, trend)
      return true unless @use_levels && trend == :up
      return true if levels_for(it[:figi]).empty?

      if @up_require_support
        gate[:near_support] = near_support?(it[:figi], it[:price])
      else
        gate[:near_resistance] = near_resistance?(it[:figi], it[:price])
        gate[:above_ma] = above_moving_average?(it[:figi], it[:price])
        !gate[:near_resistance] && gate[:above_ma]
      end
    end

    # Цена выше простой скользящей по завершённым дневным закрытиям.
    # Нет данных — не блокируем (graceful degradation, как с пустыми уровнями).
    def above_moving_average?(figi, price, days: @up_entry_ma_days)
      return true unless price

      closes = Utils.last_daily_closes(@client, figi, days: days)
      return true if closes.size < days

      price > (closes.sum / closes.size)
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
      submitted_at = nil
      attempts = 0

      begin
        attempts += 1
        submitted_at ||= Time.now.utc.iso8601
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
          submitted_at: submitted_at,
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
          submitted_at: submitted_at,
          reject_reason: e.message,
          error_code: e.class.to_s,
          technical_error: technical
        }
      end
    end

    private

    def validate_level_settings!(settings)
      assert_positive_integer!(settings[:levels_lookback_days], :levels_lookback_days)
      assert_positive_number!(settings[:level_proximity_pct], :level_proximity_pct)
      assert_positive_number!(settings[:level_sell_min_profit], :level_sell_min_profit)
      assert_positive_integer!(settings[:level_pivot_window], :level_pivot_window)
      assert_non_negative_number!(settings[:level_cluster_pct], :level_cluster_pct)
      assert_non_negative_number!(settings[:levels_cache_ttl_seconds], :levels_cache_ttl_seconds)
    end

    def assert_positive_integer!(value, name)
      raise ArgumentError, "#{name} must be > 0" unless value.to_i.positive?
    end

    def assert_positive_number!(value, name)
      raise ArgumentError, "#{name} must be > 0" unless value.to_f.positive?
    end

    def assert_non_negative_number!(value, name)
      raise ArgumentError, "#{name} must be >= 0" if value.to_f.negative?
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
