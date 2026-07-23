# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/market_cache'
require 'ostruct'

RSpec.describe TradingLogic::MarketCache do
  subject(:mc) { described_class.new(double('client')) }

  def share(attrs = {})
    OpenStruct.new({ class_code: 'TQBR', currency: 'rub', api_trade_available_flag: true }.merge(attrs))
  end

  describe 'cache ttl configuration' do
    it 'uses hour-based ttl and ignores legacy day-based env value' do
      env = { 'INSTRUMENT_CACHE_DAYS' => '7' }

      expect(described_class.cache_ttl_hours(env)).to eq(24.0)
    end

    it 'uses INSTRUMENT_CACHE_HOURS when provided' do
      env = { 'INSTRUMENT_CACHE_HOURS' => '36', 'INSTRUMENT_CACHE_DAYS' => '7' }

      expect(described_class.cache_ttl_hours(env)).to eq(36.0)
    end
  end

  describe 'instrument filtering (only tradable rub TQBR shares)' do
    it 'accepts a rub TQBR api-tradable share' do
      expect(mc.send(:allowed_instrument?, share(ticker: 'SBER'))).to be true
    end

    it 'rejects a non-TQBR class_code (e.g. foreign T on SPBXM)' do
      expect(mc.send(:allowed_instrument?, share(class_code: 'SPBXM'))).to be false
    end

    it 'rejects a non-rub currency (e.g. AT&T in usd)' do
      expect(mc.send(:allowed_instrument?, share(currency: 'usd'))).to be false
    end

    it 'rejects a share not available for API trading' do
      expect(mc.send(:allowed_instrument?, share(api_trade_available_flag: false))).to be false
    end
  end

  describe '#refresh_market_cache failure semantics' do
    it 'returns false (not true) when the shares list is empty, without overwriting' do
      client = double('client')
      svc = double('instruments')
      allow(client).to receive(:grpc_instruments).and_return(svc)
      allow(svc).to receive(:shares).and_return(OpenStruct.new(instruments: []))

      expect(File).not_to receive(:write)
      expect(described_class.new(client).refresh_market_cache(force: true)).to be false
    end
  end
end
