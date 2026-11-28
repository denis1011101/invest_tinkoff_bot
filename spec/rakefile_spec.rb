# frozen_string_literal: true

require_relative 'spec_helper'
require 'rake'

RSpec.describe 'Rakefile' do
  let(:rakefile_path) { File.expand_path('../Rakefile', __dir__) }

  around do |example|
    original_rake = Rake.application
    original_token = ENV.delete('TINKOFF_TOKEN')
    Rake.application = Rake::Application.new
    load rakefile_path
    example.run
  ensure
    Rake.application = original_rake
    ENV['TINKOFF_TOKEN'] = original_token if original_token
  end

  it 'runs moex:refresh without TINKOFF_TOKEN' do
    moex = instance_double(TradingLogic::MoexISS)
    allow(TradingLogic::MoexISS).to receive(:new).and_return(moex)
    allow(moex).to receive(:index_constituents).with('IMOEX').and_return([{ secid: 'SBER' }])

    expect(InvestTinkoff::V2::Client).not_to receive(:new)

    expect { Rake::Task['moex:refresh'].invoke }.not_to raise_error
  end

  it 'runs moex_cache:sync without TINKOFF_TOKEN' do
    syncer = instance_double(TradingLogic::MoexCacheSyncer)
    allow(TradingLogic::MoexCacheSyncer).to receive(:new).and_return(syncer)
    allow(syncer).to receive(:perform).with(index: 'IMOEX', dry_run: false).and_return(
      { dry_run: false, path: '/tmp/moex.json', sha256: 'abc' }
    )

    expect(InvestTinkoff::V2::Client).not_to receive(:new)

    expect { Rake::Task['moex_cache:sync'].invoke }.not_to raise_error
  end

  it 'prints prices, index links and unavailable quotes before notifying Telegram' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WISHLIST_TELEGRAM_BOT_TOKEN').and_return('telegram-token')
    allow(ENV).to receive(:[]).with('WISHLIST_TELEGRAM_CHAT_ID').and_return('test-chat')
    client = instance_double(InvestTinkoff::V2::Client)
    allow(TOPLEVEL_BINDING.receiver).to receive(:tinkoff_client).and_return(client)
    monitor = TradingLogic::PriceMonitor.new(client)
    allow(TradingLogic::PriceMonitor).to receive(:new).with(client).and_return(monitor)
    results = [
      { label: 'Золото', price: 3650.0, delta: 5.0 },
      { label: 'S&P 500', link: 'https://fred.stlouisfed.org/series/SP500' },
      { label: 'Платина', unavailable: true }
    ]
    allow(monitor).to receive(:fetch_all).and_return(results)
    expect(monitor).to receive(:notify_telegram).with(results, bot_token: 'telegram-token', chat_id: 'test-chat').and_return(true)

    expect { Rake::Task['price_monitor:run'].invoke }.to output(<<~TEXT).to_stdout
      Золото: 3650.0 (+5.0)
      S&P 500: https://fred.stlouisfed.org/series/SP500
      Платина: data unavailable
      Telegram notification sent
    TEXT
  end
end
