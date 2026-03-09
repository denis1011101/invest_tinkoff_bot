# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/telegram_helper'

RSpec.describe TradingLogic::TelegramHelper do
  let(:helper_class) do
    Class.new do
      include TradingLogic::TelegramHelper
    end
  end

  subject(:helper) { helper_class.new }

  it 'returns true when Telegram responds with HTTP 200 and ok=true' do
    response = instance_double(Net::HTTPOK, code: '200', body: '{"ok":true,"result":{}}')
    allow(Net::HTTP).to receive(:post).and_return(response)

    expect(helper.send_telegram(bot_token: 'token', chat_id: '123', text: 'hello')).to be true
  end

  it 'returns false when Telegram responds with HTTP 200 and ok=false' do
    response = instance_double(Net::HTTPOK, code: '200', body: '{"ok":false,"description":"chat not found"}')
    allow(Net::HTTP).to receive(:post).and_return(response)

    expect(helper.send_telegram(bot_token: 'token', chat_id: '123', text: 'hello')).to be false
  end

  it 'returns false on non-200 responses' do
    response = instance_double(Net::HTTPServerError, code: '500', body: 'error')
    allow(Net::HTTP).to receive(:post).and_return(response)

    expect(helper.send_telegram(bot_token: 'token', chat_id: '123', text: 'hello')).to be false
  end
end
