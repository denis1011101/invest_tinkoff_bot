require 'json'
require 'fileutils'
require 'time'

module TradingLogic
  class MarketCache
    CACHE_PATH = File.expand_path('../tmp/market_instruments_cache.json', __dir__)
    FileUtils.mkdir_p(File.dirname(CACHE_PATH))
    CACHE_TTL_DAYS = (ENV['INSTRUMENT_CACHE_DAYS'] || '7').to_i
    CACHE_MAX_PRICE_PER_LOT = (ENV['SCAN_MAX_LOT_RUB'] || '300').to_f

    def initialize(client)
      @client = client
    end

    # Обновляет кеш (force: true — форсированно). Возвращает true/false.
    def refresh_market_cache(force: false, batch_size: 200)
      if File.exist?(CACHE_PATH) && !force
        age = (Time.now - File.mtime(CACHE_PATH)) / 86_400.0
        return true if age < CACHE_TTL_DAYS
      end

      list = fetch_instruments
      return true if list.nil? || list.empty?

      # Собираем данные по инструментам
      items = list.map do |ins|
        figi = ins.figi rescue nil
        next unless figi
        { ticker: (ins.ticker rescue nil), figi: figi, lot: (ins.lot.to_i rescue 1) }
      end.compact

      figis = items.map { |i| i[:figi] }.uniq
      prices = {}

      # Запрашиваем last_prices пачками
      figis.each_slice(batch_size) do |slice|
        begin
          resp = @client.grpc_market_data.last_prices(figis: slice)
          if resp && resp.respond_to?(:last_prices)
            resp.last_prices.each do |lp|
              next unless lp && lp.figi && lp.price
              q = lp.price
              price = q.units.to_i + q.nano.to_i / 1_000_000_000.0
              prices[lp.figi] = price
            end
          end
        rescue => e
          warn "MarketCache.batch last_prices error: #{e.class}: #{e.message}"
        end
        sleep((ENV['MARKET_CACHE_SLEEP'] || 0).to_f) if (ENV['MARKET_CACHE_SLEEP'])
      end
      out = items.map do |i|
        price = prices[i[:figi]]
        next unless price
        price_per_lot = price * i[:lot]
        next if price_per_lot > CACHE_MAX_PRICE_PER_LOT
        { 'ticker' => i[:ticker], 'figi' => i[:figi], 'lot' => i[:lot], 'price' => price, 'price_per_lot' => price_per_lot }
      end.compact

      FileUtils.mkdir_p(File.dirname(CACHE_PATH))
      File.write(CACHE_PATH, JSON.pretty_generate({ 'updated_at' => Time.now.utc.iso8601, 'instruments' => out }))
      true
    rescue => e
      warn "MarketCache.refresh error: #{e.class}: #{e.message}"
      false
    end

    # Возвращает массив инструментов из кеша
    def load_market_cache
      return [] unless File.exist?(CACHE_PATH)
      data = JSON.parse(File.read(CACHE_PATH)) rescue nil
      return [] unless data && data['instruments'].is_a?(Array)
      data['instruments']
    end

    private

    # Получаем список акций через gRPC метод shares.
    # Метод может вернуть объект с .instruments или stream/enumerable — обработаем оба варианта.
    def fetch_instruments
      svc = @client.grpc_instruments
      unless svc.respond_to?(:shares)
        warn "MarketCache.fetch_instruments: grpc_instruments has no .shares method"
        return []
      end

      begin
        resp = svc.shares
        return [] unless resp
        if resp.respond_to?(:instruments) && resp.instruments
          warn "MarketCache.fetch_instruments: got #{resp.instruments.size} from shares RPC"
          return resp.instruments
        end
        if resp.respond_to?(:to_a)
          arr = resp.to_a
          warn "MarketCache.fetch_instruments: got #{arr.size} (stream) from shares RPC"
          return arr
        end
        warn "MarketCache.fetch_instruments: unexpected shares response type #{resp.class}"
        []
      rescue => e
        warn "MarketCache.fetch_instruments shares -> #{e.class}: #{e.message}"
        []
      end
    end

    def last_price_for(figi)
      lp = @client.grpc_market_data.last_prices(figis: [figi])
      return nil if lp.last_prices.empty?
      q = lp.last_prices.first.price
      q.units.to_i + q.nano.to_i / 1_000_000_000.0
    rescue => _
      nil
    end
  end
end
