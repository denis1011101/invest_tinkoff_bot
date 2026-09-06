# frozen_string_literal: true

require 'time'
require 'zlib'

module TradingLogic
  # Operational warnings only; executed trades still come from the broker.
  class StrategyLogSummary
    INSTRUMENT_REASONS = { instrument_unresolved: 'инструмент не найден', invalid_lot: 'некорректный лот' }.freeze

    def initialize(path:, logger: nil)
      @path = path
      @logger = logger
    end

    def build(from:, to:)
      result = { ok: true, unknown_session_count: 0, instrument_unresolved: Hash.new(0), invalid_lot: Hash.new(0) }
      log_paths.each do |path|
        # Rotations last written before the window cannot contain its events.
        next if path != @path && File.mtime(path) < from

        each_line(path) do |line|
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
