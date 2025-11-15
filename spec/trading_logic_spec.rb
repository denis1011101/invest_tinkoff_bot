require_relative 'spec_helper'
require_relative '../lib/trading_logic'

RSpec.describe TradingLogic::Runner do
  let(:client) { double('client') }
  let(:market_data) { double('market_data') }
  let(:instruments) { double('instruments') }

  before do
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments)
  end

  subject { described_class.new(client, tickers: %w[SBER ROSN], max_lot_rub: 1_000.0, dip_pct: 0.01) }

  def q(units, nano = 0)
    OpenStruct.new(units: units, nano: nano)
  end

  it 'converts protobuf money (units/nano) to decimal' do
    expect(subject.q_to_decimal(q(123, 500_000_000))).to eq(123.5)
  end

  describe '#trend' do
    it 'returns :up for 3 consecutive rising closes' do
      closes = [q(10), q(11), q(12), q(13)].map { |x| OpenStruct.new(close: x) }
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: closes))
      expect(subject.trend('IDX')).to eq(:up)
    end

    it 'returns :down for 3 consecutive falling closes' do
      closes = [q(20), q(19), q(18), q(17)].map { |x| OpenStruct.new(close: x) }
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: closes))
      expect(subject.trend('IDX')).to eq(:down)
    end

    it 'returns :side when not enough data' do
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: []))
      expect(subject.trend('IDX')).to eq(:side)
    end
  end

  describe 'dip_today? and should_buy?' do
    it 'detects intraday dip when cur <= today_high*(1-dip_pct)' do
      # today_high = 100, cur = 99 -> dip if dip_pct = 0.01 => 100*(1-0.01)=99 -> cur <= 99 => true
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(99))]))
      highs = [OpenStruct.new(high: q(100))]
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: highs))
      expect(subject.dip_today?('FIGI')).to be true
      expect(subject.should_buy?({ figi: 'FIGI' })).to be true
    end

    it 'returns false if no price or no highs' do
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: []))
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: []))
      expect(subject.dip_today?('FIGI')).to be false
    end
  end

  describe 'selling helpers' do
    it 'should_sell? returns true when current >= avg * 1.10' do
      position = OpenStruct.new(quantity: OpenStruct.new(units: 2), average_position_price: q(100))
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(110))]))
      it_hash = { figi: 'F' }
      expect(subject.should_sell?(position, it_hash)).to be true
    end

    it 'profit_multiple and should_force_exit? works' do
      position = OpenStruct.new(average_position_price: q(100))
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(131))]))
      expect(subject.profit_multiple(position, 'F')).to be_within(0.001).of(1.31)
      expect(subject.should_force_exit?(position, 'F')).to be true
    end
  end

  describe '#build_universe' do
    it 'builds universe entries when instrument and price present' do
      allow(instruments).to receive(:share_by_ticker).with(ticker: 'SBER', class_code: 'TQBR').and_return(
        OpenStruct.new(instrument: OpenStruct.new(figi: 'F1', lot: 1))
      )
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(300))]))
      u = subject.build_universe
      expect(u.size).to be >= 1
      expect(u.first[:ticker]).to eq('SBER')
      expect(u.first[:figi]).to eq('F1')
    end

    it 'filters out by max_lot_rub' do
      # set tiny max_lot to force filter
      runner = described_class.new(client, tickers: %w[SBER], max_lot_rub: 10.0)
      allow(instruments).to receive(:share_by_ticker).and_return(OpenStruct.new(instrument: OpenStruct.new(figi: 'F1', lot: 1)))
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(300))]))
      expect(runner.build_universe).to eq([])
    end
  end
end
