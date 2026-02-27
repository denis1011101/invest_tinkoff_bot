# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative 'utils'
require_relative 'market_cache'
require_relative 'strategy_helpers'
require_relative 'telegram_helper'

module TradingLogic
  class WishlistScanner
    include TelegramHelper
    WISHLISTS_DIR = File.expand_path('../tmp/wishlists', __dir__)
    RESULTS_DIR   = File.expand_path('../tmp/wishlist_results', __dir__)
    DAY = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY

    CONDITION_METHODS = {
      '52day_low'      => :scan_52day_low,
      'growth_months'  => :scan_growth_months,
      'below_sma'      => :scan_below_sma,
      'drop_from_high' => :scan_drop_from_high
    }.freeze

    def initialize(client, candle_sleep: 0.25)
      @client = client
      @candle_sleep = candle_sleep
      @market_cache = MarketCache.new(client)
      @candle_cache = {}
    end

    def scan_all
      results = {}
      wishlist_files.each do |path|
        config = JSON.parse(File.read(path))
        name = config['name'] || File.basename(path, '.json')
        results[name] = scan_one(config)
      end
      results
    end

    def scan_one(config)
      condition = config['condition']
      method_name = CONDITION_METHODS[condition]
      raise "Unknown condition: #{condition}" unless method_name

      universe = resolve_universe(config['universe'])
      top_n = (config['top_n'] || 10).to_i
      params = config['params'] || {}

      matches = send(method_name, universe, params)
      matches = matches.first(top_n)

      save_result(config, matches)
      { 'config' => config, 'matches' => matches }
    end

    def notify_telegram(results, bot_token:, chat_id:)
      results.each do |_name, data|
        header = data['config']['telegram_header'] || _name
        text = format_telegram_message(header, data['matches'])
        send_telegram(bot_token: bot_token, chat_id: chat_id, text: text)
        sleep 1
      end
    end

    private

    def wishlist_files
      Dir.glob(File.join(WISHLISTS_DIR, '*.json')).sort
    end

    def resolve_universe(universe_spec)
      case universe_spec
      when 'market_cache'
        @market_cache.load_market_cache.map { |h| { 'ticker' => h['ticker'], 'figi' => h['figi'] } }
      when 'moex_index'
        StrategyHelpers.load_cache_normalized(File.expand_path('../tmp/moex_index_cache.json', __dir__))
      when Array
        universe_spec.filter_map do |ticker|
          resp = Utils.safe_share_by_ticker(@client, ticker)
          next unless resp&.instrument
          { 'ticker' => ticker, 'figi' => resp.instrument.figi }
        end
      else
        @market_cache.load_market_cache.map { |h| { 'ticker' => h['ticker'], 'figi' => h['figi'] } }
      end
    end

    def daily_closes(figi, days:)
      if @candle_cache[figi] && @candle_cache[figi].size >= days
        return @candle_cache[figi]
      end

      calendar_days = [days * 2, days + 30].max
      from = Utils.days_ago(calendar_days)
      to = Utils.now_utc
      resp = Utils.fetch_candles(@client, figi: figi, from: from, to: to, interval: DAY)
      sleep @candle_sleep if @candle_sleep > 0
      closes = if resp&.candles
                 resp.candles.map { |c| Utils.q_to_decimal(c.close) }.compact
               else
                 []
               end
      @candle_cache[figi] = closes if closes.size > (@candle_cache[figi]&.size || 0)
      closes
    end

    # --- Conditions ---

    def scan_52day_low(universe, params)
      days = (params['days'] || 52).to_i
      scored = universe.filter_map do |inst|
        closes = daily_closes(inst['figi'], days: days)
        next if closes.size < days
        recent = closes.last(days)
        min_price = recent.min
        current = recent.last
        next unless min_price && current && min_price > 0
        pct_above_low = (current - min_price) / min_price * 100.0
        next if pct_above_low > 5.0
        inst.merge(
          'score' => pct_above_low,
          'price' => current,
          'detail' => "#{pct_above_low.round(2)}% above #{days}d low (#{min_price.round(2)})"
        )
      end
      scored.sort_by { |m| m['score'] }
    end

    def scan_growth_months(universe, params)
      months = (params['months'] || 3).to_i
      days_needed = months * 22
      scored = universe.filter_map do |inst|
        closes = daily_closes(inst['figi'], days: days_needed + 5)
        next if closes.size < days_needed
        monthly_closes = (0..months).map { |i| closes[-(1 + i * 22)] }.reverse.compact
        next if monthly_closes.size < months + 1
        growing = monthly_closes.each_cons(2).all? { |a, b| b > a }
        next unless growing
        total_growth = (monthly_closes.last - monthly_closes.first) / monthly_closes.first * 100.0
        inst.merge(
          'score' => -total_growth,
          'price' => closes.last,
          'detail' => "+#{total_growth.round(2)}% за #{months} мес."
        )
      end
      scored.sort_by { |m| m['score'] }
    end

    def scan_below_sma(universe, params)
      period = (params['period'] || 200).to_i
      scored = universe.filter_map do |inst|
        closes = daily_closes(inst['figi'], days: period + 5)
        next if closes.size < period
        sma = closes.last(period).sum / period.to_f
        current = closes.last
        next unless current < sma
        gap_pct = (sma - current) / sma * 100.0
        inst.merge(
          'score' => -gap_pct,
          'price' => current,
          'detail' => "#{gap_pct.round(2)}% ниже SMA#{period} (#{sma.round(2)})"
        )
      end
      scored.sort_by { |m| m['score'] }
    end

    def scan_drop_from_high(universe, params)
      days = (params['days'] || 52).to_i
      min_drop = (params['min_drop_pct'] || 20).to_f
      scored = universe.filter_map do |inst|
        closes = daily_closes(inst['figi'], days: days)
        next if closes.size < days
        recent = closes.last(days)
        high = recent.max
        current = recent.last
        next unless high && current && high > 0
        drop_pct = (high - current) / high * 100.0
        next if drop_pct < min_drop
        inst.merge(
          'score' => -drop_pct,
          'price' => current,
          'detail' => "-#{drop_pct.round(2)}% от максимума (#{high.round(2)})"
        )
      end
      scored.sort_by { |m| m['score'] }
    end

    # --- Output ---

    def save_result(config, matches)
      FileUtils.mkdir_p(RESULTS_DIR)
      slug = (config['name'] || 'unknown').downcase.gsub(/\s+/, '_').gsub(/[^a-z0-9_]/, '')
      slug = 'wishlist' if slug.empty?
      path = File.join(RESULTS_DIR, "#{slug}_#{Time.now.utc.strftime('%Y%m%d')}.json")
      File.write(path, JSON.pretty_generate({
        'scanned_at' => Time.now.utc.iso8601,
        'config' => config,
        'matches' => matches
      }))
    end

    def format_telegram_message(header, matches)
      date = escape_md(Time.now.utc.strftime('%Y-%m-%d'))
      lines = ["*#{escape_md(header)}*", date, '']
      if matches.empty?
        lines << '_Совпадений не найдено_'
      else
        matches.each_with_index do |m, i|
          ticker = m['ticker'] || '???'
          price = m['price'] ? escape_md(m['price'].round(2).to_s) : '?'
          detail = escape_md(m['detail'] || '')
          lines << "#{escape_md("#{i + 1}.")} `#{ticker}` \\— #{price} ₽ \\— #{detail}"
        end
      end
      lines.join("\n")
    end
  end
end
