# frozen_string_literal: true

require_relative 'spec_helper'
require 'invest_tinkoff'
require 'ostruct'

# Покрывает обёртку gem'а invest_tinkoff_grpc (get_instrument_by / indicatives).
# @stub подменяем на фейковый, чтобы не поднимать реальный gRPC-канал.
RSpec.describe InvestTinkoff::GRPC::InstrumentsService do
  let(:stub) { double('grpc_stub') }
  let(:channel) { double('channel', metadata: {}) }
  let(:invoker) { double('invoker', channel: channel) }

  subject(:service) do
    svc = described_class.allocate
    svc.instance_variable_set(:@invoker, invoker)
    svc.instance_variable_set(:@stub, stub)
    svc
  end

  describe '#get_instrument_by' do
    it 'maps :figi to the enum, passes the id, and returns resp.instrument' do
      inst = OpenStruct.new(ticker: 'SBER', lot: 10)
      allow(stub).to receive(:get_instrument_by) do |req, **_|
        # protobuf-enum читается как символ имени
        expect(req.id_type).to eq(:INSTRUMENT_ID_TYPE_FIGI)
        expect(req.id).to eq('BBG_SBER')
        OpenStruct.new(instrument: inst)
      end

      expect(service.get_instrument_by(:figi, 'BBG_SBER')).to eq(inst)
    end

    it 'raises ArgumentError on an unknown id_type instead of sending UNSPECIFIED' do
      expect { service.get_instrument_by(:isin, 'RU000A0') }.to raise_error(ArgumentError, /unknown id_type/)
    end

    it 'raises ArgumentError when id_type is :ticker but class_code is missing' do
      expect { service.get_instrument_by(:ticker, 'SBER') }.to raise_error(ArgumentError, /class_code/)
    end

    it 'allows :ticker when class_code is provided' do
      allow(stub).to receive(:get_instrument_by) do |req, **_|
        expect(req.id_type).to eq(:INSTRUMENT_ID_TYPE_TICKER)
        expect(req.class_code).to eq('TQBR')
        OpenStruct.new(instrument: OpenStruct.new(ticker: 'SBER'))
      end
      expect(service.get_instrument_by(:ticker, 'SBER', class_code: 'TQBR').ticker).to eq('SBER')
    end
  end

  describe '#indicatives' do
    it 'returns resp.instruments' do
      instruments = [OpenStruct.new(ticker: 'IMOEX', uid: 'U1')]
      allow(stub).to receive(:indicatives).and_return(OpenStruct.new(instruments: instruments))
      expect(service.indicatives).to eq(instruments)
    end
  end
end
