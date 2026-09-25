# frozen_string_literal: true

require 'time'
require 'zlib'

module TradingLogic
  # Operational warnings only; executed trades still come from the broker.
  class StrategyLogSummary
    INSTRUMENT_REASONS = { instrument_unresolved: 'инструмент не найден', invalid_lot: 'некорректный лот' }.freeze
    # Судьба SELL-заявок: каждое событие пишется в лог один раз на заявку.
    SELL_ORDER_EVENTS = {
      'CANCELLED' => :cancelled, 'PARTIAL' => :partial,
      'PENDING LONG' => :pending_long, 'PENDING STUCK' => :pending_stuck
    }.freeze
    SELL_ORDER_LABELS = {
      cancelled: 'SELL не исполнена, заявка снята',
      partial: 'SELL исполнена частично',
      pending_long: 'SELL висит дольше порога',
      pending_stuck: 'SELL с неизвестным исходом, нужна ручная проверка'
    }.freeze
    SELL_ORDER_EVENT = /\A(\S+) (?:WARN|ERROR): SELL (#{SELL_ORDER_EVENTS.keys.join('|')}) (\S+) /
    SELL_MISMATCH_EVENT = /\A(\S+) ERROR: sell consistency mismatch /

    def initialize(path:, logger: nil)
      @path = path
      @logger = logger
    end

    def build(from:, to:)
      result = { ok: true, unknown_session_count: 0, instrument_unresolved: Hash.new(0), invalid_lot: Hash.new(0),
                 sell_orders: Hash.new { |h, k| h[k] = Hash.new(0) }, sell_mismatch_count: 0 }
      log_paths.each do |path|
        # Rotations last written before the window cannot contain its events.
        next if path != @path && File.mtime(path) < from

        each_line(path) do |line|
          next if count_sell_order_event(result, line, from, to)

          event = warning_event(line)
          next unless event && from <= event[:time] && event[:time] < to

          if event[:figi]
            result[event[:reason]][event[:figi]] += 1
          else
            result[:unknown_session_count] += 1
          end
        end
      end
      result
    rescue SystemCallError, IOError, Zlib::Error => e
      @logger&.warn("strategy log summary unavailable: #{e.class}: #{e.message}")
      { ok: false, reason: :log_unavailable }
    end

    def self.format(summary)
      return [] unless summary
      return ['', '⚠️ Диагностика SELL за 24ч: н/д (лог недоступен).'] unless summary[:ok]

      count = summary[:unknown_session_count]
      prefix = count.positive? ? '⚠️ ' : ''
      lines = ['', "#{prefix}Предупреждения SELL о неизвестной сессии за 24ч: #{count}."]
      INSTRUMENT_REASONS.each do |reason, label|
        counts = summary.fetch(reason, {})
        next if counts.empty?

        lines << "⚠️ SELL: #{label}. Пропусков за 24ч: #{counts.values.sum}."
        counts.sort.each { |figi, total| lines << "#{figi}: #{total}" }
      end
      lines + format_sell_orders(summary)
    end

    def self.format_sell_orders(summary)
      lines = SELL_ORDER_LABELS.filter_map do |kind, label|
        counts = summary.fetch(:sell_orders, {}).fetch(kind, {})
        next if counts.empty?

        "⚠️ #{label}: #{counts.sort.map { |ticker, total| "#{ticker} (#{total})" }.join(', ')}."
      end
      mismatches = summary.fetch(:sell_mismatch_count, 0)
      lines << "⚠️ Продажи расходятся с брокером дольше порога: #{mismatches}." if mismatches.positive?
      lines
    end

    private

    def log_paths
      rotated = Dir.glob("#{@path}.[0-9]*").grep(/\.\d+(?:\.gz)?\z/).sort
      # During compression both forms may exist; read each rotation only once.
      [@path, *rotated.uniq { |path| path.delete_suffix('.gz') }]
    end

    def each_line(path, &)
      if path.end_with?('.gz')
        Zlib::GzipReader.open(path) { |reader| reader.each_line(&) }
      else
        File.foreach(path, &)
      end
    end

    def count_sell_order_event(result, line, from, to)
      # В логе почти одни DEBUG-строки: регэкспы только для WARN/ERROR.
      return false unless line.include?(' WARN: ') || line.include?(' ERROR: ')

      if (match = line.match(SELL_ORDER_EVENT))
        return true unless in_window?(match[1], from, to)

        result[:sell_orders][SELL_ORDER_EVENTS.fetch(match[2])][match[3]] += 1
      elsif (match = line.match(SELL_MISMATCH_EVENT))
        result[:sell_mismatch_count] += 1 if in_window?(match[1], from, to)
      else
        return false
      end
      true
    end

    def in_window?(timestamp, from, to)
      time = Time.iso8601(timestamp)
      from <= time && time < to
    rescue ArgumentError
      false
    end

    def warning_event(line)
      return unless line.include?('proceeding with unknown session') || line.include?('reason=instrument_unresolved') ||
                    line.include?('reason=invalid_lot')

      match = line.match(/\A(\S+) WARN: (?:FORCE )?SELL \S+ (.*)$/)
      return unless match

      message = match[2]
      skip = message.match(/\Askipped — reason=(instrument_unresolved|invalid_lot) figi=(\S+)/)
      return unless skip || message.start_with?('proceeding with unknown session — trading_session ')

      { time: Time.iso8601(match[1]), reason: skip && skip[1].to_sym, figi: skip && skip[2] }
    rescue ArgumentError
      nil
    end
  end
end
