# frozen_string_literal: true
require 'net/http'
require 'json'
require 'uri'
require 'time'

module TradingLogic
  class TelegramConfirm
    def initialize(bot_token:, chat_id:)
      @bot_token = bot_token
      @chat_id = chat_id.to_s
      @base = URI("https://api.telegram.org/bot#{@bot_token}")
      @last_update_id = nil
    end

    def enabled?
      @bot_token && !@bot_token.empty? && @chat_id && !@chat_id.empty?
    end

    def send_message(text)
      return unless enabled?
      uri = URI.join(@base.to_s, '/sendMessage')
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = { chat_id: @chat_id, text: text, parse_mode: 'Markdown' }.to_json
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    rescue => e
      warn "Telegram send_message error: #{e.class}: #{e.message}"
      nil
    end

    # wait for plain-text confirmation ('yes' / 'y') within timeout seconds
    def confirm?(prompt, timeout: 120)
      return true unless enabled? # auto-confirm if telegram not configured
      send_message("#{prompt}\n\nReply `yes` to confirm within #{timeout}s.")
      deadline = Time.now + timeout
      loop do
        sleep 1
        get_updates.each do |u|
          next unless u['message'] && u['message']['chat'] && u['message']['text']
          next unless u['message']['chat']['id'].to_s == @chat_id.to_s
          txt = u['message']['text'].strip.downcase
          return true if %w[y yes ok confirm].include?(txt)
          return false if %w[n no cancel].include?(txt)
        end
        return false if Time.now >= deadline
      end
    rescue => e
      warn "Telegram confirm error: #{e.class}: #{e.message}"
      false
    end

    private

    def get_updates
      uri = URI.join(@base.to_s, '/getUpdates')
      params = {}
      params[:offset] = @last_update_id + 1 if @last_update_id
      uri.query = URI.encode_www_form(params) unless params.empty?
      res = Net::HTTP.get_response(uri)
      return [] unless res.is_a?(Net::HTTPSuccess)
      body = JSON.parse(res.body)
      updates = body['result'] || []
      unless updates.empty?
        @last_update_id = updates.map { |u| u['update_id'] }.max
      end
      updates
    rescue => e
      warn "Telegram get_updates error: #{e.class}: #{e.message}"
      []
    end
  end
end
