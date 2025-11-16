module TradingLogic
  module Utils
    module_function

    def q_to_decimal(q)
      return nil unless q

      q.units.to_f + q.nano.to_f / 1_000_000_000.0
    end

    def now_utc
      Time.now.utc
    end

    def today_utc_start
      t = now_utc
      Time.utc(t.year, t.month, t.day)
    end

    def days_ago(n)
      Time.at(now_utc.to_i - n * 86_400).utc
    end

    def fetch_candles(client, figi:, from:, to:, interval:)
      client.grpc_market_data.candles(figi: figi, from: from, to: to, interval: interval)
    rescue InvestTinkoff::GRPC::Error
      nil
    end

    def last_daily_closes(client, figi, days: 10)
      resp = fetch_candles(client, figi: figi, from: days_ago(days * 2), to: now_utc, interval: DAY)
      return [] unless resp && resp.candles
      today = now_utc.strftime('%Y-%m-%d')
      resp.candles
          .reject { |c| Time.at(c.time.seconds).utc.strftime('%Y-%m-%d') == today }
          .map { |c| q_to_decimal(c.close) }
          .compact
          .last(days)
    end

    def safe_share_by_ticker(client, ticker, class_code: 'TQBR')
      client.grpc_instruments.share_by_ticker(ticker: ticker, class_code: class_code)
    rescue InvestTinkoff::GRPC::Error
      begin
        client.grpc_instruments.share_by_ticker(ticker: ticker)
      rescue InvestTinkoff::GRPC::Error
        nil
      end
    end
  end
end
