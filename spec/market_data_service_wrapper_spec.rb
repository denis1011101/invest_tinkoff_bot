# frozen_string_literal: true

require_relative 'spec_helper'
require 'invest_tinkoff'

RSpec.describe InvestTinkoff::GRPC::MarketDataService do
  let(:stub) { double('grpc_stub') }
  let(:grpc_channel) { double('grpc_channel') }
  let(:channel) { double('channel', metadata: {}, channel: grpc_channel) }
  let(:invoker) { double('invoker', channel: channel) }

  subject(:service) do
    svc = described_class.allocate
    svc.instance_variable_set(:@invoker, invoker)
    svc.instance_variable_set(:@stub, stub)
    svc
  end

  describe '#candles' do
    it 'sends uid via instrument_id and leaves figi unset' do
      from = Time.utc(2026, 7, 1)
      to = Time.utc(2026, 7, 2)

      allow(stub).to receive(:get_candles) do |req, **_|
        expect(req.instrument_id).to eq('IMOEX_UID')
        expect(req.respond_to?(:has_instrument_id?) ? req.has_instrument_id? : !req.instrument_id.to_s.empty?).to be true
        expect(req.respond_to?(:has_figi?) ? req.has_figi? : !req.figi.to_s.empty?).to be false
        expect(req.figi.to_s).to eq('')
        expect(req.interval).to eq(:CANDLE_INTERVAL_DAY)
        OpenStruct.new(candles: [])
      end

      service.candles(from: from, to: to, interval: :CANDLE_INTERVAL_DAY, instrument_id: 'IMOEX_UID')
    end
  end
end
