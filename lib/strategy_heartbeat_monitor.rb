# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require_relative 'telegram_confirm'

module TradingLogic
  # Сторож живости стратегии.
  #
  # Стратегия крутится в кроне каждые 5 минут под `flock -n` и на каждом прогоне
  # пишет в лог хотя бы строку scan_id — то есть круглосуточно, а не только в
  # торговые часы. Значит любая тишина дольше нескольких прогонов это поломка.
  #
  # 2026-08-18 прогон завис на gRPC-вызове к брокеру (ESTABLISHED-сокет, в который
  # уже ничего не придёт) и держал лок 2ч45м — cron всё это время молча пропускал
  # запуски, в логе не появилось ни строки, ни ошибки. Снаружи это выглядело как
  # «бот просто ничего не покупает». Дедлайны в геме закрывают ту конкретную
  # причину; этот сторож ловит сам симптом — тишину, чем бы она ни была вызвана.
  #
  # Отдельно подсвечиваем зависший прогон: если ruby-процесс стратегии живёт
  # дольше HUNG_RUN_MINUTES, в алерт попадает его pid, чтобы не искать руками.
  class StrategyHeartbeatMonitor
    LOG_PATH = File.expand_path('../logs/current_strategy.log', __dir__)
    STATE_PATH = File.expand_path('../tmp/strategy_heartbeat_state.json', __dir__)
    PROCESS_PATTERN = 'current_strategy.rb'

    def self.default_config(env = ENV)
      {
        path: env['STRATEGY_HEARTBEAT_LOG'].to_s.empty? ? LOG_PATH : env['STRATEGY_HEARTBEAT_LOG'],
        label: 'Strategy heartbeat',
        warn_minutes: (env['STRATEGY_HEARTBEAT_WARN_MINUTES'] || '20').to_f,
        critical_minutes: (env['STRATEGY_HEARTBEAT_CRITICAL_MINUTES'] || '60').to_f,
        repeat_hours: (env['STRATEGY_HEARTBEAT_REPEAT_HOURS'] || '6').to_f,
        hung_run_minutes: (env['STRATEGY_HUNG_RUN_MINUTES'] || '15').to_f,
        remediation: 'Check on server: ps -o lstart=,etime= -C ruby; the lock is /tmp/current_strategy.lock'
      }
    end

    def initialize(state_path: STATE_PATH, config: self.class.default_config,
                   bot_token: ENV.fetch('TELEGRAM_BOT_TOKEN', nil), chat_id: ENV.fetch('TELEGRAM_CHAT_ID', nil),
                   now_proc: -> { Time.now.utc }, notifier: nil, process_lookup: nil)
      @state_path = state_path
      @config = config
      @now_proc = now_proc
      @notifier = notifier || default_notifier(bot_token, chat_id)
      @process_lookup = process_lookup || method(:running_strategy_processes)
    end

    def check
      state = load_state
      now = @now_proc.call.utc
      written_at = last_write_at
      age_minutes = written_at ? ((now - written_at) / 60.0) : nil
      level = determine_level(age_minutes)
      hung_run = hung_run_info(now)

      notify_if_needed(state, level, written_at, age_minutes, hung_run, now)

      state['level'] = level
      state['observed_written_at'] = written_at&.iso8601
      save_state(state)

      { level: level, written_at: written_at, age_minutes: age_minutes, hung_run: hung_run }
    end

    private

    def last_write_at
      path = @config[:path]
      return nil unless File.exist?(path)

      File.mtime(path).utc
    rescue StandardError
      nil
    end

    # Лога нет вообще — это не «свежо», а неизвестно; трактуем как critical,
    # иначе пустой/переехавший путь молча выглядел бы здоровым.
    def determine_level(age_minutes)
      return 'critical' unless age_minutes
      return 'critical' if age_minutes >= @config[:critical_minutes]
      return 'warning' if age_minutes >= @config[:warn_minutes]

      'ok'
    end

    def hung_run_info(now)
      processes = Array(@process_lookup.call)
      return nil if processes.empty?

      oldest = processes.max_by { |proc_info| proc_info[:elapsed_seconds].to_i }
      return nil unless oldest

      minutes = oldest[:elapsed_seconds].to_i / 60.0
      return nil if minutes < @config[:hung_run_minutes]

      { pid: oldest[:pid], minutes: minutes, since: (now - oldest[:elapsed_seconds].to_i) }
    end

    # `ps` вместо pgrep: нужен возраст процесса, а не только pid. Ошибку ps
    # глотаем — сторож без списка процессов всё равно полезен, тишину он ловит.
    #
    # Фильтруем по имени исполняемого файла, а не по вхождению 'ruby' в строку:
    # обёртки sh/flock/bash несут в аргументах ту же команду целиком, а убивать
    # надо именно ruby — он наследует fd лока, так что смерть обёрток лок не освободит.
    def running_strategy_processes
      # Статус ps не проверяем: упавший ps отдаёт пустой вывод, а пустой вывод и
      # так означает «зависших прогонов не видно».
      output = `ps -eo pid=,etimes=,args= 2>/dev/null`
      output.to_s.lines.filter_map do |line|
        pid, elapsed, args = line.strip.split(/\s+/, 3)
        next unless args&.include?(PROCESS_PATTERN)
        next unless File.basename(args.split(/\s+/).first.to_s).start_with?('ruby')

        { pid: pid.to_i, elapsed_seconds: elapsed.to_i, command: args }
      end
    rescue StandardError
      []
    end

    def notify_if_needed(state, level, written_at, age_minutes, hung_run, now)
      return unless should_notify?(state, level, written_at, now)

      message = build_message(level, written_at, age_minutes, hung_run)
      return unless @notifier && @notifier.call(message) == true

      state['last_alert_at'] = now.iso8601
      state['last_notified_level'] = level
      state['last_notified_written_at'] = written_at&.iso8601
    end

    def should_notify?(state, level, written_at, now)
      last_notified_level = state['last_notified_level']
      # Про «ok» пишем только как о восстановлении после плохого уровня.
      return last_notified_level && last_notified_level != 'ok' if level == 'ok'
      return true if last_notified_level != level

      # Лог снова начал писаться, но уровень тот же — это уже другой инцидент.
      return true if state['last_notified_written_at'] != written_at&.iso8601

      last_alert_at = parse_time(state['last_alert_at'])
      return true unless last_alert_at

      ((now - last_alert_at) / 3600.0) >= @config[:repeat_hours]
    end

    def build_message(level, written_at, age_minutes, hung_run)
      label = @config[:label]
      return "#{label} restored. Last write #{format_age(age_minutes)} ago." if level == 'ok'

      parts = ["#{label} #{level}: #{silence_phrase(written_at, age_minutes)}."]
      if hung_run
        parts << "Hung run: pid #{hung_run[:pid]} alive #{format_age(hung_run[:minutes])} " \
                 "(since #{hung_run[:since].iso8601}); it holds the cron lock, so every later run is skipped."
      end
      parts << @config[:remediation]
      parts.join(' ')
    end

    def silence_phrase(written_at, age_minutes)
      return "log #{@config[:path]} is missing" unless written_at

      "no log write for #{format_age(age_minutes)}"
    end

    def format_age(minutes)
      return 'n/a' unless minutes

      minutes >= 60 ? "#{format('%.1f', minutes / 60.0)}h" : "#{format('%.1f', minutes)}min"
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
