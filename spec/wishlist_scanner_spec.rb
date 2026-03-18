# frozen_string_literal: true

require_relative 'spec_helper'
require 'ostruct'
require 'tmpdir'
require 'json'
require 'fileutils'
require_relative '../lib/wishlist_scanner'

RSpec.describe TradingLogic::WishlistScanner do
  let(:client) { double('client') }
  let(:market_data) { double('market_data') }
  let(:instruments_svc) { double('instruments') }

  before do
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments_svc)
  end

  subject { described_class.new(client, candle_sleep: 0) }

  def q(units, nano = 0)
    OpenStruct.new(units: units, nano: nano)
  end

  def make_candles(prices)
    candles = prices.map { |p| OpenStruct.new(close: q(p)) }
    OpenStruct.new(candles: candles)
  end

  def stub_candles_for(figi, prices)
    allow(market_data).to receive(:candles)
      .with(hash_including(figi: figi))
      .and_return(make_candles(prices))
  end

  describe '#scan_one' do
    let(:universe) { [{ 'ticker' => 'SBER', 'figi' => 'FIGI1' }, { 'ticker' => 'ROSN', 'figi' => 'FIGI2' }] }

    before do
      allow(subject).to receive(:resolve_universe).and_return(universe)
      allow(subject).to receive(:save_result)
    end

    context '52day_low' do
      it 'finds stocks near their 52-day minimum' do
        # SBER: min=90, current=91 -> 1.11% above low
        sber_prices = Array.new(50, 100.0) + [90.0, 91.0]
        stub_candles_for('FIGI1', sber_prices)

        # ROSN: min=50, current=80 -> 60% above -> excluded (>5%)
        rosn_prices = Array.new(50, 80.0) + [50.0, 80.0]
        stub_candles_for('FIGI2', rosn_prices)

        config = { 'condition' => '52day_low', 'params' => { 'days' => 52 }, 'top_n' => 10 }
        result = subject.scan_one(config)

        expect(result['matches'].size).to eq(1)
        expect(result['matches'][0]['ticker']).to eq('SBER')
        expect(result['matches'][0]['price']).to eq(91.0)
      end

      it 'sorts by proximity to low (ascending)' do
        # SBER: 1% above low
        sber_prices = Array.new(50, 110.0) + [100.0, 101.0]
        stub_candles_for('FIGI1', sber_prices)

        # ROSN: 3% above low
        rosn_prices = Array.new(50, 110.0) + [100.0, 103.0]
        stub_candles_for('FIGI2', rosn_prices)

        config = { 'condition' => '52day_low', 'params' => { 'days' => 52 }, 'top_n' => 10 }
        result = subject.scan_one(config)

        expect(result['matches'].size).to eq(2)
        expect(result['matches'][0]['ticker']).to eq('SBER')
        expect(result['matches'][1]['ticker']).to eq('ROSN')
      end
    end

    context 'growth_months' do
      it 'finds stocks growing for N consecutive months' do
        # 3 months = 66 trading days. monthly_closes sampled at day -1, -23, -45, -67
        # Growing: 100 -> 110 -> 120 -> 130
        sber_prices = [100.0] + Array.new(21,
                                          105.0) + [110.0] + Array.new(21,
                                                                       115.0) + [120.0] + Array.new(21, 125.0) + [130.0]
        stub_candles_for('FIGI1', sber_prices)

        # Not growing: 100 -> 110 -> 105 -> 130
        rosn_prices = [100.0] + Array.new(21,
                                          105.0) + [110.0] + Array.new(21,
                                                                       103.0) + [105.0] + Array.new(21, 125.0) + [130.0]
        stub_candles_for('FIGI2', rosn_prices)

        config = { 'condition' => 'growth_months', 'params' => { 'months' => 3 }, 'top_n' => 10 }
        result = subject.scan_one(config)

        expect(result['matches'].size).to eq(1)
        expect(result['matches'][0]['ticker']).to eq('SBER')
      end
    end

    context 'below_sma' do
      it 'finds stocks below SMA' do
        # SBER: SMA50 = avg of 50 values, current below it
        sber_prices = Array.new(49, 110.0) + [100.0] + Array.new(4, 100.0) + [95.0]
        stub_candles_for('FIGI1', sber_prices)

        # ROSN: current above SMA
        rosn_prices = Array.new(49, 100.0) + [100.0] + Array.new(4, 100.0) + [120.0]
        stub_candles_for('FIGI2', rosn_prices)

        config = { 'condition' => 'below_sma', 'params' => { 'period' => 50 }, 'top_n' => 10 }
        result = subject.scan_one(config)

        below = result['matches'].select { |m| m['ticker'] == 'SBER' }
        above = result['matches'].select { |m| m['ticker'] == 'ROSN' }
        expect(below.size).to eq(1)
        expect(above.size).to eq(0)
      end
    end

    context 'drop_from_high' do
      it 'finds stocks that dropped >= min_drop_pct from high' do
        # SBER: high=200, current=150 -> -25% drop
        sber_prices = Array.new(25, 180.0) + [200.0] + Array.new(25, 160.0) + [150.0]
        stub_candles_for('FIGI1', sber_prices)

        # ROSN: high=100, current=95 -> -5% drop (below 20% threshold)
        rosn_prices = Array.new(50, 98.0) + [100.0, 95.0]
        stub_candles_for('FIGI2', rosn_prices)

        config = { 'condition' => 'drop_from_high', 'params' => { 'days' => 52, 'min_drop_pct' => 20 }, 'top_n' => 10 }
        result = subject.scan_one(config)

        expect(result['matches'].size).to eq(1)
        expect(result['matches'][0]['ticker']).to eq('SBER')
      end
    end

    it 'raises on unknown condition' do
      config = { 'condition' => 'magic', 'params' => {} }
      expect { subject.scan_one(config) }.to raise_error(/Unknown condition/)
    end

    it 'respects top_n limit' do
      universe3 = [
        { 'ticker' => 'A', 'figi' => 'FA' },
        { 'ticker' => 'B', 'figi' => 'FB' },
        { 'ticker' => 'C', 'figi' => 'FC' }
      ]
      allow(subject).to receive(:resolve_universe).and_return(universe3)

      %w[FA FB FC].each do |figi|
        prices = Array.new(50, 110.0) + [100.0, 101.0]
        stub_candles_for(figi, prices)
      end

      config = { 'condition' => '52day_low', 'params' => { 'days' => 52 }, 'top_n' => 2 }
      result = subject.scan_one(config)
      expect(result['matches'].size).to eq(2)
    end
  end

  describe '#format_telegram_message' do
    it 'formats matches into MarkdownV2 message' do
      matches = [
        { 'ticker' => 'SBER', 'price' => 245.3, 'detail' => '1.2% above 52d low' },
        { 'ticker' => 'ROSN', 'price' => 412.5, 'detail' => '2.1% above 52d low' }
      ]
      msg = subject.send(:format_telegram_message, 'Test Header', matches)

      expect(msg).to include('*Test Header*')
      expect(msg).to include('`SBER`')
      expect(msg).to include('245\.3')
      expect(msg).to include('`ROSN`')
    end

    it 'escapes MarkdownV2 special characters in header and detail' do
      matches = [
        { 'ticker' => 'TEST', 'price' => 100.0, 'detail' => 'SMA_200 [test]' }
      ]
      msg = subject.send(:format_telegram_message, 'Header_with*stars', matches)

      expect(msg).to include('Header\_with\*stars')
      expect(msg).to include('SMA\_200 \[test\]')
    end

    it 'escapes dots and dashes in price and numbering' do
      matches = [
        { 'ticker' => 'SBER', 'price' => 245.3, 'detail' => 'test' }
      ]
      msg = subject.send(:format_telegram_message, 'Header', matches)

      expect(msg).to include('1\.')
      expect(msg).to include('245\.3')
      expect(msg).to include('\—')
    end

    it 'shows no-matches text when empty' do
      msg = subject.send(:format_telegram_message, 'Empty', [])
      expect(msg).to include('Совпадений не найдено')
    end
  end

  describe 'candle caching' do
    it 'caches candle data to avoid duplicate API calls' do
      prices = Array.new(60, 100.0)
      expect(market_data).to receive(:candles)
        .with(hash_including(figi: 'FIGI1'))
        .once
        .and_return(make_candles(prices))

      subject.send(:daily_closes, 'FIGI1', days: 52)
      subject.send(:daily_closes, 'FIGI1', days: 52)
    end
  end

  describe '#resolve_universe (moex_index)' do
    it 'resolves figi by ticker when moex_index cache has no figi' do
      dir = Dir.mktmpdir
      moex_path = File.join(dir, 'moex_index_cache.json')
      File.write(moex_path, JSON.generate({
                                            'instruments' => [
                                              { 'ticker' => 'SBER' },
                                              { 'ticker' => 'ROSN' }
                                            ]
                                          }))

      stub_const('TradingLogic::WishlistScanner::WISHLISTS_DIR', File.join(dir, 'wishlists'))

      sber_resp = OpenStruct.new(instrument: OpenStruct.new(figi: 'FIGI_SBER'))
      rosn_resp = OpenStruct.new(instrument: OpenStruct.new(figi: 'FIGI_ROSN'))

      allow(instruments_svc).to receive(:share_by_ticker)
        .with(hash_including(ticker: 'SBER'))
        .and_return(sber_resp)
      allow(instruments_svc).to receive(:share_by_ticker)
        .with(hash_including(ticker: 'ROSN'))
        .and_return(rosn_resp)

      allow(TradingLogic::StrategyHelpers).to receive(:load_cache_normalized)
        .and_call_original

      allow(TradingLogic::StrategyHelpers).to receive(:load_cache_normalized)
        .with(anything)
        .and_wrap_original do |method, _path|
          method.call(moex_path)
        end

      result = subject.send(:resolve_universe, 'moex_index')

      expect(result).to contain_exactly(
        { 'ticker' => 'SBER', 'figi' => 'FIGI_SBER' },
        { 'ticker' => 'ROSN', 'figi' => 'FIGI_ROSN' }
      )
    ensure
      FileUtils.rm_rf(dir)
    end

    it 'skips instruments when share_by_ticker returns nil' do
      dir = Dir.mktmpdir
      moex_path = File.join(dir, 'moex_index_cache.json')
      File.write(moex_path, JSON.generate({
                                            'instruments' => [
                                              { 'ticker' => 'SBER' },
                                              { 'ticker' => 'GONE' }
                                            ]
                                          }))

      sber_resp = OpenStruct.new(instrument: OpenStruct.new(figi: 'FIGI_SBER'))
      allow(instruments_svc).to receive(:share_by_ticker)
        .with(hash_including(ticker: 'SBER'))
        .and_return(sber_resp)
      allow(instruments_svc).to receive(:share_by_ticker)
        .with(hash_including(ticker: 'GONE'))
        .and_return(nil)

      allow(TradingLogic::StrategyHelpers).to(
        receive(:load_cache_normalized)
        .with(anything)
        .and_wrap_original { |_method, _path| TradingLogic::StrategyHelpers.load_cache_normalized(moex_path) }
      )

      allow(TradingLogic::StrategyHelpers).to receive(:load_cache_normalized)
        .with(moex_path)
        .and_call_original

      result = subject.send(:resolve_universe, 'moex_index')
      expect(result.size).to eq(1)
      expect(result[0]['ticker']).to eq('SBER')
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  describe '#scan_all' do
    it 'loads and scans all wishlist files from directory' do
      dir = Dir.mktmpdir
      wishlists_dir = File.join(dir, 'wishlists')
      FileUtils.mkdir_p(wishlists_dir)

      File.write(File.join(wishlists_dir, 'test.json'), JSON.generate({
                                                                        'name' => 'Test',
                                                                        'condition' => '52day_low',
                                                                        'params' => { 'days' => 52 },
                                                                        'top_n' => 5,
                                                                        'universe' => 'market_cache'
                                                                      }))

      stub_const('TradingLogic::WishlistScanner::WISHLISTS_DIR', wishlists_dir)
      stub_const('TradingLogic::WishlistScanner::RESULTS_DIR', File.join(dir, 'results'))

      cache_path = File.join(dir, 'cache.json')
      File.write(cache_path, JSON.generate({ 'instruments' => [{ 'ticker' => 'SBER', 'figi' => 'FIGI1' }] }))
      stub_const('TradingLogic::MarketCache::CACHE_PATH', cache_path)

      prices = Array.new(50, 110.0) + [100.0, 101.0]
      stub_candles_for('FIGI1', prices)

      results = subject.scan_all
      expect(results).to have_key('Test')
      expect(results['Test']['matches']).to be_an(Array)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
