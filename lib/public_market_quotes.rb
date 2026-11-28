# frozen_string_literal: true

require 'csv'
require 'date'
require 'json'
require 'net/http'
require 'nokogiri'
require 'time'
require 'uri'
require_relative 'moex_iss'

module TradingLogic
  class PublicMarketQuotes
    CBR_URL = 'https://www.cbr.ru/scripts/XML_daily.asp'
    FRED_URL = 'https://fred.stlouisfed.org/graph/fredgraph.csv'
    FRED_INDICES = %w[SP500 DJIA].freeze
    GOLD_API_URL = 'https://api.gold-api.com/price'
    MOEX_CA_FILE = '/etc/ssl/invest_bot/roots_with_ru.pem'
    MSK_OFFSET = '+03:00'

    class Unavailable < StandardError; end

    def initialize(index_iss: nil, futures_iss: nil, now: Time.now)
      @index_iss = index_iss || moex_client('stock', 'index')
      @futures_iss = futures_iss || moex_client('futures', 'forts')
      @today_msk = now.getlocal(MSK_OFFSET).to_date
    end

    def fetch(source, symbol)
      quote = case source
              when :cbr then cbr_quote(symbol)
              when :moex_index then index_quote(symbol)
              when :moex_future then futures_quote(symbol)
              when :gold_api then metal_quote(symbol)
              when :fred then fred_quote(symbol)
              end
      raise Unavailable, "no price for #{symbol}" unless quote && positive_number?(quote[:price])

      quote
    end

    private

    def moex_client(engine, market)
      ca_file = BrokerTls.bundle_path(ENV, keys: MoexISS::CA_ENV_KEYS)
      ca_file ||= MOEX_CA_FILE if File.readable?(MOEX_CA_FILE)
      MoexISS.new(engine: engine, market: market, ca_file: ca_file, timeout: 12)
    end

    def cbr_quote(symbol)
      current = cbr_rate(CBR_URL, symbol)
      return unless current

      reference = previous_cbr_price(symbol, current[:as_of])
      current.merge(change_from_reference(current[:price], reference))
    end

    def previous_cbr_price(symbol, effective_date)
      date = (effective_date - 1).strftime('%d/%m/%Y')
      query = URI.encode_www_form(date_req: date)
      previous = cbr_rate("#{CBR_URL}?#{query}", symbol)
      previous[:price] if previous && previous[:as_of] < effective_date
    rescue StandardError => e
      warn "PriceMonitor: previous CBR rate unavailable for #{symbol}: #{e.class}: #{e.message}"
      nil
    end

    def cbr_rate(url, symbol)
      root = Nokogiri::XML(get(url)).root
      return unless root&.name == 'ValCurs'

      row = root.xpath('Valute').find { |currency| currency.at_xpath('CharCode')&.text == symbol }
      return unless row

      nominal = Integer(row.at_xpath('Nominal')&.text.to_s, 10)
      return unless nominal.positive?

      price = Float(row.at_xpath('Value')&.text.to_s.tr(',', '.')) / nominal
      { price: price, as_of: Date.strptime(root['Date'], '%d.%m.%Y') }
    end

    def metal_quote(symbol)
      data = JSON.parse(get("#{GOLD_API_URL}/#{URI.encode_www_form_component(symbol)}"))
      return unless data['symbol'] == symbol

      { price: data['price'], as_of: Time.iso8601(data.fetch('updatedAt')) }
    end

    def fred_quote(symbol)
      closes = fred_daily_closes.fetch(symbol, [])
      current, previous = closes.last(2).reverse
      return unless current

      date, price = current
      { price: price, as_of: date, **change_from_reference(price, previous&.last) }
    end

    def fred_daily_closes
      @fred_daily_closes ||= load_fred_daily_closes
    end

    def load_fred_daily_closes
      query = URI.encode_www_form(id: FRED_INDICES.join(','), cosd: (@today_msk - 14).iso8601)
      csv = CSV.parse(get("#{FRED_URL}?#{query}"), headers: true)
      date_column = csv.headers.find { |header| %w[date observation_date].include?(header.to_s.downcase) }
      raise Unavailable, 'FRED CSV has no observation date column' unless date_column

      dated_rows = csv.filter_map do |row|
        date = Date.iso8601(row[date_column].to_s)
        [date, row] if date <= @today_msk
      rescue Date::Error
        nil
      end
      dated_rows.sort_by!(&:first)
      FRED_INDICES.to_h do |symbol|
        closes = dated_rows.filter_map do |date, row|
          price = Float(row[symbol].to_s, exception: false)
          [date, price] if positive_number?(price)
        end
        [symbol, closes]
      end
    rescue StandardError => e
      warn "PriceMonitor: FRED closes unavailable: #{e.class}: #{e.message}"
      {}
    end

    def index_quote(symbol)
      tables = @index_iss.board_data(
        board: 'SNDX', secid: symbol, columns: { marketdata: %w[CURRENTVALUE LASTCHANGE LASTCHANGEPRC TRADEDATE TIME] }
      )
      row = tables[:marketdata]&.first
      return unless row

      { price: row[:currentvalue], delta: row[:lastchange], delta_pct: row[:lastchangeprc], as_of: moex_time(row) }
    end

    def futures_quote(asset)
      contract = front_contract(asset)
      return unless contract

      tables = @futures_iss.board_data(board: 'RFUD', secid: contract[:secid], columns: {
                                         securities: %w[PREVPRICE],
                                         marketdata: %w[LAST TRADEDATE TIME]
                                       })
      row = tables[:marketdata]&.first
      return unless row && positive_number?(row[:last])

      previous_close = tables[:securities]&.first&.fetch(:prevprice, nil)
      {
        price: row[:last], as_of: moex_time(row), contract: contract[:shortname], state_symbol: contract[:secid],
        **change_from_reference(row[:last], previous_close)
      }
    end

    def front_contract(asset)
      # Roll at the start of the final trading date in Moscow, before the contract can expire.
      name = /\A#{Regexp.escape(asset)}-\d{1,2}\.\d{2}\z/
      today = @today_msk.iso8601
      contracts = futures_schedule.select do |row|
        row[:assetcode] == asset && name.match?(row[:shortname]) && row[:lasttradedate].to_s > today
      end
      contracts.min_by { |row| [row[:lasttradedate], row[:secid]] }
    end

    def futures_schedule
      @futures_schedule ||= @futures_iss.board_data(
        board: 'RFUD', columns: { securities: %w[SECID SHORTNAME ASSETCODE LASTTRADEDATE] }
      ).fetch(:securities, [])
    end

    def change_from_reference(price, reference)
      return {} unless positive_number?(reference)

      delta = price - reference
      { delta: delta, delta_pct: delta.fdiv(reference) * 100 }
    end

    def moex_time(row)
      date = Date.iso8601(row.fetch(:tradedate))
      return date if row[:time].to_s.empty?

      Time.iso8601("#{date}T#{row[:time]}#{MSK_OFFSET}")
    end

    def positive_number?(number)
      number.is_a?(Numeric) && number.finite? && number.positive?
    end

    def get(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 8) do |http|
        http.get(uri.request_uri)
      end
      raise Unavailable, "#{uri.host} HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
  end
end
