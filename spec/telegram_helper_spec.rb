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

  it 'can disable previews for inline links' do
    response = instance_double(Net::HTTPOK, code: '200', body: '{"ok":true}')
    allow(Net::HTTP).to receive(:post).and_return(response)

    helper.send_telegram(bot_token: 'token', chat_id: '123', text: '[FRED](https://fred.stlouisfed.org)', disable_link_preview: true)

    expect(Net::HTTP).to have_received(:post).with(anything, satisfy do |json|
      JSON.parse(json)['link_preview_options'] == { 'is_disabled' => true }
    end, anything)
  end
end
