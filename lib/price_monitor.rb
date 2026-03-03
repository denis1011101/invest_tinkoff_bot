# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative 'utils'
require_relative 'strategy_helpers'
require_relative 'telegram_helper'

module TradingLogic
  class PriceMonitor
    include TelegramHelper

    CONFIG_PATH = File.expand_path('../tmp/price_monitor.json', __dir__)
    STATE_PATH  = File.expand_path('../tmp/price_monitor_state.json', __dir__)
    YEK_OFFSET  = '+05:00'

    def initialize(client)
      @client = client
    end

    def fetch_all
      config = load_config
      return [] if config['instruments'].nil? || config['instruments'].empty?

      instruments = resolve_instruments(config['instruments'])
      return [] if instruments.empty?

      figis = instruments.filter_map { |i| i[:figi] }
      prices = fetch_prices(figis)
      previous = load_previous_prices

      results = instruments.filter_map do |inst|
        price = prices[inst[:figi]]
        next unless price

        price *= inst[:scale] if inst[:scale] != 1.0

        prev = previous[inst[:query]]
        delta = prev ? price - prev : nil
        delta_pct = prev && prev != 0 ? (delta / prev * 100.0) : nil

        {
          label: inst[:label],
          query: inst[:query],
          price: price,
          prev_price: prev,
          delta: delta,
          delta_pct: delta_pct
        }
      end

      save_current_prices(results)
      results
    end

    def notify_telegram(results, bot_token:, chat_id:, header: nil)
      config = load_config
      header ||= config['telegram_header'] || 'Котировки'
      text = format_monitor_message(header, results)
      send_telegram(bot_token: bot_token, chat_id: chat_id, text: text)
    end

    private

    def load_config
      return {} unless File.exist?(CONFIG_PATH)

      JSON.parse(File.read(CONFIG_PATH))
    rescue JSON::ParserError
      {}
    end

    def resolve_instruments(instruments_config)
      instruments_config.filter_map do |inst|
        query = inst['query']
        label = inst['label'] || query
        scale = inst['scale']&.to_f || 1.0
        figi = resolve_figi(query)
        unless figi
          warn "PriceMonitor: instrument not found for query '#{query}'"
          next
        end
        { label: label, query: query, figi: figi, scale: scale }
      end
    end

    def resolve_figi(query)
      resp = @client.grpc_instruments.find_instrument(query: query.to_s)
      instruments = resp.instruments.to_a
      upcased = query.to_s.upcase
      preferred = instruments.find { |i| i.ticker.to_s.upcase == upcased && i.class_code == 'TQBR' } ||
                  instruments.find { |i| i.ticker.to_s.upcase == upcased && i.api_trade_available_flag } ||
                  instruments.find { |i| i.api_trade_available_flag } ||
                  instruments.first
      preferred&.figi
    rescue StandardError
      nil
    end

    def fetch_prices(figis)
      return {} if figis.empty?

      resp = @client.grpc_market_data.last_prices(figis: figis)
      prices = {}
      resp.last_prices.each do |lp|
        next unless lp&.figi && lp.price

        prices[lp.figi] = Utils.q_to_decimal(lp.price)
      end
      prices
    rescue StandardError => e
      warn "PriceMonitor: last_prices error: #{e.class}: #{e.message}"
      {}
    end

    def load_previous_prices
      return {} unless File.exist?(STATE_PATH)

      data = JSON.parse(File.read(STATE_PATH))
      data['prices'] || {}
    rescue JSON::ParserError
      {}
    end

    def save_current_prices(results)
      prices = {}
      results.each { |r| prices[r[:query]] = r[:price] }
      FileUtils.mkdir_p(File.dirname(STATE_PATH))
      File.write(STATE_PATH, JSON.pretty_generate({
                                                    'updated_at' => yek_now.iso8601,
                                                    'prices' => prices
                                                  }))
    end

    def yek_now
      Time.now.getlocal(YEK_OFFSET)
    end

    def format_monitor_message(header, results)
      now = yek_now
      date_str = escape_md(now.strftime('%Y-%m-%d %H:%M'))
      lines = ["*#{escape_md(header)}*", "#{date_str} \\(Екб\\)", '']

      if results.empty?
        lines << '_Нет данных_'
      else
        results.each do |r|
          label = r[:label].to_s.delete('`')
          price = escape_md(format_price(r[:price]))
          delta_str = format_delta(r[:delta], r[:delta_pct])
          lines << "`#{label}` #{price} #{delta_str}"
        end
      end

      lines.join("\n")
    end

    def format_price(price)
      return '?' unless price

      price >= 100 ? price.round(1).to_s : price.round(2).to_s
    end

    def format_delta(delta, delta_pct)
      return '' unless delta && delta_pct

      arrow = if delta > 0.001
                '↗'
              elsif delta < -0.001
                '↘'
              else
                '—'
              end

      sign = delta.positive? ? '+' : ''
      d = escape_md("#{sign}#{format_price(delta)}")
      p = escape_md("#{sign}#{delta_pct.round(2)}%")
      "#{arrow} #{d} \\(#{p}\\)"
    end
  end
end
