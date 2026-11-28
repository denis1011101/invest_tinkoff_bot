# frozen_string_literal: true

require_relative 'spec_helper'
require 'ostruct'
require 'json'
require 'tmpdir'
require_relative '../lib/price_monitor'

RSpec.describe TradingLogic::PriceMonitor do
  let(:client) { double('client') }
  let(:market_data) { double('market_data') }
  let(:instruments_svc) { double('instruments') }
  let(:investing_parser) { double('investing_parser') }

  before do
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments_svc)
  end

  subject(:monitor) { described_class.new(client, investing_parser: investing_parser) }

  def q(units, nano = 0)
    OpenStruct.new(units: units, nano: nano)
  end

  describe '#fetch_all' do
    around do |example|
      Dir.mktmpdir('price-monitor-test-') do |directory|
        @state_path = File.join(directory, 'state.json')
        example.run
      end
    end

    before do
      stub_const('TradingLogic::PriceMonitor::STATE_PATH', @state_path)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(TradingLogic::MarketCache::CACHE_PATH).and_raise(Errno::ENOENT)
      allow(File).to receive(:exist?).with(TradingLogic::PriceMonitor::CONFIG_PATH).and_return(true)
    end

    def saved_state
      JSON.parse(File.read(described_class::STATE_PATH))
    end

    it 'fetches static instruments from investing and dynamic instruments from Tinkoff' do
      config = {
        'telegram_header' => 'Test',
        'static_instruments' => [
          { 'label' => 'EUR/RUB', 'url' => '/currencies/eur-rub' }
        ],
        'dynamic_instruments' => [
          { 'label' => 'Сбер', 'query' => 'SBER' }
        ]
      }

      allow(File).to receive(:read).with(TradingLogic::PriceMonitor::CONFIG_PATH).and_return(JSON.generate(config))
      allow(investing_parser).to receive(:fetch_quote)
        .with('/currencies/eur-rub')
        .and_return(price: 92.45, delta: 0.45, delta_pct: 0.49)

      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'SBER')
        .and_return(
          OpenStruct.new(
            instruments: [OpenStruct.new(ticker: 'SBER', figi: 'FIGI_SBER', class_code: 'TQBR', api_trade_available_flag: true)]
          )
        )
      allow(market_data).to receive(:last_prices)
        .with(figis: ['FIGI_SBER'])
        .and_return(
          OpenStruct.new(last_prices: [
                           OpenStruct.new(figi: 'FIGI_SBER', price: q(245, 300_000_000))
                         ])
        )

      results = monitor.fetch_all

      expect(results.size).to eq(2)
      expect(results[0]).to include(label: 'EUR/RUB', group: :static, price: 92.45)
      expect(results[0][:delta_pct]).to eq(0.49)
      expect(results[1]).to include(label: 'Сбер', group: :dynamic)
      expect(results[1][:price]).to be_within(0.01).of(245.3)
    end

    it 'uses state keys per source when loading previous prices' do
      config = {
        'telegram_header' => 'Test',
        'static_instruments' => [
          { 'label' => 'EUR/RUB', 'url' => '/currencies/eur-rub' }
        ],
        'dynamic_instruments' => [
          { 'label' => 'Сбер', 'query' => 'SBER' }
        ]
      }
      prev_state = {
        'prices' => {
          'investing:/currencies/eur-rub' => 92.0,
          'tinkoff:SBER' => 240.0
        }
      }

      allow(File).to receive(:read).with(TradingLogic::PriceMonitor::CONFIG_PATH).and_return(JSON.generate(config))
      File.write(described_class::STATE_PATH, JSON.generate(prev_state))

      allow(investing_parser).to receive(:fetch_quote)
        .with('/currencies/eur-rub')
        .and_return(price: 92.45, delta: nil, delta_pct: nil)

      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'SBER')
        .and_return(
          OpenStruct.new(
            instruments: [OpenStruct.new(ticker: 'SBER', figi: 'FIGI_SBER', class_code: 'TQBR', api_trade_available_flag: true)]
          )
        )
      allow(market_data).to receive(:last_prices)
        .with(figis: ['FIGI_SBER'])
        .and_return(
          OpenStruct.new(last_prices: [
                           OpenStruct.new(figi: 'FIGI_SBER', price: q(245, 300_000_000))
                         ])
        )

      results = monitor.fetch_all

      expect(results[0][:delta]).to be_within(0.01).of(0.45)
      expect(results[0][:delta_pct]).to be_within(0.01).of(0.489)
      expect(results[1][:delta]).to be_within(0.01).of(5.3)
      expect(results[1][:delta_pct]).to be_within(0.01).of(2.208)
    end

    it 'keeps static instruments first and sorts dynamic ones by descending delta_pct' do
      config = {
        'telegram_header' => 'Test',
        'static_instruments' => [
          { 'label' => 'EUR/RUB', 'url' => '/currencies/eur-rub' }
        ],
        'dynamic_instruments' => [
          { 'label' => 'Лукойл', 'query' => 'LKOH' },
          { 'label' => 'Сбер', 'query' => 'SBER' }
        ]
      }
      prev_state = {
        'prices' => {
          'investing:/currencies/eur-rub' => 92.0,
          'tinkoff:LKOH' => 10_000.0,
          'tinkoff:SBER' => 100.0
        }
      }

      allow(File).to receive(:read).with(TradingLogic::PriceMonitor::CONFIG_PATH).and_return(JSON.generate(config))
      File.write(described_class::STATE_PATH, JSON.generate(prev_state))
      allow(investing_parser).to receive(:fetch_quote)
        .with('/currencies/eur-rub')
        .and_return(price: 92.45, delta: 0.45, delta_pct: 0.49)

      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'LKOH')
        .and_return(
          OpenStruct.new(
            instruments: [OpenStruct.new(ticker: 'LKOH', figi: 'FIGI_LKOH', class_code: 'TQBR', api_trade_available_flag: true)]
          )
        )
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'SBER')
        .and_return(
          OpenStruct.new(
            instruments: [OpenStruct.new(ticker: 'SBER', figi: 'FIGI_SBER', class_code: 'TQBR', api_trade_available_flag: true)]
          )
        )
      allow(market_data).to receive(:last_prices)
        .with(figis: %w[FIGI_LKOH FIGI_SBER])
        .and_return(
          OpenStruct.new(last_prices: [
                           OpenStruct.new(figi: 'FIGI_LKOH', price: q(10_300, 0)),
                           OpenStruct.new(figi: 'FIGI_SBER', price: q(105, 0))
                         ])
        )

      results = monitor.fetch_all

      expect(results.map { |r| r[:label] }).to eq(['EUR/RUB', 'Сбер', 'Лукойл'])
    end

    it 'supports legacy single instruments list as dynamic Tinkoff instruments' do
      legacy_config = {
        'telegram_header' => 'Test',
        'instruments' => [
          { 'label' => 'USD/RUB', 'query' => 'USD000UTSTOM' }
        ]
      }

      allow(investing_parser).to receive(:fetch_quote)
      allow(File).to receive(:read).with(TradingLogic::PriceMonitor::CONFIG_PATH).and_return(JSON.generate(legacy_config))
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'USD000UTSTOM')
        .and_return(
          OpenStruct.new(
            instruments: [OpenStruct.new(ticker: 'USD000UTSTOM', figi: 'FIGI_USD', class_code: 'CETS', api_trade_available_flag: true)]
          )
        )
      allow(market_data).to receive(:last_prices)
        .with(figis: ['FIGI_USD'])
        .and_return(
          OpenStruct.new(last_prices: [
                           OpenStruct.new(figi: 'FIGI_USD', price: q(92, 450_000_000))
                         ])
        )

      results = monitor.fetch_all

      expect(results.map { |r| r[:label] }).to eq(['USD/RUB'])
      expect(investing_parser).not_to have_received(:fetch_quote)
    end

    it 'renders compact current quotes, older timestamps, numeric US closes and source failures' do
      legacy_instruments = [
        ['USD/RUB', 'https://ru.investing.com/currencies/usd-rub'],
        ['IMOEX', '/indices/mcx'],
        ['Нефть Brent', '/commodities/brent-oil'],
        ['Золото $', '/commodities/gold'],
        ['S&P 500', '/indices/us-spx-500'],
        ['Dow Jones', '/indices/us-30'],
        ['Никель', '/commodities/nickel'],
        ['Палладий', '/commodities/palladium'],
        ['Платина', '/commodities/platinum']
      ].map { |label, url| { 'label' => label, 'url' => url } }
      config = { 'static_instruments' => legacy_instruments }
      previous = { 'prices' => { 'moex_future:BRZ6' => 95.0, 'investing:/commodities/brent-oil' => 87.0 } }
      allow(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate(config))
      File.write(described_class::STATE_PATH, JSON.generate(previous))
      public_quotes = instance_double(TradingLogic::PublicMarketQuotes)
      monitor = described_class.new(client, investing_parser: investing_parser, public_quotes: public_quotes)
      as_of = Time.iso8601('2026-11-27T19:30:09+03:00')
      allow(monitor).to receive(:yek_now).and_return(Time.iso8601('2026-11-28T16:00:00+05:00'))
      allow(public_quotes).to receive(:fetch).with(:cbr, 'USD').and_return(price: 80.6273, as_of: Date.new(2026, 11, 28))
      allow(public_quotes).to receive(:fetch).with(:moex_index, 'IMOEX2').and_return(price: 2364.5, as_of: as_of)
      allow(public_quotes).to receive(:fetch).with(:moex_future, 'BR').and_return(
        price: 91.0, as_of: Time.iso8601('2026-11-27T23:49:00+03:00'), contract: 'BR-1.27', state_symbol: 'BRF7'
      )
      allow(public_quotes).to receive(:fetch).with(:moex_future, 'NICKEL').and_raise(TradingLogic::PublicMarketQuotes::Unavailable)
      allow(public_quotes).to receive(:fetch).with(:fred, 'SP500').and_return(
        price: 7050.0, as_of: Date.new(2026, 11, 27), delta: 15.0, delta_pct: 0.21
      )
      allow(public_quotes).to receive(:fetch).with(:fred, 'DJIA').and_return(
        price: 49_900.0, as_of: Date.new(2026, 11, 27), delta: -100.0, delta_pct: -0.2
      )
      %w[XAU XPD XPT].each do |symbol|
        allow(public_quotes).to receive(:fetch).with(:gold_api, symbol).and_return(price: 1234.0, as_of: as_of)
      end

      results = monitor.fetch_all
      message = monitor.send(:format_monitor_message, 'Котировки', results)

      expect(results.length).to eq(9)
      expect(results[2]).to include(price: 91.0, prev_price: nil, delta: nil, state_key: 'moex_future:BR', state_symbol: 'BRF7')
      expect(message).to include(
        '`USD/RUB ЦБ` 80\.63 — · на 28\.11',
        '`IMOEX2` 2364\.5 — · 27\.11 21:30',
        '`Brent фьюч. 1.27` 91\.0 — · 01:49',
        '`Никель фьюч.` — данные недоступны',
        '`S&P 500 закр.` 7050\.0 ↗ \+15\.0 \(\+0\.21%\) · на 27\.11',
        '`Dow Jones закр.` 49900\.0 ↘ \-100\.0 \(\-0\.2%\) · на 27\.11'
      )
      saved = JSON.parse(File.read(described_class::STATE_PATH))
      expect(saved.fetch('prices')).to include('moex_future:BR' => 91.0, 'fred:SP500' => 7050.0, 'fred:DJIA' => 49_900.0)
      expect(saved.fetch('future_contracts')).to eq('moex_future:BR' => 'BRF7')
    end

    it 'uses exact TQBR cache hits and keeps broker lookup for missing, ambiguous or non-TQBR tickers' do
      config = { 'dynamic_instruments' => %w[sber GAZP LKOH].map { |ticker| { 'query' => ticker } } }
      instruments_cache = {
        'updated_at' => Time.now.utc.iso8601,
        'instruments' => [
          { 'ticker' => 'SBER', 'figi' => 'SBER_MAIN', 'class_code' => 'TQBR' },
          { 'ticker' => 'SBER', 'figi' => 'SBER_OTHER', 'class_code' => 'OTHER' },
          { 'ticker' => 'GAZP', 'figi' => 'GAZP_OTHER', 'class_code' => 'OTHER' },
          { 'ticker' => 'LKOH', 'figi' => 'LKOH_FIRST', 'class_code' => 'TQBR' },
          { 'ticker' => 'LKOH', 'figi' => 'LKOH_SECOND', 'class_code' => 'TQBR' }
        ]
      }
      allow(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate(config))
      allow(File).to receive(:read).with(TradingLogic::MarketCache::CACHE_PATH).and_return(JSON.generate(instruments_cache))
      %w[GAZP LKOH].each do |ticker|
        expect(instruments_svc).to receive(:find_instrument).with(query: ticker).and_return(
          OpenStruct.new(instruments: [OpenStruct.new(ticker: ticker, figi: "#{ticker}_LOOKUP", class_code: 'TQBR')])
        )
      end
      expect(market_data).to receive(:last_prices).with(figis: %w[SBER_MAIN GAZP_LOOKUP LKOH_LOOKUP]).and_return(
        OpenStruct.new(last_prices: %w[SBER_MAIN GAZP_LOOKUP LKOH_LOOKUP].map { |figi| OpenStruct.new(figi: figi, price: q(100)) })
      )

      expect(monitor.fetch_all.map { |result| result[:query] }).to eq(%w[sber GAZP LKOH])
    end

    it 'retains last successful prices of configured instruments through a failed run' do
      config = {
        'static_instruments' => [{ 'label' => 'Gold', 'url' => '/commodities/gold' }],
        'dynamic_instruments' => [{ 'query' => 'SBER' }]
      }
      previous = { 'prices' => { 'gold_api:XAU' => 4000.0, 'tinkoff:SBER' => 100.0, 'tinkoff:REMOVED' => 99.0 } }
      File.write(described_class::STATE_PATH, JSON.generate(previous))
      allow(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate(config))
      public_quotes = instance_double(TradingLogic::PublicMarketQuotes)
      monitor = described_class.new(client, public_quotes: public_quotes)
      config_ticker = OpenStruct.new(ticker: 'SBER', figi: 'FIGI_SBER', class_code: 'TQBR')
      allow(instruments_svc).to receive(:find_instrument).with(query: 'SBER').and_return(OpenStruct.new(instruments: [config_ticker]))
      allow(public_quotes).to receive(:fetch).with(:gold_api, 'XAU').and_raise(TradingLogic::PublicMarketQuotes::Unavailable)
      allow(market_data).to receive(:last_prices).with(figis: ['FIGI_SBER']).and_raise(StandardError, 'broker unavailable')

      expect(monitor.fetch_all).to contain_exactly(hash_including(unavailable: true, label: 'Gold'))
      expect(saved_state.fetch('prices')).to eq('gold_api:XAU' => 4000.0, 'tinkoff:SBER' => 100.0)

      allow(public_quotes).to receive(:fetch).with(:gold_api, 'XAU').and_return(price: 4020.0)
      allow(market_data).to receive(:last_prices).with(figis: ['FIGI_SBER']).and_return(
        OpenStruct.new(last_prices: [OpenStruct.new(figi: 'FIGI_SBER', price: q(104))])
      )

      expect(monitor.fetch_all.map { |result| result.values_at(:label, :delta) }).to eq([['Gold', 20.0], ['SBER', 4.0]])
    end

    it 'formats upward, downward and unchanged spot metal prices in the upper block' do
      metals = [
        ['Золото', 'gold', 'XAU', 4000.0, 4020.0],
        ['Палладий', 'palladium', 'XPD', 1000.0, 990.0],
        ['Платина', 'platinum', 'XPT', 1200.0, 1200.0]
      ]
      instruments = metals.map { |label, url, *| { 'label' => label, 'url' => "/commodities/#{url}" } }
      allow(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate('static_instruments' => instruments))
      public_quotes = instance_double(TradingLogic::PublicMarketQuotes)
      monitor = described_class.new(client, public_quotes: public_quotes)
      first_time = Time.iso8601('2026-11-27T12:00:00+05:00')
      allow(monitor).to receive(:yek_now).and_return(first_time)
      metals.each do |_, _, symbol, first_price, next_price|
        allow(public_quotes).to receive(:fetch).with(:gold_api, symbol).and_return(
          { price: first_price, as_of: first_time },
          { price: next_price, as_of: first_time + 3600 }
        )
      end

      first = monitor.send(:format_monitor_message, 'Котировки', monitor.fetch_all)
      second = monitor.send(:format_monitor_message, 'Котировки', monitor.fetch_all)

      expect(first).to include('`Золото` 4000\.0 — · 12:00')
      expect(second).to include(
        '`Золото` 4020\.0 ↗ \+20\.0 \(\+0\.5%\)',
        '`Палладий` 990\.0 ↘ \-10\.0 \(\-1\.0%\)',
        '`Платина` 1200\.0 — 0\.0 \(0\.0%\)'
      )
    end

    it 'uses a previous futures price only from the same contract, including legacy state' do
      config = { 'static_instruments' => [{ 'label' => 'Brent', 'url' => '/commodities/brent-oil' }] }
      File.write(described_class::STATE_PATH, JSON.generate('prices' => { 'moex_future:BRZ6' => 95.0 }))
      allow(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate(config))
      public_quotes = instance_double(TradingLogic::PublicMarketQuotes)
      monitor = described_class.new(client, public_quotes: public_quotes)
      allow(public_quotes).to receive(:fetch).with(:moex_future, 'BR').and_raise(TradingLogic::PublicMarketQuotes::Unavailable)

      monitor.fetch_all
      expect(saved_state.fetch('prices')).to eq('moex_future:BRZ6' => 95.0)

      allow(public_quotes).to receive(:fetch).with(:moex_future, 'BR').and_return(
        { price: 96.0, state_symbol: 'BRZ6' },
        { price: 90.0, state_symbol: 'BRF7' }
      )

      expect(monitor.fetch_all.first[:delta]).to eq(1.0)
      expect(saved_state.fetch('prices')).to eq('moex_future:BR' => 96.0)
      expect(monitor.fetch_all.first[:delta]).to be_nil
      expect(saved_state.fetch('future_contracts')).to eq('moex_future:BR' => 'BRF7')
    end

    it 'skips static instruments without url and dynamic instruments not found via find_instrument' do
      config = {
        'telegram_header' => 'Test',
        'static_instruments' => [
          { 'label' => 'Broken static' }
        ],
        'dynamic_instruments' => [
          { 'label' => 'Unknown', 'query' => 'NOPE' }
        ]
      }

      allow(File).to receive(:read).with(TradingLogic::PriceMonitor::CONFIG_PATH).and_return(JSON.generate(config))
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'NOPE')
        .and_return(OpenStruct.new(instruments: []))

      expect(monitor.fetch_all).to eq([])
    end
  end

  describe '#format_monitor_message' do
    it 'formats results with delta arrows' do
      results = [
        {
          label: 'USD/RUB', query: '/currencies/usd-rub', price: 92.45,
          prev_price: 92.0, delta: 0.45, delta_pct: 0.489,
          state_key: 'investing:/currencies/usd-rub'
        },
        { label: 'SBER', query: 'SBER', price: 245.3, prev_price: 250.0, delta: -4.7, delta_pct: -1.88, state_key: 'tinkoff:SBER' }
      ]
      msg = monitor.send(:format_monitor_message, 'Котировки', results)

      expect(msg).to include('*Котировки*')
      expect(msg).to include('`USD/RUB`')
      expect(msg).to include('92\.45')
      expect(msg).to include('↗')
      expect(msg).to include('`SBER`')
      expect(msg).to include('↘')
    end

    it 'shows no delta on first run' do
      results = [
        { label: 'SBER', query: 'SBER', price: 245.3, prev_price: nil, delta: nil, delta_pct: nil, state_key: 'tinkoff:SBER' }
      ]
      msg = monitor.send(:format_monitor_message, 'Test', results)

      expect(msg).to include('`SBER`')
      expect(msg).to include('245\.3')
      expect(msg).not_to include('↗')
      expect(msg).not_to include('↘')
    end

    it 'shows no-data message when results are empty' do
      msg = monitor.send(:format_monitor_message, 'Test', [])
      expect(msg).to include('Нет данных')
    end

    it 'includes Yekaterinburg time' do
      results = [{ label: 'X', query: 'X', price: 1.0, prev_price: nil, delta: nil, delta_pct: nil, state_key: 'tinkoff:X' }]
      msg = monitor.send(:format_monitor_message, 'Test', results)
      expect(msg).to include('Екб')
    end
  end

  describe '#resolve_figi' do
    def instrument(ticker:, figi:, class_code: '', api_trade_available_flag: true)
      OpenStruct.new(ticker: ticker, figi: figi, class_code: class_code,
                     instrument_type: 'share', api_trade_available_flag: api_trade_available_flag)
    end

    it 'prefers TQBR share with matching ticker' do
      instruments = [
        instrument(ticker: 'GAZP', figi: 'WRONG', class_code: 'SPBX'),
        instrument(ticker: 'GAZP', figi: 'CORRECT', class_code: 'TQBR'),
        instrument(ticker: 'GAZP', figi: 'ALSO_WRONG', class_code: 'TQOB')
      ]
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'GAZP')
        .and_return(OpenStruct.new(instruments: instruments))

      expect(monitor.send(:resolve_figi, 'GAZP')).to eq('CORRECT')
    end

    it 'is case-insensitive for query' do
      instruments = [
        instrument(ticker: 'SBER', figi: 'FIGI_SBER', class_code: 'TQBR')
      ]
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'sber')
        .and_return(OpenStruct.new(instruments: instruments))

      expect(monitor.send(:resolve_figi, 'sber')).to eq('FIGI_SBER')
    end

    it 'handles nil ticker in instrument list' do
      instruments = [
        OpenStruct.new(ticker: nil, figi: 'NIL_TICKER', class_code: 'TQBR', instrument_type: 'bond', api_trade_available_flag: false),
        instrument(ticker: 'SBER', figi: 'GOOD', class_code: 'TQBR')
      ]
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'SBER')
        .and_return(OpenStruct.new(instruments: instruments))

      expect(monitor.send(:resolve_figi, 'SBER')).to eq('GOOD')
    end

    it 'falls back to api_trade_available when no TQBR match' do
      instruments = [
        instrument(ticker: 'X', figi: 'NOT_TRADABLE', api_trade_available_flag: false),
        instrument(ticker: 'BTC/USD', figi: 'TRADABLE', class_code: 'CETS', api_trade_available_flag: true)
      ]
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'BTC/USD')
        .and_return(OpenStruct.new(instruments: instruments))

      expect(monitor.send(:resolve_figi, 'BTC/USD')).to eq('TRADABLE')
    end

    it 'falls back to first instrument when none are tradable' do
      instruments = [
        instrument(ticker: 'X', figi: 'FIRST', api_trade_available_flag: false),
        instrument(ticker: 'Y', figi: 'SECOND', api_trade_available_flag: false)
      ]
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'UNKNOWN')
        .and_return(OpenStruct.new(instruments: instruments))

      expect(monitor.send(:resolve_figi, 'UNKNOWN')).to eq('FIRST')
    end

    it 'returns nil for empty results' do
      allow(instruments_svc).to receive(:find_instrument)
        .with(query: 'NOPE')
        .and_return(OpenStruct.new(instruments: []))

      expect(monitor.send(:resolve_figi, 'NOPE')).to be_nil
    end
  end

  describe 'TelegramHelper integration' do
    it 'has escape_md method from TelegramHelper' do
      expect(monitor.send(:escape_md, 'test_value')).to eq('test\_value')
    end

    it 'has send_telegram method from TelegramHelper' do
      expect(monitor).to respond_to(:send_telegram)
    end
  end
end
