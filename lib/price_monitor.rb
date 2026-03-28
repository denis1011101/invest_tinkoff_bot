# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative 'investing_parser'
require_relative 'utils'
require_relative 'strategy_helpers'
require_relative 'telegram_helper'

module TradingLogic
  class PriceMonitor
    include TelegramHelper

    CONFIG_PATH = File.expand_path('../tmp/price_monitor.json', __dir__)
    STATE_PATH  = File.expand_path('../tmp/price_monitor_state.json', __dir__)
    YEK_OFFSET  = '+05:00'

    def initialize(client, investing_parser: nil)
      @client = client
      @investing_parser = investing_parser || InvestingParser.new
    end

    def fetch_all
      config = load_config
      static_config, dynamic_config = instrument_configs(config)
      return [] if static_config.empty? && dynamic_config.empty?

      previous = load_previous_prices
      results = sort_results(
        fetch_static_results(static_config, previous) +
        fetch_dynamic_results(dynamic_config, previous)
      )

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

    def instrument_configs(config)
      if config['static_instruments'].is_a?(Array) || config['dynamic_instruments'].is_a?(Array)
        [config['static_instruments'] || [], config['dynamic_instruments'] || []]
      else
        [[], config['instruments'] || []]
      end
    end

    def fetch_static_results(instruments_config, previous)
      resolve_static_instruments(instruments_config).filter_map do |inst|
        quote = @investing_parser.fetch_quote(inst[:url])
        prev = previous[inst[:state_key]]
        delta = quote[:delta]
        delta_pct = quote[:delta_pct]

        if delta.nil? && prev
          delta = quote[:price] - prev
          delta_pct = prev.zero? ? nil : (delta / prev * 100.0)
        end

        {
          label: inst[:label],
          query: inst[:url],
          group: inst[:group],
          sort_index: inst[:sort_index],
          price: quote[:price],
          prev_price: prev,
          delta: delta,
          delta_pct: delta_pct,
          state_key: inst[:state_key]
        }
      rescue StandardError => e
        warn "PriceMonitor: investing fetch failed for '#{inst[:url]}': #{e.class}: #{e.message}"
        nil
      end
    end

    def fetch_dynamic_results(instruments_config, previous)
      instruments = resolve_dynamic_instruments(instruments_config)
      return [] if instruments.empty?

      prices = fetch_prices(instruments.filter_map { |inst| inst[:figi] })

      instruments.filter_map do |inst|
        price = prices[inst[:figi]]
        next unless price

        prev = previous[inst[:state_key]]
        delta = prev ? price - prev : nil
        delta_pct = prev && !prev.zero? ? (delta / prev * 100.0) : nil

        {
          label: inst[:label],
          query: inst[:query],
          group: inst[:group],
          sort_index: inst[:sort_index],
          price: price,
          prev_price: prev,
          delta: delta,
          delta_pct: delta_pct,
          state_key: inst[:state_key]
        }
      end
    end

    def resolve_static_instruments(instruments_config)
      instruments_config.each_with_index.filter_map do |inst, idx|
        url = inst['url'].to_s.strip
        label = inst['label'] || url
        if url.empty?
          warn "PriceMonitor: static instrument missing url for '#{label}'"
          next
        end

        {
          label: label,
          url: url,
          group: :static,
          sort_index: idx,
          state_key: state_key_for_static(url)
        }
      end
    end

    def resolve_dynamic_instruments(instruments_config)
      instruments_config.each_with_index.filter_map do |inst, idx|
        query = inst['query'].to_s.strip
        label = inst['label'] || query
        if query.empty?
          warn "PriceMonitor: dynamic instrument missing query for '#{label}'"
          next
        end

        figi = resolve_figi(query)
        unless figi
          warn "PriceMonitor: instrument not found for query '#{query}'"
          next
        end

        {
          label: label,
          query: query,
          figi: figi,
          group: :dynamic,
          sort_index: idx,
          state_key: state_key_for_dynamic(query)
        }
      end
    end

    def sort_results(results)
      static, dynamic = results.partition { |r| r[:group] == :static }
      dynamic = dynamic.sort_by do |r|
        [
          r[:delta_pct] ? 0 : 1,
          -(r[:delta_pct] || 0.0),
          r[:sort_index]
        ]
      end
      static + dynamic
    end

    def resolve_figi(query)
      resp = @client.grpc_instruments.find_instrument(query: query.to_s)
      instruments = resp.instruments.to_a
      upcased = query.to_s.upcase
      preferred = instruments.find { |i| i.ticker.to_s.upcase == upcased && i.class_code == 'TQBR' } ||
                  instruments.find { |i| i.ticker.to_s.upcase == upcased && i.api_trade_available_flag } ||
                  instruments.find(&:api_trade_available_flag) ||
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
      results.each { |r| prices[r[:state_key]] = r[:price] }
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
        prev_group = nil
        results.each do |r|
          lines << '' if prev_group && prev_group != r[:group]
          prev_group = r[:group]
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

    def state_key_for_static(url)
      "investing:#{url}"
    end

    def state_key_for_dynamic(query)
      "tinkoff:#{query}"
    end
  end
end
