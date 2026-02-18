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

  describe '.position_within_limit?' do
    def make_portfolio(total_shares:, positions: [])
      OpenStruct.new(total_amount_shares: q(total_shares), positions: positions)
    end

    def make_position(figi:, qty:, avg_price:, current_price: nil)
      pos = OpenStruct.new(
        figi: figi,
        quantity: OpenStruct.new(units: qty),
        average_position_price: q(avg_price)
      )
      if current_price
        allow(pos).to receive(:respond_to?).and_call_original
        allow(pos).to receive(:respond_to?).with(:current_price).and_return(true)
        allow(pos).to receive(:current_price).and_return(q(current_price))
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
  end
end
