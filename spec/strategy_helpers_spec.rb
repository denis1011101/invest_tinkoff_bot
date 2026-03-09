# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/strategy_helpers'
require 'tempfile'
require 'json'
require 'ostruct'

RSpec.describe TradingLogic::StrategyHelpers do
  def q(units, nano = 0)
    OpenStruct.new(units: units, nano: nano)
  end

  def write_cache(rows)
    f = Tempfile.new(['cache', '.json'])
    f.write(JSON.generate({ 'instruments' => rows }))
    f.flush
    f
  end

  def rising_daily_candles
    [
      OpenStruct.new(close: q(10)),
      OpenStruct.new(close: q(11)),
      OpenStruct.new(close: q(12)),
      OpenStruct.new(close: q(13))
    ]
  end

  def flat_daily_candles
    [
      OpenStruct.new(close: q(10)),
      OpenStruct.new(close: q(11)),
      OpenStruct.new(close: q(11)),
      OpenStruct.new(close: q(10))
    ]
  end

  def build_buy_flow_client(market_candles:)
    client = double('client')
    market_data = double('market_data')
    operations = double('operations')
    instruments = double('instruments')

    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_operations).and_return(operations)
    allow(client).to receive(:grpc_instruments).and_return(instruments)
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: market_candles))
    allow(operations).to receive(:portfolio).and_return(
      OpenStruct.new(total_amount_shares: q(10_000), positions: [])
    )

    [client, market_data, operations, instruments]
  end

  it 'stops after first accepted BUY when category is sent_not_filled' do
    market_cache = write_cache(
      [
        { 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 },
        { 'ticker' => 'BBB', 'figi' => 'F_BBB', 'lot' => 1 }
      ]
    )
    index_cache = write_cache(
      [
        { 'ticker' => 'AAA' },
        { 'ticker' => 'BBB' }
      ]
    )

    client = double('client')
    market_data = double('market_data')
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: rising_daily_candles))

    operations = double('operations')
    allow(client).to receive(:grpc_operations).and_return(operations)
    allow(operations).to receive(:portfolio).and_return(
      OpenStruct.new(total_amount_shares: q(10_000), positions: [])
    )

    logic = double('logic')
    allow(logic).to receive(:last_price_for).and_return(100.0)
    allow(logic).to receive(:dip_today?).and_return(true)
    expect(logic).to receive(:confirm_and_place_order_with_result).once.and_return(
      {
        ok: false,
        category: :sent_not_filled,
        response: OpenStruct.new(order_id: 'order-1'),
        client_order_id: 'client-1'
      }
    )

    state = { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {} }
    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      state,
      market_cache_path: market_cache.path,
      moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0,
      lots_per_order: 1,
      account_id: 'acc'
    )

    expect(result).to be true
    expect(state.fetch('pending_orders').fetch('AAA').fetch('status')).to eq('sent_not_filled')
    expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d')).fetch('AAA')).to be true
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'stops after first accepted BUY when category is partially_filled' do
    market_cache = write_cache(
      [
        { 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 },
        { 'ticker' => 'BBB', 'figi' => 'F_BBB', 'lot' => 1 }
      ]
    )
    index_cache = write_cache(
      [
        { 'ticker' => 'AAA' },
        { 'ticker' => 'BBB' }
      ]
    )

    client = double('client')
    market_data = double('market_data')
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: rising_daily_candles))

    operations = double('operations')
    allow(client).to receive(:grpc_operations).and_return(operations)
    allow(operations).to receive(:portfolio).and_return(
      OpenStruct.new(total_amount_shares: q(10_000), positions: [])
    )

    logic = double('logic')
    allow(logic).to receive(:last_price_for).and_return(100.0)
    allow(logic).to receive(:dip_today?).and_return(true)
    expect(logic).to receive(:confirm_and_place_order_with_result).once.and_return(
      {
        ok: false,
        category: :partially_filled,
        response: OpenStruct.new(order_id: 'order-2'),
        client_order_id: 'client-2'
      }
    )

    state = { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {} }
    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      state,
      market_cache_path: market_cache.path,
      moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0,
      lots_per_order: 1,
      account_id: 'acc'
    )

    expect(result).to be true
    expect(state.fetch('pending_orders').fetch('AAA').fetch('status')).to eq('partially_filled')
    expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d')).fetch('AAA')).to be true
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'resolves figi through instruments service when cache entry has no figi' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])

    client = double('client')
    market_data = double('market_data')
    instruments = double('instruments')
    operations = double('operations')

    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments)
    allow(client).to receive(:grpc_operations).and_return(operations)
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: rising_daily_candles))
    allow(instruments).to receive(:find_instrument)
      .with(query: 'AAA')
      .and_return(OpenStruct.new(instruments: [OpenStruct.new(figi: 'F_AAA')]))
    allow(operations).to receive(:portfolio).and_return(
      OpenStruct.new(total_amount_shares: q(10_000), positions: [])
    )

    logic = double('logic')
    allow(logic).to receive(:last_price_for).with('F_AAA').and_return(100.0)
    allow(logic).to receive(:dip_today?).with('F_AAA').and_return(true)
    allow(logic).to receive(:respond_to?).with(:near_support?).and_return(false)
    allow(logic).to receive(:confirm_and_place_order_with_result).and_return(
      { ok: true, category: :filled, response: OpenStruct.new(order_id: 'order-3'), client_order_id: 'client-3' }
    )

    state = { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {} }

    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      state,
      market_cache_path: market_cache.path,
      moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0,
      lots_per_order: 1,
      account_id: 'acc'
    )

    expect(result).to be true
    expect(logic).to have_received(:last_price_for).with('F_AAA')
    expect(logic).to have_received(:dip_today?).with('F_AAA')
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'skips candidate when pending buy cooldown is still active' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])
    client, = build_buy_flow_client(market_candles: rising_daily_candles)

    logic = double('logic')
    allow(logic).to receive(:last_price_for).with('F_AAA').and_return(100.0)
    allow(logic).to receive(:dip_today?).with('F_AAA').and_return(true)
    allow(logic).to receive(:respond_to?).with(:near_support?).and_return(false)
    expect(logic).not_to receive(:confirm_and_place_order_with_result)

    state = {
      'last_buy' => {},
      'last_sell' => {},
      'pending_orders' => {
        'AAA' => {
          'status' => 'sent_not_filled',
          'ts' => Time.now.utc.iso8601
        }
      }
    }

    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      state,
      market_cache_path: market_cache.path,
      moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0,
      lots_per_order: 1,
      account_id: 'acc'
    )

    expect(result).to be false
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'skips candidate when daily candles do not confirm momentum' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])
    client, = build_buy_flow_client(market_candles: flat_daily_candles)

    logic = double('logic')
    expect(logic).not_to receive(:last_price_for)
    expect(logic).not_to receive(:confirm_and_place_order_with_result)

    state = { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {} }

    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      state,
      market_cache_path: market_cache.path,
      moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0,
      lots_per_order: 1,
      account_id: 'acc'
    )

    expect(result).to be false
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'prioritizes candidate closer to support before placing order' do
    market_cache = write_cache(
      [
        { 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 },
        { 'ticker' => 'BBB', 'figi' => 'F_BBB', 'lot' => 1 }
      ]
    )
    index_cache = write_cache(
      [
        { 'ticker' => 'AAA' },
        { 'ticker' => 'BBB' }
      ]
    )
    client, = build_buy_flow_client(market_candles: rising_daily_candles)

    logic = double('logic')
    allow(logic).to receive(:last_price_for).with('F_AAA').and_return(100.0)
    allow(logic).to receive(:last_price_for).with('F_BBB').and_return(100.0)
    allow(logic).to receive(:dip_today?).with('F_AAA').and_return(true)
    allow(logic).to receive(:dip_today?).with('F_BBB').and_return(true)
    allow(logic).to receive(:respond_to?).with(:near_support?).and_return(true)
    allow(logic).to receive(:nearest_support).with('F_AAA', 100.0).and_return({ price: 95.0 })
    allow(logic).to receive(:nearest_support).with('F_BBB', 100.0).and_return({ price: 99.0 })
    expect(logic).to receive(:confirm_and_place_order_with_result).with(
      hash_including(figi: 'F_BBB')
    ).once.and_return(
      { ok: true, category: :filled, response: OpenStruct.new(order_id: 'order-4'), client_order_id: 'client-4' }
    )

    state = { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {} }

    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      state,
      market_cache_path: market_cache.path,
      moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0,
      lots_per_order: 1,
      account_id: 'acc'
    )

    expect(result).to be true
    expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d')).fetch('BBB')).to be true
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'skips candidate when figi resolution raises an error' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])
    client, _market_data, _operations, instruments = build_buy_flow_client(market_candles: rising_daily_candles)

    allow(instruments).to receive(:find_instrument).with(query: 'AAA').and_raise(StandardError, 'lookup failed')

    logic = double('logic')
    expect(logic).not_to receive(:last_price_for)
    expect(logic).not_to receive(:confirm_and_place_order_with_result)

    state = { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {} }

    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      state,
      market_cache_path: market_cache.path,
      moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0,
      lots_per_order: 1,
      account_id: 'acc'
    )

    expect(result).to be false
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'skips candidate when candles request raises an error' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])
    client, market_data = build_buy_flow_client(market_candles: rising_daily_candles)
    allow(market_data).to receive(:candles).and_raise(StandardError, 'candles failed')

    logic = double('logic')
    expect(logic).not_to receive(:last_price_for)
    expect(logic).not_to receive(:confirm_and_place_order_with_result)

    state = { 'last_buy' => {}, 'last_sell' => {}, 'pending_orders' => {} }

    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      state,
      market_cache_path: market_cache.path,
      moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0,
      lots_per_order: 1,
      account_id: 'acc'
    )

    expect(result).to be false
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  describe '.position_within_limit?' do
    def make_portfolio(total_shares:, positions: [])
      OpenStruct.new(total_amount_shares: q(total_shares), positions: positions)
    end

    def make_position(figi:, qty:, avg_price:, current_price: nil)
      attrs = {
        figi: figi,
        quantity: OpenStruct.new(units: qty),
        average_position_price: q(avg_price)
      }
      attrs[:current_price] = q(current_price) if current_price
      pos = OpenStruct.new(**attrs)
      if current_price
        allow(pos).to receive(:respond_to?).and_call_original
        allow(pos).to receive(:respond_to?).with(:current_price).and_return(true)
      end
      pos
    end

    it 'returns true when no existing position' do
      port = make_portfolio(total_shares: 10_000)
      result = described_class.position_within_limit?(
        nil, nil, 'F_NEW', portfolio: port, planned_buy_value: 100
      )
      expect(result).to be true
    end

    it 'returns false when post-trade share exceeds limit' do
      pos = make_position(figi: 'F1', qty: 30, avg_price: 100)
      port = make_portfolio(total_shares: 10_000, positions: [pos])
      # current position = 30*100 = 3000, planned = 1000
      # post_trade = 4000 / 11000 = 36.4% > 33%
      result = described_class.position_within_limit?(
        nil, nil, 'F1', portfolio: port, planned_buy_value: 1000, max_share: 0.33
      )
      expect(result).to be false
    end

    it 'returns true when post-trade share is within limit' do
      pos = make_position(figi: 'F1', qty: 10, avg_price: 100)
      port = make_portfolio(total_shares: 10_000, positions: [pos])
      # current position = 10*100 = 1000, planned = 200
      # post_trade = 1200 / 10200 = 11.8% < 33%
      result = described_class.position_within_limit?(
        nil, nil, 'F1', portfolio: port, planned_buy_value: 200, max_share: 0.33
      )
      expect(result).to be true
    end

    it 'accounts for planned buy in share calculation' do
      pos = make_position(figi: 'F1', qty: 30, avg_price: 100)
      port = make_portfolio(total_shares: 10_000, positions: [pos])
      # Without planned buy: 3000/10000 = 30% < 33% => would pass
      expect(described_class.position_within_limit?(
               nil, nil, 'F1', portfolio: port, planned_buy_value: 0, max_share: 0.33
             )).to be true
      # With planned buy of 500: (3000+500)/(10000+500) = 33.3% >= 33% => should fail
      expect(described_class.position_within_limit?(
               nil, nil, 'F1', portfolio: port, planned_buy_value: 500, max_share: 0.33
             )).to be false
    end

    it 'uses current_price when available for existing position valuation' do
      pos = make_position(figi: 'F1', qty: 10, avg_price: 100, current_price: 200)
      port = make_portfolio(total_shares: 10_000, positions: [pos])

      result = described_class.position_within_limit?(
        nil, nil, 'F1', portfolio: port, planned_buy_value: 2_500, max_share: 0.33
      )

      expect(result).to be false
    end

    it 'returns true when max_share is disabled by zero' do
      pos = make_position(figi: 'F1', qty: 100, avg_price: 100)
      port = make_portfolio(total_shares: 10_000, positions: [pos])

      result = described_class.position_within_limit?(
        nil, nil, 'F1', portfolio: port, planned_buy_value: 10_000, max_share: 0
      )

      expect(result).to be true
    end

    it 'returns true when portfolio total is non-positive' do
      pos = make_position(figi: 'F1', qty: 10, avg_price: 100)
      port = make_portfolio(total_shares: 0, positions: [pos])

      result = described_class.position_within_limit?(
        nil, nil, 'F1', portfolio: port, planned_buy_value: 1_000, max_share: 0.33
      )

      expect(result).to be true
    end
  end
end
