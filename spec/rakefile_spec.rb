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
end
