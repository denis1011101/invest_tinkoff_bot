require_relative 'spec_helper'
require_relative '../lib/strategy_helpers'

RSpec.describe TradingLogic::StrategyHelpers do
  describe '.mark_action!/.acted_today? for last_sell' do
    it 'stores ticker => {figi,ts,reason} and detects same-day action' do
      state = { 'last_sell' => {} }
      described_class.mark_action!(state, 'last_sell', 'SBER', figi: 'FIGI1', reason: 'signal', ts: '2026-01-01T10:00:00Z')

      expect(state['last_sell']['SBER']).to eq(
        'figi' => 'FIGI1',
        'ts' => '2026-01-01T10:00:00Z',
        'reason' => 'signal'
      )

      allow(described_class).to receive(:today_key).and_return('2026-01-01')
      expect(described_class.acted_today?(state, 'last_sell', 'SBER')).to be true
    end
  end

  describe '.resolve_ticker_for_sell' do
    it 'resolves ticker by figi when fallback ticker absent' do
      client = double('client')
      grpc_instruments = double('grpc_instruments')
      allow(client).to receive(:grpc_instruments).and_return(grpc_instruments)
      allow(grpc_instruments).to receive(:get_instrument_by).with(:figi, 'FIGI1').and_return(OpenStruct.new(ticker: 'sber'))

      expect(described_class.resolve_ticker_for_sell(client, figi: 'FIGI1', fallback_ticker: nil)).to eq('SBER')
    end
  end

  describe '.check_sell_consistency!' do
    it 'logs mismatch when broker sell count differs from state entries' do
      client = double('client')
      state = {
        'last_sell' => {
          'SBER' => { 'figi' => 'F1', 'ts' => '2026-01-01T10:00:00Z', 'reason' => 'signal' }
        }
      }

      allow(described_class).to receive(:today_key).and_return('2026-01-01')
      allow(described_class).to receive(:broker_sell_orders_count_for_day).and_return(2)

      expect(described_class).to receive(:warn).with(/sell consistency mismatch broker=2 state_last_sell=1/)
      described_class.check_sell_consistency!(client, 'acc', state)
    end
  end
end
