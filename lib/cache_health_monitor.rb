# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require_relative 'market_cache'
require_relative 'moex_iss'
require_relative 'strategy_helpers'
require_relative 'telegram_confirm'

module TradingLogic
  class CacheHealthMonitor
    STATE_PATH = File.expand_path('../tmp/cache_health_state.json', __dir__)

    def self.default_cache_configs(env = ENV)
      warn_hours = (env['CACHE_WARN_AGE_HOURS'] || '36').to_f
      critical_hours = (env['CACHE_CRITICAL_AGE_HOURS'] || '60').to_f
      stale_hours = (env['INTERSECTION_CACHE_MAX_AGE_HOURS'] || '72').to_f
      repeat_hours = (env['CACHE_ALERT_REPEAT_HOURS'] || '12').to_f

      {
        'moex' => {
          path: TradingLogic::MoexISS::CACHE_PATH,
          label: 'MOEX cache',
          warn_hours: warn_hours,
          critical_hours: critical_hours,
          stale_hours: stale_hours,
          repeat_hours: repeat_hours,
          remediation: 'Run locally: bundle exec rake moex_cache:sync INDEX=IMOEX'
        },
        'market' => {
          path: TradingLogic::MarketCache::CACHE_PATH,
          label: 'Market cache',
          warn_hours: warn_hours,
          critical_hours: critical_hours,
          stale_hours: stale_hours,
          repeat_hours: repeat_hours,
          remediation: 'Run on server: bundle exec rake market_cache:refresh FORCE=true'
        }
      }
    end

    def initialize(state_path: STATE_PATH, cache_configs: self.class.default_cache_configs,
                   bot_token: ENV.fetch('TELEGRAM_BOT_TOKEN', nil), chat_id: ENV.fetch('TELEGRAM_CHAT_ID', nil),
                   now_proc: -> { Time.now.utc }, notifier: nil)
      @state_path = state_path
      @cache_configs = cache_configs
      @now_proc = now_proc
      @notifier = notifier || default_notifier(bot_token, chat_id)
    end

    def check(targets: nil)
      state = load_state
      results = {}
      target_names = targets ? Array(targets).map(&:to_s) : @cache_configs.keys

      target_names.each do |name|
        config = @cache_configs.fetch(name)
        results[name] = evaluate_cache(name, config, state)
      end

      save_state(state)
      results
    end

    private

    def evaluate_cache(name, config, state)
      now = @now_proc.call.utc
      updated_at = TradingLogic::StrategyHelpers.cache_updated_at(config[:path])&.utc
      age_hours = updated_at ? ((now - updated_at) / 3600.0) : nil
      level = determine_level(age_hours, config)
      previous = state[name] || {}

      if should_notify?(previous, level, updated_at, config, now)
        notify_success = @notifier && @notifier.call(build_message(level, config, updated_at, age_hours)) == true
        if notify_success
          previous['last_alert_at'] = now.iso8601
          previous['last_notified_level'] = level
          previous['last_notified_updated_at'] = updated_at&.iso8601
        end
      end

      state[name] = previous.merge(
        'level' => level,
        'observed_updated_at' => updated_at&.iso8601
      )

      { level: level, updated_at: updated_at, age_hours: age_hours }
    end

    def determine_level(age_hours, config)
      return 'stale' unless age_hours
      return 'stale' if age_hours >= config[:stale_hours]
      return 'critical' if age_hours >= config[:critical_hours]
      return 'warning' if age_hours >= config[:warn_hours]

      'ok'
    end

    def should_notify?(previous, level, updated_at, config, now)
      last_notified_level = previous['last_notified_level']
      return last_notified_level && last_notified_level != 'ok' if level == 'ok'
      return true if last_notified_level != level

      previous_updated_at = previous['last_notified_updated_at']
      current_updated_at = updated_at&.iso8601
      return true if previous_updated_at != current_updated_at

      last_alert_at = parse_time(previous['last_alert_at'])
      return true unless last_alert_at

      ((now - last_alert_at) / 3600.0) >= config[:repeat_hours]
    end

    def build_message(level, config, updated_at, age_hours)
      label = config[:label]
      case level
      when 'ok'
        "#{label} restored. updated_at=#{updated_at.iso8601}."
      when 'warning'
        "#{label} warning: age #{format('%.1f', age_hours)}h. #{config[:remediation]}"
      when 'critical'
        hours_left = [config[:stale_hours] - age_hours, 0].max
        "#{label} critical: age #{format('%.1f', age_hours)}h. " \
          "Buys may stop in #{format('%.1f', hours_left)}h. #{config[:remediation]}"
      else
        if updated_at
          "#{label} stale: age #{format('%.1f', age_hours)}h. " \
            "Intersection buys are blocked. #{config[:remediation]}"
        else
          "#{label} stale: cache missing or invalid. Intersection buys are blocked. #{config[:remediation]}"
        end
      end
    end

    def load_state
      return {} unless File.exist?(@state_path)

      JSON.parse(File.read(@state_path))
    rescue StandardError
      {}
    end

    def save_state(state)
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.write(@state_path, JSON.pretty_generate(state))
    end

    def parse_time(raw)
      return nil if raw.to_s.empty?

      Time.parse(raw.to_s).utc
    rescue StandardError
      nil
    end

    def default_notifier(bot_token, chat_id)
      return nil if bot_token.to_s.empty? || chat_id.to_s.empty?

      lambda do |text|
        TradingLogic::TelegramConfirm.send_message(bot_token: bot_token, chat_id: chat_id, text: text, parse_mode: nil)
      end
    end
  end
end
