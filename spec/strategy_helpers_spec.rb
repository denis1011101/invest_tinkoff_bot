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

    logic = double('logic')
    allow(logic).to receive(:last_price_for).and_return(100.0)
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

    logic = double('logic')
    allow(logic).to receive(:last_price_for).and_return(100.0)
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
end
