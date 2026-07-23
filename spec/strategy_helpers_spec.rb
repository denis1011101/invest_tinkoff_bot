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
    # updated_at свежий — иначе срабатывает защита от протухших кешей.
    f.write(JSON.generate({ 'updated_at' => Time.now.utc.iso8601, 'instruments' => rows }))
    f.flush
    f
  end

  # Торгуемая рублёвая акция TQBR (то, что теперь возвращает авторитетный резолв
  # через share_by_ticker вместо строкового совпадения тикера из кеша).
  def tradable_share(figi:, lot: 1)
    OpenStruct.new(
      figi: figi, lot: lot, uid: "uid_#{figi}", currency: 'rub', class_code: 'TQBR',
      buy_available_flag: true, sell_available_flag: true, api_trade_available_flag: true,
      trading_status: 'SECURITY_TRADING_STATUS_NORMAL_TRADING'
    )
  end

  def stub_share(instruments, ticker, figi:, lot: 1)
    allow(instruments).to receive(:share_by_ticker)
      .with(hash_including(ticker: ticker))
      .and_return(OpenStruct.new(instrument: tradable_share(figi: figi, lot: lot)))
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
    # По умолчанию тикер X резолвится в торгуемую акцию с figi "F_X".
    allow(instruments).to receive(:share_by_ticker) do |ticker:, **_|
      OpenStruct.new(instrument: tradable_share(figi: "F_#{ticker}"))
    end

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
    instruments = double('instruments')
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments)
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: rising_daily_candles))
    allow(instruments).to receive(:share_by_ticker) do |ticker:, **_|
      OpenStruct.new(instrument: tradable_share(figi: "F_#{ticker}"))
    end

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
    instruments = double('instruments')
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments)
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: rising_daily_candles))
    allow(instruments).to receive(:share_by_ticker) do |ticker:, **_|
      OpenStruct.new(instrument: tradable_share(figi: "F_#{ticker}"))
    end

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

  it 'resolves figi authoritatively via share_by_ticker, ignoring any figi in cache' do
    # В кеше намеренно "чужой" figi (как AT&T для тикера T) — он должен игнорироваться,
    # а торговаться авторитетный figi из share_by_ticker.
    market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_WRONG', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])

    client = double('client')
    market_data = double('market_data')
    instruments = double('instruments')
    operations = double('operations')

    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments)
    allow(client).to receive(:grpc_operations).and_return(operations)
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: rising_daily_candles))
    stub_share(instruments, 'AAA', figi: 'F_AAA')
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
    expect(logic).not_to have_received(:last_price_for).with('F_WRONG')
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

    allow(instruments).to receive(:share_by_ticker).and_raise(StandardError, 'lookup failed')

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

  it 'halts intersection BUY when caches are stale (older than max age)' do
    stale = Time.now.utc - (10 * 24 * 3600)
    market_cache = Tempfile.new(['m', '.json'])
    market_cache.write(JSON.generate({ 'updated_at' => stale.iso8601,
                                       'instruments' => [{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }] }))
    market_cache.flush
    index_cache = Tempfile.new(['i', '.json'])
    index_cache.write(JSON.generate({ 'updated_at' => stale.iso8601, 'instruments' => [{ 'ticker' => 'AAA' }] }))
    index_cache.flush

    logic = double('logic')
    expect(logic).not_to receive(:confirm_and_place_order_with_result)

    result = described_class.buy_one_momentum_from_intersection!(
      double('client'), logic, described_class.default_state,
      market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc'
    )
    expect(result).to be false
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'sends BUY quantity in LOTS (lots_per_order), not lot_size * lots, when lot_size > 1' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 10 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])
    client, _md, _ops, instruments = build_buy_flow_client(market_candles: rising_daily_candles)
    allow(instruments).to receive(:share_by_ticker)
      .with(hash_including(ticker: 'AAA'))
      .and_return(OpenStruct.new(instrument: tradable_share(figi: 'F_AAA', lot: 10)))

    logic = double('logic')
    allow(logic).to receive(:last_price_for).with('F_AAA').and_return(10.0)
    allow(logic).to receive(:dip_today?).with('F_AAA').and_return(true)
    allow(logic).to receive(:respond_to?).with(:near_support?).and_return(false)
    captured = nil
    allow(logic).to receive(:confirm_and_place_order_with_result) do |**kw|
      captured = kw
      { ok: true, category: :filled, response: OpenStruct.new(order_id: 'o'), client_order_id: 'c' }
    end

    result = described_class.buy_one_momentum_from_intersection!(
      client, logic, described_class.default_state,
      market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0, lots_per_order: 2, account_id: 'acc'
    )

    expect(result).to be true
    # 2 лота, а НЕ 10*2=20 бумаг
    expect(captured[:quantity]).to eq(2)
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'quarantines the figi after a permanent 30079 reject and skips it on the next run' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])
    client, = build_buy_flow_client(market_candles: rising_daily_candles)

    logic = double('logic')
    allow(logic).to receive(:last_price_for).with('F_AAA').and_return(100.0)
    allow(logic).to receive(:dip_today?).with('F_AAA').and_return(true)
    allow(logic).to receive(:respond_to?).with(:near_support?).and_return(false)
    allow(logic).to receive(:confirm_and_place_order_with_result).and_return(
      { ok: false, category: :broker_rejected, error_code: '30079',
        reject_reason: 'instrument not available for trading', client_order_id: 'c' }
    )

    state = described_class.default_state
    args = {
      market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc'
    }

    described_class.buy_one_momentum_from_intersection!(client, logic, state, **args)
    expect(state['quarantine']).to have_key('F_AAA')

    described_class.buy_one_momentum_from_intersection!(client, logic, state, **args)
    # confirm вызван РОВНО один раз: на втором проходе кандидат в карантине
    expect(logic).to have_received(:confirm_and_place_order_with_result).once
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'skips a same-ticker instrument that is not TQBR/rub (fail-closed resolution)' do
    market_cache = write_cache([{ 'ticker' => 'T', 'figi' => 'F_ATT', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'T' }])
    client, = build_buy_flow_client(market_candles: rising_daily_candles)
    foreign = OpenStruct.new(
      figi: 'F_ATT', lot: 1, uid: 'u', currency: 'usd', class_code: 'SPBXM',
      buy_available_flag: true, sell_available_flag: true, api_trade_available_flag: true,
      trading_status: 'SECURITY_TRADING_STATUS_NORMAL_TRADING'
    )
    allow(client.grpc_instruments).to receive(:share_by_ticker)
      .with(hash_including(ticker: 'T')).and_return(OpenStruct.new(instrument: foreign))

    logic = double('logic')
    expect(logic).not_to receive(:confirm_and_place_order_with_result)

    result = described_class.buy_one_momentum_from_intersection!(
      client, logic, described_class.default_state,
      market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc'
    )
    expect(result).to be false
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  describe '.try_sell_positions_with_logic!' do
    it 'sells ONE lot (quantity in lots), not the raw share count, for a multi-lot position' do
      position = OpenStruct.new(figi: 'F1', instrument_type: 'SHARE', quantity: OpenStruct.new(units: 100))
      client = double('client')
      ops = double('ops')
      instruments = double('instruments')
      allow(client).to receive(:grpc_operations).and_return(ops)
      allow(client).to receive(:grpc_instruments).and_return(instruments)
      allow(ops).to receive(:portfolio).and_return(OpenStruct.new(positions: [position]))
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F1').and_return(OpenStruct.new(lot: 10))

      logic = double('logic')
      allow(logic).to receive(:should_sell?).and_return(true)
      allow(logic).to receive(:last_price_for).with('F1').and_return(50.0)
      captured = nil
      allow(logic).to receive(:confirm_and_place_order) do |**kw|
        captured = kw
        OpenStruct.new(order_id: 'o')
      end

      described_class.try_sell_positions_with_logic!(
        client, logic, 'acc', described_class.default_state,
        figi_cache: { 'F1' => 'AAA' }, trend: :side
      )

      # 100 бумаг / лот 10 = 10 лотов, продаём 1 лот
      expect(captured[:quantity]).to eq(1)
    end
  end

  describe '.try_force_exit_positions_with_logic!' do
    it 'force-sells the full held lots even when the buy universe would be empty' do
      position = OpenStruct.new(
        figi: 'F1',
        instrument_type: 'SHARE',
        quantity: OpenStruct.new(units: 100),
        average_position_price: q(100)
      )
      client = double('client')
      ops = double('ops')
      instruments = double('instruments')
      allow(client).to receive(:grpc_operations).and_return(ops)
      allow(client).to receive(:grpc_instruments).and_return(instruments)
      allow(ops).to receive(:portfolio).and_return(OpenStruct.new(positions: [position]))
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F1').and_return(OpenStruct.new(lot: 10, ticker: 'AAA'))

      logic = double('logic')
      allow(logic).to receive(:should_force_exit?).with(position, 'F1').and_return(true)
      allow(logic).to receive(:last_price_for).with('F1').and_return(150.0)
      captured = nil
      allow(logic).to receive(:confirm_and_place_order) do |**kw|
        captured = kw
        OpenStruct.new(order_id: 'force-1')
      end

      described_class.try_force_exit_positions_with_logic!(
        client, logic, 'acc', figi_cache: { 'F1' => 'AAA' }
      )

      expect(captured[:figi]).to eq('F1')
      expect(captured[:quantity]).to eq(10)
    end

    it 'skips force-exit when instrument lot size cannot be resolved' do
      position = OpenStruct.new(
        figi: 'F1',
        instrument_type: 'SHARE',
        quantity: OpenStruct.new(units: 100),
        average_position_price: q(100)
      )
      client = double('client')
      ops = double('ops')
      instruments = double('instruments')
      allow(client).to receive(:grpc_operations).and_return(ops)
      allow(client).to receive(:grpc_instruments).and_return(instruments)
      allow(ops).to receive(:portfolio).and_return(OpenStruct.new(positions: [position]))
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F1').and_raise(StandardError, 'lookup failed')

      logic = double('logic')
      allow(logic).to receive(:should_force_exit?).with(position, 'F1').and_return(true)
      expect(logic).not_to receive(:last_price_for)
      expect(logic).not_to receive(:confirm_and_place_order)

      described_class.try_force_exit_positions_with_logic!(
        client, logic, 'acc', figi_cache: { 'F1' => 'AAA' }
      )
    end
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
