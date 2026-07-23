# frozen_string_literal: true

require 'time'

module TradingLogic
  module Utils
    module_function

    def q_to_decimal(q)
      return nil unless q

      q.units.to_f + (q.nano.to_f / 1_000_000_000.0)
    end

    def now_utc
      Time.now.utc
    end

    def today_utc_start
      t = now_utc
      Time.utc(t.year, t.month, t.day)
    end

    def days_ago(n)
      Time.at(now_utc.to_i - (n * 86_400)).utc
    end

    def fetch_candles(client, from:, to:, interval:, figi: nil, instrument_id: nil)
      client.grpc_market_data.candles(
        figi: figi, instrument_id: instrument_id, from: from, to: to, interval: interval
      )
    rescue InvestTinkoff::GRPC::Error
      nil
    end

    def candle_time_utc(candle)
      raw_time = candle.respond_to?(:time) ? candle.time : nil
      return nil unless raw_time

      if raw_time.respond_to?(:seconds)
        Time.at(raw_time.seconds).utc
      elsif raw_time.is_a?(Time)
        raw_time.utc
      else
        Time.parse(raw_time.to_s).utc
      end
    rescue StandardError
      nil
    end

    # Используем только завершённые дневные свечи.
    # Если поле is_complete отсутствует, исключаем свечу за текущую торговую дату.
    def candle_complete?(candle, now: now_utc)
      return candle.is_complete == true if candle.respond_to?(:is_complete)

      candle_time = candle_time_utc(candle)
      return true unless candle_time

      candle_time.strftime('%Y-%m-%d') != now.utc.strftime('%Y-%m-%d')
    end

    def completed_daily_candles(candles, now: now_utc)
      return [] unless candles

      candles.select { |candle| candle_complete?(candle, now: now) }
    end

    def last_daily_closes(client, figi, days: 10)
      resp = fetch_candles(client, figi: figi, from: days_ago(days * 2), to: now_utc, interval: DAY)
      return [] unless resp&.candles

      completed_daily_candles(resp.candles, now: now_utc)
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
