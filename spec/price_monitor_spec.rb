require_relative 'spec_helper'
require 'ostruct'
require 'tmpdir'
require 'json'
require 'fileutils'
require_relative '../lib/price_monitor'

RSpec.describe TradingLogic::PriceMonitor do
  let(:client) { double('client') }
  let(:market_data) { double('market_data') }
  let(:instruments_svc) { double('instruments') }

  before do
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments_svc)
  end

  subject { described_class.new(client) }

  def q(units, nano = 0)
    OpenStruct.new(units: units, nano: nano)
  end

  describe '#fetch_all' do
    let(:config) do
      {
        'telegram_header' => 'Test',
        'instruments' => [
          { 'label' => 'USD/RUB', 'query' => 'USD000UTSTOM' },
          { 'label' => 'Сбер', 'query' => 'SBER' }
        ]
      }
    end

    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(TradingLogic::PriceMonitor::CONFIG_PATH).and_return(true)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(TradingLogic::PriceMonitor::CONFIG_PATH).and_return(JSON.generate(config))

      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'USD000UTSTOM')
        .and_return(OpenStruct.new(instruments: [OpenStruct.new(figi: 'FIGI_USD')]))
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'SBER')
        .and_return(OpenStruct.new(instruments: [OpenStruct.new(figi: 'FIGI_SBER')]))

      allow(market_data).to receive(:last_prices)
        .with(figis: %w[FIGI_USD FIGI_SBER])
        .and_return(OpenStruct.new(last_prices: [
          OpenStruct.new(figi: 'FIGI_USD', price: q(92, 450_000_000)),
          OpenStruct.new(figi: 'FIGI_SBER', price: q(245, 300_000_000))
        ]))
    end

    it 'fetches prices for all instruments' do
      allow(File).to receive(:exist?).with(TradingLogic::PriceMonitor::STATE_PATH).and_return(false)
      allow(File).to receive(:write).and_return(nil)
      allow(FileUtils).to receive(:mkdir_p)

      results = subject.fetch_all

      expect(results.size).to eq(2)
      expect(results[0][:label]).to eq('USD/RUB')
      expect(results[0][:price]).to be_within(0.01).of(92.45)
      expect(results[1][:label]).to eq('Сбер')
      expect(results[1][:price]).to be_within(0.01).of(245.3)
    end

    it 'calculates delta from previous prices' do
      prev_state = { 'prices' => { 'USD000UTSTOM' => 92.0, 'SBER' => 240.0 } }
      allow(File).to receive(:exist?).with(TradingLogic::PriceMonitor::STATE_PATH).and_return(true)
      allow(File).to receive(:read).with(TradingLogic::PriceMonitor::STATE_PATH).and_return(JSON.generate(prev_state))
      allow(File).to receive(:write).and_return(nil)
      allow(FileUtils).to receive(:mkdir_p)

      results = subject.fetch_all

      expect(results[0][:delta]).to be_within(0.01).of(0.45)
      expect(results[0][:delta_pct]).to be_within(0.01).of(0.489)
      expect(results[1][:delta]).to be_within(0.01).of(5.3)
    end

    it 'returns nil delta on first run (no previous state)' do
      allow(File).to receive(:exist?).with(TradingLogic::PriceMonitor::STATE_PATH).and_return(false)
      allow(File).to receive(:write).and_return(nil)
      allow(FileUtils).to receive(:mkdir_p)

      results = subject.fetch_all

      expect(results[0][:delta]).to be_nil
      expect(results[0][:delta_pct]).to be_nil
    end

    it 'skips instruments not found via find_instrument' do
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'USD000UTSTOM')
        .and_return(OpenStruct.new(instruments: []))

      allow(market_data).to receive(:last_prices)
        .with(figis: %w[FIGI_SBER])
        .and_return(OpenStruct.new(last_prices: [
          OpenStruct.new(figi: 'FIGI_SBER', price: q(245, 300_000_000))
        ]))

      allow(File).to receive(:exist?).with(TradingLogic::PriceMonitor::STATE_PATH).and_return(false)
      allow(File).to receive(:write).and_return(nil)
      allow(FileUtils).to receive(:mkdir_p)

      results = subject.fetch_all
      expect(results.size).to eq(1)
      expect(results[0][:label]).to eq('Сбер')
    end
  end

  describe '#format_monitor_message' do
    it 'formats results with delta arrows' do
      results = [
        { label: 'USD/RUB', query: 'USD', price: 92.45, prev_price: 92.0, delta: 0.45, delta_pct: 0.489 },
        { label: 'SBER', query: 'SBER', price: 245.3, prev_price: 250.0, delta: -4.7, delta_pct: -1.88 }
      ]
      msg = subject.send(:format_monitor_message, 'Котировки', results)

      expect(msg).to include('*Котировки*')
      expect(msg).to include('`USD/RUB`')
      expect(msg).to include('92\.45')
      expect(msg).to include('↗')
      expect(msg).to include('`SBER`')
      expect(msg).to include('↘')
    end

    it 'shows no delta on first run' do
      results = [
        { label: 'SBER', query: 'SBER', price: 245.3, prev_price: nil, delta: nil, delta_pct: nil }
      ]
      msg = subject.send(:format_monitor_message, 'Test', results)

      expect(msg).to include('`SBER`')
      expect(msg).to include('245\.3')
      expect(msg).not_to include('↗')
      expect(msg).not_to include('↘')
    end

    it 'shows no-data message when results are empty' do
      msg = subject.send(:format_monitor_message, 'Test', [])
      expect(msg).to include('Нет данных')
    end

    it 'includes Yekaterinburg time' do
      results = [{ label: 'X', query: 'X', price: 1.0, prev_price: nil, delta: nil, delta_pct: nil }]
      msg = subject.send(:format_monitor_message, 'Test', results)
      expect(msg).to include('Екб')
    end
  end

  describe 'TelegramHelper integration' do
    it 'has escape_md method from TelegramHelper' do
      expect(subject.send(:escape_md, 'test_value')).to eq('test\_value')
    end

    it 'has send_telegram method from TelegramHelper' do
      expect(subject).to respond_to(:send_telegram)
    end
  end
end
