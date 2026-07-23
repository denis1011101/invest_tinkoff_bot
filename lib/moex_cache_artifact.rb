# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module TradingLogic
  class MoexCacheArtifact
    FUTURE_SKEW_SECONDS = 300
    DEFAULT_MAX_AGE_HOURS = 6.0
    DEFAULT_MIN_COUNT_RATIO = 0.5
    DEFAULT_MIN_INSTRUMENTS = 20

    class ValidationError < StandardError; end
    class IntegrityError < StandardError; end

    def self.default_max_age_hours(env = ENV)
      (env['MOEX_CACHE_MAX_AGE_HOURS'] || DEFAULT_MAX_AGE_HOURS.to_s).to_f
    end

    def self.default_min_count_ratio(env = ENV)
      (env['MOEX_CACHE_MIN_COUNT_RATIO'] || DEFAULT_MIN_COUNT_RATIO.to_s).to_f
    end

    def self.default_min_instruments(env = ENV)
      (env['MOEX_CACHE_MIN_INSTRUMENTS'] || DEFAULT_MIN_INSTRUMENTS.to_s).to_i
    end

    def self.validate(path, expected_index:, now: Time.now.utc,
                      min_instruments: default_min_instruments,
                      max_age_hours: default_max_age_hours,
                      previous_path: TradingLogic::MoexISS::CACHE_PATH,
                      min_count_ratio: default_min_count_ratio)
      raise ValidationError, "artifact file not found: #{path}" unless File.exist?(path)

      payload = JSON.parse(File.read(path))
      index = payload['index'].to_s.strip
      raise ValidationError, "unexpected index #{index.inspect}, expected #{expected_index.inspect}" unless index == expected_index

      updated_at_raw = payload['updated_at'] || payload['updatedAt']
      updated_at = Time.parse(updated_at_raw.to_s).utc
      raise ValidationError, "updated_at is in the future: #{updated_at.iso8601}" if updated_at > now + FUTURE_SKEW_SECONDS

      age_hours = (now - updated_at) / 3600.0
      raise ValidationError, format('artifact too old: %.1fh > %.1fh', age_hours, max_age_hours) if age_hours > max_age_hours

      instruments = payload['instruments']
      raise ValidationError, 'instruments must be a non-empty array' unless instruments.is_a?(Array) && !instruments.empty?

      raise ValidationError, "instrument count #{instruments.size} is below minimum #{min_instruments}" if instruments.size < min_instruments

      seen_tickers = {}
      instruments.each_with_index do |row, idx|
        ticker = instrument_ticker(row)
        raise ValidationError, "instrument at index #{idx} has no secid/seccode/ticker" if ticker.empty?

        if seen_tickers.key?(ticker)
          raise ValidationError,
                "duplicate ticker #{ticker} at index #{idx} (first seen at index #{seen_tickers[ticker]})"
        end

        seen_tickers[ticker] = idx
      end

      previous_count = previous_instrument_count(previous_path, fallback: instruments.size)
      min_allowed = [min_instruments, (previous_count * min_count_ratio).ceil].max
      if previous_count.positive? && instruments.size < min_allowed
        raise ValidationError,
              "instrument count dropped too much: #{instruments.size} < #{min_allowed} (previous #{previous_count})"
      end

      {
        path: path,
        index: index,
        updated_at: updated_at,
        age_hours: age_hours,
        instruments_count: instruments.size,
        sha256: Digest::SHA256.file(path).hexdigest,
        payload: payload
      }
    rescue JSON::ParserError => e
      raise ValidationError, "invalid JSON: #{e.message}"
    rescue ArgumentError => e
      raise ValidationError, "invalid updated_at: #{e.message}"
    end

    def self.install(source, destination:, expected_index:, sha256: nil, now: Time.now.utc,
                     min_instruments: default_min_instruments,
                     max_age_hours: default_max_age_hours,
                     min_count_ratio: default_min_count_ratio,
                     backup_dir: File.join(File.dirname(destination), 'cache_backups'))
      metadata = validate(
        source,
        expected_index: expected_index,
        now: now,
        min_instruments: min_instruments,
        max_age_hours: max_age_hours,
        previous_path: destination,
        min_count_ratio: min_count_ratio
      )
      raise IntegrityError, "sha256 mismatch: expected #{sha256}, got #{metadata[:sha256]}" if sha256 && metadata[:sha256] != sha256

      FileUtils.mkdir_p(File.dirname(destination))
      backup_path = backup_existing(destination, backup_dir, now)
      staged_source = stage_source_for_install(source, destination)
      File.rename(staged_source, destination)
      FileUtils.rm_f(source) if File.exist?(source) && source != destination

      metadata.merge(destination: destination, backup_path: backup_path)
    end

    def self.backup_existing(destination, backup_dir, now)
      return nil unless File.exist?(destination)

      FileUtils.mkdir_p(backup_dir)
      backup_path = File.join(
        backup_dir,
        "#{File.basename(destination, '.json')}-#{now.utc.strftime('%Y%m%dT%H%M%SZ')}.json"
      )
      FileUtils.cp(destination, backup_path)
      backup_path
    end
    private_class_method :backup_existing

    def self.stage_source_for_install(source, destination)
      return source if File.dirname(source) == File.dirname(destination)

      staged = File.join(
        File.dirname(destination),
        ".#{File.basename(destination)}.incoming-#{Process.pid}-#{SecureRandom.hex(4)}"
      )
      FileUtils.cp(source, staged)
      staged
    end
    private_class_method :stage_source_for_install

    def self.previous_instrument_count(previous_path, fallback: 0)
      return fallback unless previous_path && File.exist?(previous_path)

      payload = JSON.parse(File.read(previous_path))
      instruments = payload['instruments']
      return fallback unless instruments.is_a?(Array)

      instruments.size
    rescue StandardError
      fallback
    end
    private_class_method :previous_instrument_count

    def self.instrument_ticker(row)
      return '' unless row.is_a?(Hash)

      (row['ticker'] || row['secid'] || row['seccode'] || row[:ticker] || row[:secid] || row[:seccode]).to_s.strip.upcase
    end
    private_class_method :instrument_ticker
  end
end
