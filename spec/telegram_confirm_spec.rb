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
