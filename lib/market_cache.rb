# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module TradingLogic
  class MarketCache
    CACHE_PATH = File.expand_path('../tmp/market_instruments_cache.json', __dir__)
    FileUtils.mkdir_p(File.dirname(CACHE_PATH))

    def self.cache_ttl_hours(env = ENV)
      (env['INSTRUMENT_CACHE_HOURS'] || '24').to_f
    end

    # Свежесть считаем по updated_at ВНУТРИ кеша (а не по mtime файла) и в часах,
    # чтобы TTL обновления был согласован с порогом «протухания» в стратегии
    # (INTERSECTION_CACHE_MAX_AGE_HOURS). Обновление должно быть чаще протухания.
    CACHE_TTL_HOURS = cache_ttl_hours
    CACHE_MAX_PRICE_PER_LOT = (ENV['SCAN_MAX_LOT_RUB'] || '500').to_f
    # Только рублёвые акции основного режима МосБиржи допускаем в кеш —
    # иначе тикер вроде "T" может сматчиться на иностранный инструмент (AT&T, BBG000BSJK37).
    ALLOWED_CLASS_CODES = (ENV['CACHE_CLASS_CODES'] || 'TQBR').split(',').map { |c| c.strip.upcase }.freeze
    ALLOWED_CURRENCY = (ENV['CACHE_CURRENCY'] || 'rub').downcase

    def initialize(client)
      @client = client
    end

    # Обновляет кеш (force: true — форсированно). Возвращает true/false.
    def refresh_market_cache(force: false, batch_size: 200) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength
      return true if !force && cache_fresh_by_updated_at?

      list = fetch_instruments
      # Пустой/nil ответ — это НЕ успех: старый кеш сохраняем, но сообщаем об ошибке.
      if list.nil? || list.empty?
        warn 'MarketCache.refresh: instruments list empty — keeping previous cache, treating as failure'
        return false
      end

      # Собираем данные по инструментам (только торгуемые рублёвые акции TQBR)
      items = list.filter_map do |ins|
        figi = share_field(ins, :figi)
        next unless figi
        next unless allowed_instrument?(ins)

        {
          ticker: share_field(ins, :ticker),
          figi: figi,
          uid: share_field(ins, :uid),
          class_code: share_field(ins, :class_code),
          currency: share_field(ins, :currency).to_s.downcase,
          lot: (share_field(ins, :lot) || 1).to_i,
          api_trade: share_flag(ins, :api_trade_available_flag),
          buy: share_flag(ins, :buy_available_flag),
          sell: share_flag(ins, :sell_available_flag),
          trading_status: share_field(ins, :trading_status).to_s
        }
      end

      figis = items.map { |i| i[:figi] }.uniq
      prices = {}

      # Запрашиваем last_prices пачками
      figis.each_slice(batch_size) do |slice|
        begin
          resp = @client.grpc_market_data.last_prices(figis: slice)
          if resp.respond_to?(:last_prices)
            resp.last_prices.each do |lp|
              next unless lp&.figi && lp.price

              q = lp.price
              price = q.units.to_i + (q.nano.to_i / 1_000_000_000.0)
              prices[lp.figi] = price
            end
          end
        rescue StandardError => e
          warn "MarketCache.batch last_prices error: #{e.class}: #{e.message}"
        end
        sleep((ENV['MARKET_CACHE_SLEEP'] || 0).to_f) if ENV['MARKET_CACHE_SLEEP']
      end
      out = items.map do |i|
        price = prices[i[:figi]]
        next unless price

        price_per_lot = price * i[:lot]
        next if price_per_lot > CACHE_MAX_PRICE_PER_LOT

        {
          'ticker' => i[:ticker], 'figi' => i[:figi], 'uid' => i[:uid],
          'class_code' => i[:class_code], 'currency' => i[:currency], 'lot' => i[:lot],
          'price' => price, 'price_per_lot' => price_per_lot,
          'api_trade_available_flag' => i[:api_trade], 'buy_available_flag' => i[:buy],
          'sell_available_flag' => i[:sell], 'trading_status' => i[:trading_status]
        }
      end.compact

      # После фильтрации по ценам/лимиту получить пусто — тоже провал: не перезаписываем
      # старый кеш пустышкой (иначе стратегия увидит пустое пересечение и «успех» в rake).
      if out.empty?
        warn 'MarketCache.refresh: no instruments passed price/lot filter — keeping previous cache, treating as failure'
        return false
      end

      FileUtils.mkdir_p(File.dirname(CACHE_PATH))
      File.write(CACHE_PATH, JSON.pretty_generate({ 'updated_at' => Time.now.utc.iso8601, 'instruments' => out }))
      true
    rescue StandardError => e
      warn "MarketCache.refresh error: #{e.class}: #{e.message}"
      false
    end

    # Возвращает массив инструментов из кеша
    def load_market_cache
      return [] unless File.exist?(CACHE_PATH)

      data = begin
        JSON.parse(File.read(CACHE_PATH))
      rescue StandardError
        nil
      end
      return [] unless data && data['instruments'].is_a?(Array)

      data['instruments']
    end

    private

    # Свежесть по updated_at внутри файла кеша (в часах), не по mtime.
    def cache_fresh_by_updated_at?
      return false unless File.exist?(CACHE_PATH)

      data = JSON.parse(File.read(CACHE_PATH))
      ts = data['updated_at']
      return false unless ts

      age_hours = (Time.now.utc - Time.parse(ts.to_s).utc) / 3600.0
      age_hours < CACHE_TTL_HOURS
    rescue StandardError
      false
    end

    def share_field(ins, name)
      ins.public_send(name) if ins.respond_to?(name)
    rescue StandardError
      nil
    end

    def share_flag(ins, name)
      share_field(ins, name) == true
    end

    # Пускаем в кеш только рублёвые акции разрешённых режимов (по умолчанию TQBR),
    # доступные для торгов через API и для покупки. Это отсекает иностранные
    # инструменты с совпадающим тикером (например "T" -> AT&T).
    def allowed_instrument?(ins)
      class_code = share_field(ins, :class_code).to_s.upcase
      currency = share_field(ins, :currency).to_s.downcase
      return false unless ALLOWED_CLASS_CODES.include?(class_code)
      return false unless currency == ALLOWED_CURRENCY
      return false unless share_flag(ins, :api_trade_available_flag)

      true
    end

    # Получаем список акций через gRPC метод shares.
    # Метод может вернуть объект с .instruments или stream/enumerable — обработаем оба варианта.
    def fetch_instruments
      svc = @client.grpc_instruments
      unless svc.respond_to?(:shares)
        warn 'MarketCache.fetch_instruments: grpc_instruments has no .shares method'
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
      rescue StandardError => e
        warn "MarketCache.fetch_instruments shares -> #{e.class}: #{e.message}"
        []
      end
    end

    def last_price_for(figi)
      lp = @client.grpc_market_data.last_prices(figis: [figi])
      return nil if lp.last_prices.empty?

      q = lp.last_prices.first.price
      q.units.to_i + (q.nano.to_i / 1_000_000_000.0)
    rescue StandardError => _e
      nil
    end
  end
end
