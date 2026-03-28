# frozen_string_literal: true

require 'net/http'
require 'time'
require 'uri'

begin
  require 'nokogiri'
rescue LoadError
  warn 'InvestingParser: nokogiri is not available, using text-only fallback parser'
  nil
end

module TradingLogic
  class InvestingParser
    BASE_URL = 'https://ru.investing.com'
    DEFAULT_SLEEP_RANGE = 1.0..2.0
    MAX_ATTEMPTS = 3

    RETRIABLE_ERRORS = [
      Timeout::Error,
      EOFError,
      Errno::ECONNRESET,
      Errno::ETIMEDOUT,
      SocketError
    ].freeze

    NUMBER_LINE_REGEX = /\A[+-−]?\d[\d.\s\u00A0]*(?:,\d+)?%?\z/
    COMBINED_CHANGE_REGEX = /
      (?<delta>[+\-−]?\d[\d.\s\u00A0]*(?:,\d+)?)
      \s*
      \(
      \s*
      (?<delta_pct>[+\-−]?\d[\d.\s\u00A0]*(?:,\d+)?)
      %
      \s*
      \)
    /x

    class ParseError < StandardError; end
    class HttpError < StandardError; end

    def initialize(sleep_range: DEFAULT_SLEEP_RANGE, http_getter: nil, now_proc: nil,
                   sleep_proc: nil, warn_proc: nil)
      @sleep_range = sleep_range
      @http_getter = http_getter || method(:default_http_get)
      @now_proc = now_proc || -> { Time.now }
      @sleep_proc = sleep_proc || ->(seconds) { sleep(seconds) }
      @warn_proc = warn_proc || ->(message) { warn(message) }
      @last_fetch_at = nil
    end

    def fetch_quote(path)
      normalized_path = normalize_path(path)
      throttle_requests!

      quote = fetch_quote_uncached(normalized_path)
      @last_fetch_at = now
      quote
    end

    private

    def fetch_quote_uncached(path)
      uri = URI.join(BASE_URL, path)
      attempts = 0

      begin
        attempts += 1
        response = @http_getter.call(uri, default_headers)
        code = response.code.to_i
        raise HttpError, "HTTP #{code}" if retriable_status?(code)
        raise HttpError, "HTTP #{code}" unless success_status?(code)

        parse_quote(response.body).merge(path: path, fetched_at: now.iso8601)
      rescue *RETRIABLE_ERRORS, HttpError => e
        raise if !retriable_exception?(e) || attempts >= MAX_ATTEMPTS

        @sleep_proc.call(2**(attempts - 1))
        retry
      end
    end

    def parse_quote(html)
      document = build_document(html)
      lines = extract_lines(document, html)

      selector_quote = parse_from_selectors(document)
      warn_once('selectors not found, falling back to text parsing') unless selector_quote
      line_quote = parse_from_lines(lines)
      quote = selector_quote || line_quote

      raise ParseError, 'price not found in investing page' unless quote && quote[:price]

      quote
    end

    def build_document(html)
      return nil unless defined?(Nokogiri)

      Nokogiri::HTML(html)
    end

    def parse_from_selectors(document)
      return nil unless document

      price_text = first_selector_text(document, [
                                         '[data-test="instrument-price-last"]',
                                         '[data-test="instrument-last-price"]',
                                         '[data-test*="instrument-price-last"]'
                                       ])

      delta_text = first_selector_text(document, [
                                         '[data-test="instrument-price-change"]',
                                         '[data-test="instrument-price-change-value"]',
                                         '[data-test*="instrument-price-change"]'
                                       ])

      delta_pct_text = first_selector_text(document, [
                                             '[data-test="instrument-price-change-percent"]',
                                             '[data-test="instrument-price-change-percentage"]',
                                             '[data-test*="instrument-price-change-percent"]'
                                           ])

      combined_change = first_selector_text(document, ['[data-test="instrument-price-change-percent"]'])

      price = parse_number(price_text)
      delta = parse_number(delta_text)
      delta_pct = parse_percent(delta_pct_text)

      if (delta.nil? || delta_pct.nil?) && combined_change
        parsed_delta, parsed_pct = parse_change_text(combined_change)
        delta ||= parsed_delta
        delta_pct ||= parsed_pct
      end

      return nil unless price

      {
        price: price,
        delta: delta,
        delta_pct: delta_pct
      }
    end

    def parse_from_lines(lines)
      return nil if lines.empty?

      window = quote_window(lines)
      price, trailing_lines = parse_price_from_window(window)
      return nil unless price

      delta, delta_pct = parse_change_from_lines(trailing_lines)

      {
        price: price,
        delta: delta,
        delta_pct: delta_pct
      }
    end

    def extract_lines(document, html)
      return document.xpath('//text()').map { |node| normalize_whitespace(node.text) }.reject(&:empty?) if document

      html.gsub(%r{<script.*?</script>}m, ' ')
          .gsub(%r{<style.*?</style>}m, ' ')
          .gsub(/<[^>]+>/, "\n")
          .lines
          .map { |line| normalize_whitespace(line) }
          .reject(&:empty?)
    end

    def quote_window(lines)
      anchor_index = lines.find_index { |line| line.include?('Добавить в список наблюдения') } ||
                     lines.find_index { |line| line.start_with?('Цена в ') }

      unless anchor_index
        warn_once('anchor text not found, scanning from top of document')
        anchor_index = 0
      end

      lines[anchor_index, 16] || lines.first(16)
    end

    def parse_price_from_window(window)
      price_idx = window.find_index { |line| number_line?(line, allow_percent: false) }
      return [nil, []] unless price_idx

      price = parse_number(window[price_idx])
      trailing_lines = window[(price_idx + 1)..] || []
      [price, trailing_lines]
    end

    def parse_change_from_lines(lines)
      delta = nil
      delta_pct = nil

      lines.each do |line|
        next if line.empty?

        delta, delta_pct = apply_change_line(line, delta, delta_pct)
        break if delta && delta_pct
      end

      [delta, delta_pct]
    end

    def apply_change_line(line, delta, delta_pct)
      parsed_delta, parsed_pct = parse_change_text(line)
      delta ||= parsed_delta
      delta_pct ||= parsed_pct
      return [delta, delta_pct] if parsed_delta || parsed_pct

      return [delta, delta_pct] unless number_line?(line)

      delta ||= parse_number(line)
      delta_pct ||= parse_percent(line) if line.include?('%')
      [delta, delta_pct]
    end

    def first_selector_text(document, selectors)
      selectors.each do |selector|
        node = document.at_css(selector)
        text = normalize_whitespace(node&.text)
        return text unless text.empty?
      end
      nil
    rescue Nokogiri::CSS::SyntaxError
      nil
    end

    def parse_change_text(text)
      return [nil, nil] if text.to_s.strip.empty?

      match = text.match(COMBINED_CHANGE_REGEX)
      return [nil, nil] unless match

      [parse_number(match[:delta]), parse_number(match[:delta_pct])]
    end

    def parse_percent(text)
      parse_number(text.to_s.delete('%'))
    end

    def parse_number(text)
      return nil if text.to_s.strip.empty?

      normalized = text.to_s
                       .tr('−', '-')
                       .delete('%')
                       .gsub(/\s|\u00A0/, '')

      if normalized.include?(',') && normalized.include?('.')
        normalized = normalized.gsub('.', '').tr(',', '.')
      elsif normalized.include?(',')
        normalized = normalized.tr(',', '.')
      end

      return nil unless normalized.match?(/\A[+-]?\d+(?:\.\d+)?\z/)

      normalized.to_f
    end

    def number_line?(text, allow_percent: true)
      return false unless text.match?(NUMBER_LINE_REGEX)
      return true if allow_percent

      !text.include?('%')
    end

    def normalize_whitespace(text)
      text.to_s.gsub(/\s+/, ' ').strip
    end

    def normalize_path(path)
      raise ArgumentError, 'investing path is empty' if path.to_s.strip.empty?

      uri = URI.parse(path.to_s)
      return uri.request_uri if uri.host

      raw = path.to_s.strip
      raw.start_with?('/') ? raw : "/#{raw}"
    rescue URI::InvalidURIError => e
      raise ArgumentError, "invalid investing path: #{e.message}"
    end

    def default_headers
      {
        'User-Agent' => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
                        '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept-Language' => 'ru,en;q=0.9'
      }
    end

    def default_http_get(uri, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: 10,
                                          read_timeout: 10) do |http|
        request = Net::HTTP::Get.new(uri)
        headers.each { |key, value| request[key] = value }
        http.request(request)
      end
    end

    def retriable_status?(code)
      [429, 503].include?(code)
    end

    def success_status?(code)
      code >= 200 && code < 300
    end

    def retriable_exception?(error)
      return true if RETRIABLE_ERRORS.any? { |klass| error.is_a?(klass) }

      error.is_a?(HttpError) && retriable_status?(error.message[/\d+/].to_i)
    end

    def throttle_requests!
      return unless @last_fetch_at

      min_delay = @sleep_range.begin.to_f
      elapsed = now - @last_fetch_at
      return if elapsed >= min_delay

      delay = rand(@sleep_range) - elapsed
      @sleep_proc.call(delay) if delay.positive?
    end

    def warn_once(message)
      @warned_messages ||= {}
      return if @warned_messages[message]

      @warn_proc.call("InvestingParser: #{message}")
      @warned_messages[message] = true
    end

    def now
      @now_proc.call
    end
  end
end
