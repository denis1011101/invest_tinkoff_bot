# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'net/http'
require 'uri'

module TradingLogic
  # Доставка ежедневного отчёта: plain-text Telegram (без Markdown, с разбивкой
  # длинных сообщений), защита от дублей и append-only архив на машине.
  class DailyReportDelivery
    CHUNK_LIMIT = 3500

    def initialize(state_path:, archive_dir:, sender: nil, logger: nil)
      @state_path = state_path
      @archive_dir = archive_dir
      @sender = sender || method(:post_to_telegram)
      @logger = logger
    end

    def already_sent?(day)
      state = read_state
      state['last_sent_day'].to_s == day.to_s
    end

    # Возвращает true при успешной отправке всех частей. dry_run печатает в stdout
    # и не трогает state/архив. force разрешает повтор за уже отправленный день.
    def deliver(result, bot_token:, chat_id:, dry_run: false, force: false)
      day = result[:day]
      if dry_run
        puts result[:text]
        return true
      end
      return true if already_sent?(day) && !force

      chunks = chunk(result[:text])
      return false unless chunks.all? { |part| @sender.call(bot_token: bot_token, chat_id: chat_id, text: part) }

      # Только полноценный отчёт (с агрегатами) фиксируем в state и архиве;
      # служебные сообщения (напр. об ошибке) отправляем без побочных эффектов.
      if result[:aggregates]
        mark_sent!(day)
        archive_best_effort(result)
      end
      true
    end

    def chunk(text)
      parts = []
      current = +''
      text.each_line do |raw_line|
        hard_split(raw_line).each do |line|
          if current.length + line.length > CHUNK_LIMIT && !current.empty?
            parts << current
            current = +''
          end
          current << line
        end
      end
      parts << current unless current.empty?
      parts
    end

    private

    # Одна строка длиннее лимита сама по себе не влезет в сообщение Telegram —
    # режем её на куски по CHUNK_LIMIT.
    def hard_split(line)
      return [line] if line.length <= CHUNK_LIMIT

      line.chars.each_slice(CHUNK_LIMIT).map(&:join)
    end

    def read_state
      return {} unless File.exist?(@state_path)

      JSON.parse(File.read(@state_path))
    rescue StandardError
      {}
    end

    def mark_sent!(day)
      write_atomic(@state_path, JSON.pretty_generate('last_sent_day' => day.to_s, 'sent_at' => Time.now.utc.iso8601))
    end

    # Архив — вспомогательный результат: Telegram уже доставлен, поэтому сбой
    # записи логируем, но не роняем доставку и не откатываем state.
    def archive_best_effort(result)
      archive!(result)
    rescue StandardError => e
      @logger&.warn("daily report archive failed for #{result[:day]}: #{e.class}: #{e.message}")
    end

    def archive!(result)
      FileUtils.mkdir_p(@archive_dir)
      month = result[:day].to_s[0, 7]
      append_locked(File.join(@archive_dir, "#{month}.txt"), "#{result[:text]}\n\n#{'-' * 40}\n\n")
      append_locked(File.join(@archive_dir, "#{month}.jsonl"), "#{archive_json(result)}\n")
    end

    def archive_json(result)
      agg = result[:aggregates]
      idx = result[:index]
      JSON.generate(
        day: result[:day],
        buys: agg[:buys_count], sells: agg[:sells_count],
        buy_turnover: agg[:buy_turnover], sell_turnover: agg[:sell_turnover],
        fees: agg[:fees], realized: agg[:realized],
        index: idx[:ok] ? { value: idx[:current], delta_points: idx[:delta_points], delta_percent: idx[:delta_percent] } : nil,
        portfolio: result[:portfolio][:ok] ? result[:portfolio].except(:ok) : nil
      )
    end

    def append_locked(path, text)
      File.open(path, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.write(text)
      end
    end

    def write_atomic(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp-#{Process.pid}"
      File.write(tmp, content)
      File.rename(tmp, path)
    end

    def post_to_telegram(bot_token:, chat_id:, text:)
      uri = URI("https://api.telegram.org/bot#{bot_token}/sendMessage")
      body = { chat_id: chat_id.to_s, text: text }.to_json
      resp = Net::HTTP.post(uri, body, 'Content-Type' => 'application/json')
      return true if resp.code.to_i == 200 && JSON.parse(resp.body)['ok'] == true

      @logger&.warn("Telegram send failed: HTTP #{resp.code}")
      false
    rescue StandardError => e
      @logger&.warn("Telegram send error: #{e.class}: #{e.message}")
      false
    end
  end
end
