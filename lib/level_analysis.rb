# frozen_string_literal: true

module TradingLogic
  module LevelAnalysis
    def levels_for(figi)
      cache_key = level_cache_key(figi)
      cached_entry = @levels_cache[cache_key]
      return cached_entry[:levels] if level_cache_entry_fresh?(cached_entry)

      levels = compute_support_resistance(figi)
      @levels_cache[cache_key] = { levels: levels, cached_at: Time.now.utc }
      levels
    end

    def compute_support_resistance(figi)
      candles = level_candles_for(figi)
      pivot_window = @level_pivot_window
      return [] if candles.size < ((pivot_window * 2) + 1)

      lows = candles.map { |c| Utils.q_to_decimal(c.low) }
      highs = candles.map { |c| Utils.q_to_decimal(c.high) }
      support_prices, resistance_prices = extract_level_prices(lows, highs, pivot_window)

      build_levels(support_prices, :support) + build_levels(resistance_prices, :resistance)
    rescue StandardError
      []
    end

    def nearest_support(figi, price)
      return nil unless @use_levels

      levels_for(figi).select { |l| l[:type] == :support && l[:price] <= price }.max_by { |l| l[:price] }
    end

    def nearest_resistance(figi, price)
      return nil unless @use_levels

      levels_for(figi).select { |l| l[:type] == :resistance && l[:price] >= price }.min_by { |l| l[:price] }
    end

    def near_support?(figi, price)
      level_near_price?(nearest_support(figi, price), price)
    end

    def near_resistance?(figi, price)
      level_near_price?(nearest_resistance(figi, price), price, reverse: true)
    end

    def level_debug_info(figi, price)
      return 'levels disabled' unless @use_levels

      levels = levels_for(figi)
      return 'no levels computed' if levels.empty?

      support = nearest_support(figi, price)
      resistance = nearest_resistance(figi, price)
      "#{format_level_debug(:support, support, price)} | " \
        "#{format_level_debug(:resistance, resistance, price)} (total levels: #{levels.size})"
    end

    private

    def level_candles_for(figi)
      calendar_days = [@levels_lookback_days * 2, @levels_lookback_days + 30].max
      response = Utils.fetch_candles(
        @client,
        figi: figi,
        from: Utils.days_ago(calendar_days),
        to: Utils.now_utc,
        interval: self.class::DAY
      )

      filter_closed_level_candles(response&.candles.to_a).last(@levels_lookback_days)
    end

    def filter_closed_level_candles(candles)
      today_start = Utils.today_utc_start
      candles.reject { |c| candle_time_utc(c) >= today_start }
    end

    def extract_level_prices(lows, highs, pivot_window)
      support_prices = []
      resistance_prices = []

      (pivot_window...(lows.size - pivot_window)).each do |index|
        support_prices << lows[index] if pivot_level?(lows, index, pivot_window, :>)
        resistance_prices << highs[index] if pivot_level?(highs, index, pivot_window, :<)
      end

      [support_prices, resistance_prices]
    end

    def pivot_level?(values, index, window, operator)
      value = values[index]
      return false unless value

      left = values[(index - window)...index]
      right = values[(index + 1)..(index + window)]
      left.all? { |v| v.public_send(operator, value) } &&
        right.all? { |v| v.public_send(operator, value) }
    end

    def build_levels(prices, type)
      cluster_levels(prices, @level_cluster_pct)
        .map { |price, strength| { price: price, type: type, strength: strength } }
        .sort_by { |level| level[:price] }
    end

    def level_near_price?(level, price, reverse: false)
      distance = compute_distance(level, price, reverse: reverse)
      !!(distance && distance <= @level_proximity_pct)
    end

    def format_level_debug(type, level, price)
      return "no #{type}" unless level

      distance = compute_distance(level, price, reverse: type == :resistance)
      return "no #{type}" unless distance

      "#{type}=#{level[:price].round(2)} dist=#{(distance * 100).round(2)}% str=#{level[:strength]}"
    end

    def cluster_levels(prices, cluster_pct)
      clusters = prices.compact.sort.each_with_object([]) do |price, current_clusters|
        cluster = current_clusters.find { |current| within_cluster?(price, current, cluster_pct) }
        if cluster
          cluster << price
        else
          current_clusters << [price]
        end
      end

      clusters.map { |cluster| [cluster.sum / cluster.size, cluster.size] }
    end

    def within_cluster?(price, cluster, cluster_pct)
      center = cluster.sum / cluster.size
      ((price - center).abs / center) <= cluster_pct
    end

    def compute_distance(level, price, reverse: false)
      return nil unless level.is_a?(Hash)
      return nil unless level[:price].is_a?(Numeric) && price.is_a?(Numeric)

      level_price = level[:price]
      current_price = price
      return nil if level_price.zero?
      return nil if level_price.respond_to?(:finite?) && !level_price.finite?
      return nil if current_price.respond_to?(:finite?) && !current_price.finite?

      if reverse
        (level_price - current_price) / level_price
      else
        (current_price - level_price) / level_price
      end
    end

    def candle_time_utc(candle)
      Time.at(candle.time.seconds).utc
    end

    def level_cache_key(figi)
      [
        figi,
        @levels_lookback_days,
        @level_pivot_window,
        @level_cluster_pct,
        @level_proximity_pct
      ]
    end

    def level_cache_entry_fresh?(entry)
      return false unless entry.is_a?(Hash) && entry[:cached_at].is_a?(Time)
      return false unless entry.key?(:levels)

      ttl = @levels_cache_ttl_seconds.to_i
      return false if ttl <= 0

      (Time.now.utc - entry[:cached_at]) < ttl
    end
  end
end
