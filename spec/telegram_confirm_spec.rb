# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/telegram_confirm'
require 'ostruct'

RSpec.describe TradingLogic::TelegramConfirm do
  let(:token) { 'dummy-token' }
  let(:chat_id) { '12345' }
  let(:text) { 'Please confirm order' }

  describe '.send_message' do
    it 'returns true when Telegram responds ok (HTTP 200 and ok=true)' do
      fake_resp = OpenStruct.new(code: '200', body: '{"ok":true,"result":{}}')
      allow(Net::HTTP).to receive(:post).and_return(fake_resp)

      result = described_class.send_message(bot_token: token, chat_id: chat_id, text: text)
      expect(result).to be true
    end

    it 'sends plain text when parse_mode is nil' do
      fake_resp = OpenStruct.new(code: '200', body: '{"ok":true,"result":{}}')
      captured_body = nil
      allow(Net::HTTP).to receive(:post) do |_uri, body, _headers|
        captured_body = JSON.parse(body)
        fake_resp
      end

      described_class.send_message(bot_token: token, chat_id: chat_id, text: 'bundle exec rake moex_cache:sync', parse_mode: nil)

      expect(captured_body).not_to have_key('parse_mode')
      expect(captured_body['text']).to include('moex_cache:sync')
    end

    it 'returns false on non-200 response' do
      fake_resp = OpenStruct.new(code: '500', body: 'error')
      allow(Net::HTTP).to receive(:post).and_return(fake_resp)

      result = described_class.send_message(bot_token: token, chat_id: chat_id, text: text)
      expect(result).to be false
    end

    it 'returns false when Telegram responds ok=false' do
      fake_resp = OpenStruct.new(code: '200', body: '{"ok":false,"description":"bad"}')
      allow(Net::HTTP).to receive(:post).and_return(fake_resp)

      result = described_class.send_message(bot_token: token, chat_id: chat_id, text: text)
      expect(result).to be false
    end
  end
end
