# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tempfile'
require 'time'
require_relative 'market_cache'
require_relative 'public_market_quotes'
require_relative 'utils'
require_relative 'strategy_helpers'
require_relative 'telegram_helper'

module TradingLogic
  class PriceMonitor
    include TelegramHelper

    CONFIG_PATH = File.expand_path('../tmp/price_monitor.json', __dir__)
    STATE_PATH  = File.expand_path('../tmp/price_monitor_state.json', __dir__)
    YEK_OFFSET  = '+05:00'
    STATIC_REPLACEMENTS = {
      '/currencies/usd-rub' => { source: :cbr, symbol: 'USD', label: 'USD/RUB ЦБ' },
      '/indices/mcx' => { source: :moex_index, symbol: 'IMOEX2', label: 'IMOEX2 (все сессии)' },
      '/commodities/brent-oil' => { source: :moex_future, symbol: 'BR', label: 'Нефть Brent, фьючерс' },
      '/commodities/nickel' => { source: :moex_future, symbol: 'NICKEL', label: 'Никель, фьючерс' },
      '/commodities/gold' => { source: :gold_api, symbol: 'XAU' },
      '/commodities/palladium' => { source: :gold_api, symbol: 'XPD' },
      '/commodities/platinum' => { source: :gold_api, symbol: 'XPT' },
      '/indices/us-spx-500' => { link: 'https://fred.stlouisfed.org/series/SP500' },
      '/indices/us-30' => { link: 'https://fred.stlouisfed.org/series/DJIA' }
    }.freeze
    INVESTING_HOSTS = %w[investing.com ru.investing.com www.investing.com].freeze

    def initialize(client, investing_parser: nil, public_quotes: nil)
      @client = client
      @investing_parser = investing_parser
      @public_quotes = public_quotes
    end

    def fetch_all
      config = load_config
      static_config, dynamic_config = instrument_configs(config)
      return [] if static_config.empty? && dynamic_config.empty?

      static_instruments = resolve_static_instruments(static_config)
      dynamic_instruments = resolve_dynamic_instruments(dynamic_config)
      previous = load_previous_state
      results = sort_results(
        fetch_static_results(static_instruments, previous) +
        fetch_dynamic_results(dynamic_instruments, previous.fetch('prices'))
      )

      save_current_prices(results, previous, static_instruments + dynamic_instruments)
      results
    end

    def format_log_result(result)
      label = result[:label]
      price = result[:price]
      return "#{label}: #{result[:link] || 'data unavailable'}" unless price

      delta = result[:delta]
      change = " (#{'+' if delta.positive?}#{delta.round(2)})" if delta
      "#{label}: #{price.round(2)}#{change}"
    end

    def notify_telegram(results, bot_token:, chat_id:, header: nil)
      config = load_config
      header ||= config['telegram_header'] || 'Котировки'
      text = format_monitor_message(header, results)
      send_telegram(bot_token: bot_token, chat_id: chat_id, text: text, disable_link_preview: results.any? { |r| r[:link] })
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

    def fetch_static_results(instruments, previous)
      parser = @investing_parser || build_investing_parser if instruments.any? { |inst| inst[:replacement].nil? }
      public_quotes = @public_quotes || PublicMarketQuotes.new if instruments.any? { |inst| inst.dig(:replacement, :source) }
      instruments.filter_map { |inst| fetch_static_result(inst, previous, parser, public_quotes) }
    ensure
      parser&.close unless @investing_parser
    end

    def build_investing_parser
      require_relative 'investing_parser'
      InvestingParser.new(browser_path: InvestingBrowser.path)
    end

    def fetch_static_result(inst, previous, parser, public_quotes)
      result = { label: inst[:label], query: inst[:url], group: :static, sort_index: inst[:sort_index] }
      replacement = inst[:replacement]
      return result.merge(link: replacement[:link]) if replacement&.key?(:link)

      key = inst.fetch(:state_key)
      if replacement
        source, symbol = replacement.values_at(:source, :symbol)
        quote = public_quotes.fetch(source, symbol)
      else
        quote = parser.fetch_quote(inst[:url])
      end

      prior_price = previous_static_price(previous, key, quote[:state_symbol])
      result.merge(static_price(quote, prior_price)).merge(state_key: key, state_symbol: quote[:state_symbol])
    rescue StandardError => e
      warn "PriceMonitor: #{source || 'investing'} fetch failed for '#{inst[:url]}': #{e.class}: #{e.message}"
      result.merge(unavailable: true) if replacement
    end

    def previous_static_price(previous, key, contract)
      prices = previous.fetch('prices')
      return prices[key] unless contract

      previous_contract = previous.fetch('future_contracts')[key]
      return prices["moex_future:#{contract}"] unless previous_contract

      prices[key] if previous_contract == contract
    end

    def static_price(quote, prev)
      delta = quote[:delta]
      delta_pct = quote[:delta_pct]
      if delta.nil? && prev
        delta = quote[:price] - prev
        delta_pct = prev.zero? ? nil : (delta / prev * 100.0)
      end
      { **quote.slice(:price, :as_of, :contract), prev_price: prev, delta: delta, delta_pct: delta_pct }
    end

    def fetch_dynamic_results(instruments, previous)
      return [] if instruments.empty?

      cache = cached_figis
      resolved = instruments.filter_map do |inst|
        query = inst[:query]
        figi = cache[query.upcase] || resolve_figi(query)
        unless figi
          warn "PriceMonitor: instrument not found for query '#{query}'"
          next
        end

        inst.merge(figi: figi)
      end
      prices = fetch_prices(resolved.map { |inst| inst[:figi] }.uniq)

      resolved.filter_map do |inst|
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
        replacement = replacement_for(url)
        label = replacement&.fetch(:label, nil) || inst['label'] || url
        if url.empty?
          warn "PriceMonitor: static instrument missing url for '#{label}'"
          next
        end

        {
          label: label,
          url: url,
          sort_index: idx,
          replacement: replacement,
          state_key: state_key_for_static(url, replacement)
        }
      end
    end

    def replacement_for(url)
      uri = URI.parse(url)
      return if uri.host && !INVESTING_HOSTS.include?(uri.host.downcase)

      path = uri.path.to_s.delete_prefix('/').delete_suffix('/')
      STATIC_REPLACEMENTS["/#{path}"]
    rescue URI::InvalidURIError
      nil
    end

    def resolve_dynamic_instruments(instruments_config)
      instruments_config.each_with_index.filter_map do |inst, idx|
        query = inst['query'].to_s.strip
        label = inst['label'] || query
        if query.empty?
          warn "PriceMonitor: dynamic instrument missing query for '#{label}'"
          next
        end

        {
          label: label,
          query: query,
          group: :dynamic,
          sort_index: idx,
          state_key: state_key_for_dynamic(query)
        }
      end
    end

    def cached_figis
      rows = MarketCache.new(@client).load_market_cache(fresh_only: true)
      exact_figis = rows.each_with_object({}) do |row, candidates|
        next unless row.is_a?(Hash) && row['class_code'] == 'TQBR'

        ticker = row['ticker'].to_s.upcase
        figi = row['figi'].to_s
        next if ticker.empty? || figi.empty?

        candidates[ticker] = candidates.fetch(ticker, figi) == figi ? figi : nil
      end
      exact_figis.compact
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

    def load_previous_state
      data = File.exist?(STATE_PATH) ? JSON.parse(File.read(STATE_PATH)) : {}
      data = {} unless data.is_a?(Hash)
      %w[prices future_contracts].to_h { |key| [key, data[key].is_a?(Hash) ? data[key] : {}] }
    rescue JSON::ParserError, Errno::ENOENT
      { 'prices' => {}, 'future_contracts' => {} }
    end

    def save_current_prices(results, previous, instruments)
      active_keys = instruments.filter_map { |inst| inst[:state_key] }
      prices = previous.fetch('prices').slice(*active_keys)
      future_contracts = previous.fetch('future_contracts').slice(*active_keys)
      results.each do |result|
        key = result[:state_key]
        next unless key && result[:price]

        prices[key] = result[:price]
        future_contracts[key] = result[:state_symbol] if result[:state_symbol]
      end
      # Before the first successful quote for each configured future, keep old contract-keyed prices.
      if instruments.any? { |inst| inst.dig(:replacement, :source) == :moex_future && !future_contracts.key?(inst[:state_key]) }
        legacy = previous.fetch('prices').select { |key, _| key.match?(/\Amoex_future:[A-Z]{2,}[FGHJKMNQUVXZ]\d\z/) }
        prices.merge!(legacy)
      end
      state = { 'updated_at' => yek_now.iso8601, 'prices' => prices, 'future_contracts' => future_contracts }
      directory = File.dirname(STATE_PATH)
      FileUtils.mkdir_p(directory)
      Tempfile.create('price-monitor-state-', directory) do |file|
        path = file.path
        file.write(JSON.pretty_generate(state))
        file.close
        File.rename(path, STATE_PATH)
      end
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
          lines << format_result(r)
        end
      end

      lines.join("\n")
    end

    def format_result(result)
      return "[#{escape_md(result[:label])}](#{result[:link]})" if result[:link]

      label = [result[:label], result[:contract]].compact.join(' · ').delete('`')
      return "`#{label}` — данные недоступны" if result[:unavailable]

      price = escape_md(format_price(result[:price]))
      change = format_delta(result[:delta], result[:delta_pct])
      change = '—' if change.empty? && result[:as_of]
      time = format_as_of(result[:as_of])
      ["`#{label}`", price, change, time].reject(&:empty?).join(' ')
    end

    def format_as_of(value)
      case value
      when Time then "· #{escape_md(value.getlocal(YEK_OFFSET).strftime('%d.%m %H:%M'))}"
      when Date then "· на #{escape_md(value.strftime('%d.%m.%Y'))}"
      else ''
      end
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

    def state_key_for_static(url, replacement)
      return "investing:#{url}" unless replacement
      return if replacement[:link]

      "#{replacement[:source]}:#{replacement[:symbol]}"
    end

    def state_key_for_dynamic(query)
      "tinkoff:#{query}"
    end
  end
end
