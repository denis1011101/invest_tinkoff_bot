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
      timestamp_to_utc(candle.respond_to?(:time) ? candle.time : nil)
    end

    # Google::Protobuf::Timestamp (или Time/строка) -> UTC Time.
    def timestamp_to_utc(raw_time)
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

      !candle_of_today?(candle, now: now)
    end

    # Сессии MOEX в UTC с долей дневного объёма на каждую.
    # Основная 10:00–18:45 MSK = 07:00–15:45 UTC, вечерняя 19:05–23:50 MSK = 16:05–20:50 UTC.
    # Веса — грубая оценка распределения оборота (вечерняя сессия ~10%); внутри сессии
    # считаем объём равномерным. Модель приблизительная, но снимает главное искажение —
    # сравнение неполного дня с полными.
    SESSION_SEGMENTS = [
      { from: 7 * 60, to: (15 * 60) + 45, weight: 0.9 },
      { from: (16 * 60) + 5, to: (20 * 60) + 50, weight: 0.1 }
    ].freeze

    # Какая доля дневного объёма уже должна была наторговаться к моменту now.
    def session_volume_fraction(now: now_utc)
      minutes = (now.hour * 60) + now.min

      SESSION_SEGMENTS.sum do |seg|
        if minutes >= seg[:to]
          seg[:weight]
        elsif minutes <= seg[:from]
          0.0
        else
          seg[:weight] * (minutes - seg[:from]).to_f / (seg[:to] - seg[:from])
        end
      end
    end

    def candle_of_today?(candle, now: now_utc)
      candle_time = candle_time_utc(candle)
      return false unless candle_time

      candle_time.strftime('%Y-%m-%d') == now.utc.strftime('%Y-%m-%d')
    end

    def completed_daily_candles(candles, now: now_utc)
      return [] unless candles

      candles.select { |candle| candle_complete?(candle, now: now) }
    end

    def last_daily_closes(client, figi, days: 10)
      # Константу берём по полному пути: раньше здесь был голый DAY, который
      # резолвился только через top-level константу из bin/current_strategy.rb
      # и падал бы NameError при вызове из любой другой точки входа.
      day_interval = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY
      resp = fetch_candles(client, figi: figi, from: days_ago(days * 2), to: now_utc, interval: day_interval)
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
