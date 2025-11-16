require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'fileutils'

module TradingLogic
  class MoexISS
    BASE = 'https://iss.moex.com/iss'
    CACHE_PATH = File.expand_path('../tmp/moex_index_cache.json', __dir__)
    FileUtils.mkdir_p(File.dirname(CACHE_PATH))

    # options:
    #  :engine  (default 'stock')
    #  :market  (default 'shares')
    #  :boards  (Array or nil) boards to consider as trading (default ['TQBR','TQTF'])
    #  :timeout (seconds)
    def initialize(options = {})
      @engine  = options.fetch(:engine, 'stock')
      @market  = options.fetch(:market, 'shares')
      @boards  = options.fetch(:boards, ['TQBR', 'TQTF'])
      @timeout = options.fetch(:timeout, 10)
    end

    # Возвращает массив хэшей — каждое значение соответствует колонке ISS, ключи symbolized (downcased).
    # Если traded_only: true — фильтрует по доскам (BOARDID in boards) и по наличию BOARDID.
    def securities(traded_only: true)
      url = "#{BASE}/engines/#{URI.encode_www_form_component(@engine)}/markets/#{URI.encode_www_form_component(@market)}/securities.json"
      body = http_get_json(url)
      return [] unless body && body['securities'] && body['securities']['columns'] && body['securities']['data']

      cols = body['securities']['columns']
      rows = body['securities']['data']

      arr = rows.map do |r|
        h = {}
        cols.each_with_index { |c, i| h[c.downcase.to_sym] = r[i] }
        # convenient aliases
        h[:secid] ||= h[:secname] || h[:seccode]
        h
      end

      if traded_only
        arr.select { |h| tradable?(h) }
      else
        arr
      end
    end

    # Возвращает массив хэшей компонентов индекса (например 'IMOEX').
    # Пробует несколько известных URL-форматов ISS и парсит таблицы analytics/constituents/securities.
    def index_constituents(index_id)
      candidates = [
        # 1) analytics — обычно даёт полный состав (нужна пагинация + limit)
        "statistics/engines/#{URI.encode_www_form_component(@engine)}/markets/index/analytics/#{URI.encode_www_form_component(index_id)}.json",
        # 2) constituents — альтернативные старые эндпоинты состава
        "engines/#{URI.encode_www_form_component(@engine)}/markets/#{URI.encode_www_form_component(@market)}/indexes/#{URI.encode_www_form_component(index_id)}/constituents.json",
        "indexes/#{URI.encode_www_form_component(index_id)}/constituents.json",
        # 3) securities для индекса (иногда возвращает состав)
        "engines/#{URI.encode_www_form_component(@engine)}/markets/#{URI.encode_www_form_component(@market)}/indexes/#{URI.encode_www_form_component(index_id)}/securities.json",
        "indexes/#{URI.encode_www_form_component(index_id)}/securities.json"
        # ВАЖНО: SNDX/securities — это список всех индексов, а не состав конкретного => не используем
      ]

      per_page = 100
      max_pages = 50  # safety cap -> 100*50 = 5000 rows max

      candidates.each do |path|
        url_base = "#{BASE}/#{path}"
        # ask for per_page rows explicitly (ISS default limit is small, ~20)
        body = http_get_json("#{url_base}?limit=#{per_page}")
        next unless body

        warn "MoexISS.index_constituents: probing #{path} -> keys=#{body.keys.inspect}"
        warn "MoexISS.index_constituents: analytics.cursor=#{body['analytics.cursor'].inspect}" if body['analytics.cursor']

        # find top-level table (or nested) that has columns/data
        table_key = nil
        table_cols = nil

        # check top-level keys first
        body.each do |k, v|
          if v.is_a?(Hash) && v['columns'].is_a?(Array) && v['data'].is_a?(Array)
            table_key = k
            table_cols = v['columns']
            break
          end
        end

        # fallback: check nested blocks like analytics/*
        if table_key.nil? && body['analytics'].is_a?(Hash)
          body['analytics'].each do |k, v|
            if v.is_a?(Hash) && v['columns'].is_a?(Array) && v['data'].is_a?(Array)
              table_key = "analytics/#{k}"
              table_cols = v['columns']
              break
            end
          end
        end

        next unless table_key && table_cols

        # Collect rows with pagination
        all_rows = []
        start = 0
        page = 0
        total_expected = nil
        if body['analytics.cursor'].is_a?(Hash)
          # try to detect total rows from cursor (field name may vary)
          cur = body['analytics.cursor']
          total_expected = cur['total'] || cur['all'] || cur['count'] || cur.values.find { |v| v.is_a?(Integer) }
        end
        loop do
          req_url = if start > 0
                      "#{url_base}?start=#{start}&limit=#{per_page}"
                    else
                      "#{url_base}?limit=#{per_page}"
                    end
          body_page = http_get_json(req_url)
          break unless body_page

          # extract table for this page (support top-level key or analytics nested)
          page_rows = []
          if table_key.start_with?('analytics/')
            subk = table_key.split('/', 2).last
            tbl = body_page['analytics'] && body_page['analytics'][subk]
            page_rows = tbl['data'] if tbl.is_a?(Hash) && tbl['data'].is_a?(Array)
          else
            tbl = body_page[table_key]
            page_rows = tbl['data'] if tbl.is_a?(Hash) && tbl['data'].is_a?(Array)
          end

          break if page_rows.nil? || page_rows.empty?

          all_rows.concat(page_rows)
          page += 1
          break if page_rows.size < per_page
          break if total_expected && all_rows.size >= total_expected
          start += per_page
          break if page >= max_pages
        end

        next if all_rows.empty?

        # map rows -> hashes
        res = all_rows.map do |r|
          h = {}
          table_cols.each_with_index { |c, i| h[c.downcase.to_sym] = r[i] }
          h[:secid] ||= h[:seccode] || h[:secname]
          h
        end

        # save cache
        begin
          FileUtils.mkdir_p(File.dirname(CACHE_PATH))
          File.write(CACHE_PATH, JSON.pretty_generate({ 'updated_at' => Time.now.utc.iso8601, 'index' => index_id, 'instruments' => res }))
        rescue => e
          warn "MoexISS: failed to write cache #{CACHE_PATH}: #{e.class}: #{e.message}"
        end

        return res
      end

      warn "MoexISS.index_constituents: no table found for index #{index_id}"
      []
    end

    private

    def tradable?(row)
      board = (row[:boardid] || '').to_s
      return false if board.empty?
      # if boards list provided — require match
      return @boards.any? { |b| board.upcase.start_with?(b.upcase) } if @boards && !@boards.empty?

      true
    end

    def http_get_json(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      req = Net::HTTP::Get.new(uri.request_uri, { 'Accept' => 'application/json' })
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        warn "HTTP GET #{url} failed: status=#{res.code} body=#{res.body[0,500].inspect}"
        return nil
      end
      JSON.parse(res.body)
    rescue => e
      warn "Error during HTTP GET or JSON parse for #{url}: #{e.class}: #{e.message}"
      nil
    end
  end
end
