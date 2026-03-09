# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module TradingLogic
  module TelegramHelper
    def escape_md(text)
      text.to_s.gsub(/([_*\[\]()~`>#+\-=|{}.!])/, '\\\\\1')
    end

    def send_telegram(bot_token:, chat_id:, text:)
      uri = URI("https://api.telegram.org/bot#{bot_token}/sendMessage")
      body = { chat_id: chat_id.to_s, text: text, parse_mode: 'MarkdownV2' }.to_json
      response = Net::HTTP.post(uri, body, 'Content-Type' => 'application/json')
      return false unless response.code.to_i == 200

      payload = JSON.parse(response.body)
      return true if payload['ok'] == true

      warn "Telegram send error: #{payload['description'] || 'unknown API error'}"
      false
    rescue StandardError => e
      warn "Telegram send error: #{e.class}: #{e.message}"
      false
    end
  end
end
