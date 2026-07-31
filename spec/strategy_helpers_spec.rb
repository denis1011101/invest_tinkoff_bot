# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/strategy_helpers'
require 'tempfile'
require 'json'
require 'ostruct'
require 'google/protobuf/timestamp_pb'

RSpec.describe TradingLogic::StrategyHelpers do
  def q(units, nano = 0)
    OpenStruct.new(units: units, nano: nano)
  end

  def positions_snapshot(rub:, blocked: 0, loading: false)
    OpenStruct.new(
      money: [OpenStruct.new(currency: 'rub', units: rub, nano: 0)],
      blocked: [OpenStruct.new(currency: 'rub', units: blocked, nano: 0)],
      limits_loading_in_progress: loading
    )
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

  def rising_daily_candles_with_incomplete_today_drop
    now = Time.now.utc
    [
      OpenStruct.new(close: q(10), is_complete: true,  time: OpenStruct.new(seconds: (now - (4 * 86_400)).to_i)),
      OpenStruct.new(close: q(11), is_complete: true,  time: OpenStruct.new(seconds: (now - (3 * 86_400)).to_i)),
      OpenStruct.new(close: q(12), is_complete: true,  time: OpenStruct.new(seconds: (now - (2 * 86_400)).to_i)),
      OpenStruct.new(close: q(13), is_complete: true,  time: OpenStruct.new(seconds: (now - 86_400).to_i)),
      OpenStruct.new(close: q(7),  is_complete: false, time: OpenStruct.new(seconds: now.to_i))
    ]
  end

  # Провал на первом изменении и рост на двух последних: strict3 отклоняет,
  # last2/two_of_three/cumulative пропускают.
  def dip_then_rising_daily_candles
    [
      OpenStruct.new(close: q(10)),
      OpenStruct.new(close: q(9)),
      OpenStruct.new(close: q(11)),
      OpenStruct.new(close: q(12))
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
      OpenStruct.new(total_amount_shares: q(10_000), total_amount_currencies: q(10_000), positions: [])
    )
    allow(client).to receive(:positions).and_return(positions_snapshot(rub: 10_000))
    # По умолчанию тикер X резолвится в торгуемую акцию с figi "F_X".
    allow(instruments).to receive(:share_by_ticker) do |ticker:, **_|
      OpenStruct.new(instrument: tradable_share(figi: "F_#{ticker}"))
    end

    [client, market_data, operations, instruments]
  end

  it 'loads a failed portfolio preflight only once for all intersection candidates' do
    tickers = %w[AAA BBB CCC]
    market_cache = write_cache(tickers.map { |ticker| { 'ticker' => ticker } })
    index_cache = write_cache(tickers.map { |ticker| { 'ticker' => ticker } })
    client, _market_data, operations, = build_buy_flow_client(market_candles: rising_daily_candles)
    expect(operations).to receive(:portfolio).once.and_raise(StandardError, 'portfolio unavailable')
    expect(client).not_to receive(:positions)

    logic = double('logic')
    allow(logic).to receive(:last_price_for).and_return(100.0)
    allow(logic).to receive(:dip_today?).and_return(true)
    expect(logic).not_to receive(:confirm_and_place_order_with_result)

    result = described_class.buy_one_momentum_from_intersection!(
      client,
      logic,
      described_class.default_state,
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

  it 'tracks pending BUY without last_buy mark when category is sent_not_filled' do
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
      OpenStruct.new(total_amount_shares: q(10_000), total_amount_currencies: q(10_000), positions: [])
    )
    allow(client).to receive(:positions).and_return(positions_snapshot(rub: 10_000))

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
    expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d'), {})).not_to have_key('AAA')
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'tracks pending BUY and marks last_buy when category is partially_filled' do
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
      OpenStruct.new(total_amount_shares: q(10_000), total_amount_currencies: q(10_000), positions: [])
    )
    allow(client).to receive(:positions).and_return(positions_snapshot(rub: 10_000))

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

  it 'uses only completed daily candles for momentum validation' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])
    client, market_data = build_buy_flow_client(market_candles: rising_daily_candles)
    allow(market_data).to receive(:candles).and_return(
      OpenStruct.new(candles: rising_daily_candles_with_incomplete_today_drop)
    )

    logic = double('logic')
    allow(logic).to receive(:last_price_for).with('F_AAA').and_return(100.0)
    allow(logic).to receive(:dip_today?).with('F_AAA').and_return(true)
    allow(logic).to receive(:respond_to?).with(:near_support?).and_return(false)
    expect(logic).to receive(:confirm_and_place_order_with_result).once.and_return(
      {
        ok: true,
        category: :filled,
        response: OpenStruct.new(order_id: 'order-complete-1'),
        client_order_id: 'client-complete-1'
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
      OpenStruct.new(total_amount_shares: q(10_000), total_amount_currencies: q(10_000), positions: [])
    )
    allow(client).to receive(:positions).and_return(positions_snapshot(rub: 10_000))

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

  it 'skips candidate when pending buy is old but still active in state' do
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
          'ts' => (Time.now.utc - (24 * 3600)).iso8601
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

  describe '.cleanup_pending_orders!' do
    it 'keeps pending when get_orders returns nil (malformed response)' do
      client = double('client')
      orders = double('orders')
      logger = double('logger', warn: nil)
      allow(client).to receive(:grpc_orders).and_return(orders)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(nil)

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'req-uuid-1',
            'broker_order_id' => '82057073067',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state, logger: logger)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(logger).to have_received(:warn).with(include('get_orders: nil response'))
      expect(logger).to have_received(:warn).with(include('reason="nil response"'))
    end

    it 'keeps pending when get_orders response does not have orders field' do
      client = double('client')
      orders = double('orders')
      logger = double('logger', warn: nil)
      allow(client).to receive(:grpc_orders).and_return(orders)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(foo: []))

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'req-uuid-1',
            'broker_order_id' => '82057073067',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state, logger: logger)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(logger).to have_received(:warn).with(include('get_orders: response missing orders'))
      expect(logger).to have_received(:warn).with(include('reason="response missing orders"'))
    end

    it 'keeps pending when get_orders orders is nil' do
      client = double('client')
      orders = double('orders')
      logger = double('logger', warn: nil)
      allow(client).to receive(:grpc_orders).and_return(orders)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: nil))

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'req-uuid-1',
            'broker_order_id' => '82057073067',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state, logger: logger)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(logger).to have_received(:warn).with(include('get_orders: orders is nil'))
      expect(logger).to have_received(:warn).with(include('reason="orders is nil"'))
    end

    it 'keeps pending when active order has matching order_request_id but different broker order_id' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      active_order = OpenStruct.new(order_id: '82057073067', order_request_id: 'req-uuid-1')
      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: [active_order]))
      expect(operations).not_to receive(:operations_by_cursor)

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'req-uuid-1',
            'broker_order_id' => '999999',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(state.fetch('last_buy')).to eq({})
    end

    it 'marks last_buy when pending order disappears and buy execution is present in broker operations' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))

      buy_op = OpenStruct.new(type: 'OPERATION_TYPE_BUY', figi: 'F_AAA', date: Time.now.utc.iso8601, quantity_done: 1)
      allow(operations).to receive(:operations_by_cursor).and_return(OpenStruct.new(items: [buy_op], has_next: false))

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-1',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to eq({})
      expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d')).fetch('AAA')).to be true
    end

    it 'keeps pending when operations API fails (reconciliation unknown)' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      allow(operations).to receive(:operations_by_cursor).and_raise(StandardError, 'temporary outage')

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-unknown',
            'broker_order_id' => 'brk-unknown',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(state.fetch('last_buy')).to eq({})
    end

    it 'keeps pending when operations_by_cursor returns nil (malformed response)' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      allow(operations).to receive(:operations_by_cursor).and_return(nil)

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-nil-ops',
            'broker_order_id' => 'brk-nil-ops',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(state.fetch('last_buy')).to eq({})
    end

    it 'keeps pending when operations service has no supported history method' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-no-ops-method',
            'broker_order_id' => 'brk-no-ops-method',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(state.fetch('last_buy')).to eq({})
    end

    it 'keeps pending when operations response has_next=true and execution is not in first page' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      page1 = OpenStruct.new(items: [OpenStruct.new(type: 'OPERATION_TYPE_BUY', figi: 'F_AAA')], has_next: true)
      allow(operations).to receive(:operations_by_cursor).and_return(page1)

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-page-1',
            'broker_order_id' => 'brk-page-1',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(state.fetch('last_buy')).to eq({})
    end

    it 'keeps pending when FIGI is missing to avoid cross-instrument false matches' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      buy_op = OpenStruct.new(type: 'OPERATION_TYPE_BUY', figi: 'F_OTHER', date: Time.now.utc.iso8601)
      allow(operations).to receive(:operations_by_cursor).and_return(OpenStruct.new(items: [buy_op]))

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-no-figi',
            'broker_order_id' => 'brk-no-figi',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(state.fetch('last_buy')).to eq({})
    end

    it 'does not mark last_buy from BUY operation without execution evidence' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      buy_op = OpenStruct.new(type: 'OPERATION_TYPE_BUY', figi: 'F_AAA', state: 'OPERATION_STATE_CANCELLED')
      allow(operations).to receive(:operations_by_cursor).and_return(OpenStruct.new(items: [buy_op], has_next: false))

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-no-exec',
            'broker_order_id' => 'brk-no-exec',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to eq({})
      expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d'), {})).not_to have_key('AAA')
    end

    it 'marks last_buy when BUY operation has execution in trades_info.trades' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      trades_info = OpenStruct.new(trades: [OpenStruct.new(quantity: 1)])
      buy_op = OpenStruct.new(type: 'OPERATION_TYPE_BUY', figi: 'F_AAA', trades_info: trades_info)
      allow(operations).to receive(:operations_by_cursor).and_return(OpenStruct.new(items: [buy_op], has_next: false))

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-trades-info',
            'broker_order_id' => 'brk-trades-info',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to eq({})
      expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d')).fetch('AAA')).to be true
    end

    it 'removes pending order without marking last_buy when there is no buy execution' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      allow(operations).to receive(:operations_by_cursor).and_return(OpenStruct.new(items: []))

      state = {
        'last_buy' => {},
        'last_sell' => {},
        'pending_orders' => {
          'AAA' => {
            'client_order_id' => 'order-2',
            'figi' => 'F_AAA',
            'ticker' => 'AAA',
            'ts' => (Time.now.utc - 600).iso8601,
            'status' => 'sent_not_filled'
          }
        }
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to eq({})
      expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d'), {})).not_to have_key('AAA')
    end

    it 'requests cancellation after TTL but releases the reservation only after terminal reconciliation' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)

      active = OpenStruct.new(
        order_id: 'broker-ttl',
        order_request_id: 'client-ttl',
        execution_report_status: 'EXECUTION_REPORT_STATUS_NEW',
        lots_requested: 2,
        lots_executed: 0,
        total_order_amount: q(201.2)
      )
      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(
        OpenStruct.new(orders: [active]),
        OpenStruct.new(orders: [])
      )
      allow(client).to receive(:cancel_order)
        .with(account_id: 'acc', order_id: 'broker-ttl')
        .and_return(OpenStruct.new(success?: true))
      cancelled = {
        'executionReportStatus' => 'EXECUTION_REPORT_STATUS_CANCELLED',
        'lotsRequested' => 2,
        'lotsExecuted' => 0,
        'totalOrderAmount' => { 'units' => 201, 'nano' => 200_000_000 }
      }
      allow(client).to receive(:order_state)
        .with(account_id: 'acc', order_id: 'broker-ttl')
        .and_return(OpenStruct.new(success?: true, payload: cancelled))

      state = described_class.default_state
      state['pending_orders']['AAA'] = {
        'client_order_id' => 'client-ttl',
        'broker_order_id' => 'broker-ttl',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => (Time.now.utc - 1_200).iso8601,
        'status' => 'sent_not_filled',
        'planned_value' => 200.0,
        'filled_value' => 0.0,
        'reserved_value' => 200.0
      }

      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10)

      expect(client).to have_received(:cancel_order).once
      expect(state.fetch('pending_orders').fetch('AAA')).to have_key('cancel_requested_at')
      expect(described_class.pending_buy_reserved_total(state)).to eq(200)

      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10)

      expect(state.fetch('pending_orders')).to eq({})
      expect(client).to have_received(:order_state).once
      expect(described_class.pending_buy_reserved_total(state)).to eq(0)
      expect(described_class.daily_buy_total(state)).to eq(0)
    end

    it 'migrates an active legacy commitment from daily_buys into an order reservation' do
      client = double('client')
      orders = double('orders')
      allow(client).to receive(:grpc_orders).and_return(orders)

      active = OpenStruct.new(
        order_id: 'broker-legacy',
        order_request_id: 'client-legacy',
        execution_report_status: 'EXECUTION_REPORT_STATUS_NEW',
        lots_requested: 2,
        lots_executed: 0,
        initial_order_price: q(200),
        total_order_amount: q(201.2)
      )
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: [active]))

      state = described_class.default_state
      described_class.register_daily_buy!(state, 200)
      state['pending_orders']['AAA'] = {
        'client_order_id' => 'client-legacy',
        'broker_order_id' => 'broker-legacy',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => Time.now.utc.iso8601,
        'status' => 'sent_not_filled'
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(described_class.daily_buy_total(state)).to eq(0)
      expect(described_class.pending_buy_reserved_total(state)).to eq(200)
      expect(described_class.daily_buy_committed_total(state)).to eq(200)
    end

    it 'keeps the reservation when cancellation has no confirmed terminal status' do
      client = double('client')
      orders = double('orders')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: []))
      still_active = OpenStruct.new(
        execution_report_status: 'EXECUTION_REPORT_STATUS_NEW',
        lots_requested: 1,
        lots_executed: 0
      )
      allow(client).to receive(:order_state)
        .with(account_id: 'acc', order_id: 'broker-wait')
        .and_return(OpenStruct.new(success?: true, payload: still_active))

      state = described_class.default_state
      state['pending_orders']['AAA'] = {
        'client_order_id' => 'client-wait',
        'broker_order_id' => 'broker-wait',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => (Time.now.utc - 1_200).iso8601,
        'status' => 'sent_not_filled',
        'planned_value' => 100.0,
        'filled_value' => 0.0,
        'reserved_value' => 100.0,
        'cancel_requested_at' => Time.now.utc.iso8601
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(described_class.pending_buy_reserved_total(state)).to eq(100)
    end

    # PARTIALLYFILL терминальным не является, а отсутствие в одной выдаче GetOrders
    # не доказывает судьбу заявки — резерв держим до явного CANCELLED/REJECTED/FILL.
    it 'keeps the reservation while a cancelled order still reports PARTIALLYFILL' do
      client = double('client')
      orders = double('orders')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: []))
      partial = OpenStruct.new(
        execution_report_status: 'EXECUTION_REPORT_STATUS_PARTIALLYFILL',
        lots_requested: 4,
        lots_executed: 1
      )
      allow(client).to receive(:order_state)
        .with(account_id: 'acc', order_id: 'broker-partial')
        .and_return(OpenStruct.new(success?: true, payload: partial))

      state = described_class.default_state
      state['pending_orders']['AAA'] = {
        'client_order_id' => 'client-partial',
        'broker_order_id' => 'broker-partial',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => (Time.now.utc - 1_200).iso8601,
        'status' => 'partially_filled',
        'planned_value' => 200.0,
        'filled_value' => 0.0,
        'reserved_value' => 200.0,
        'cancel_requested_at' => Time.now.utc.iso8601
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      pending = state.fetch('pending_orders').fetch('AAA')
      expect(pending.fetch('terminal_confirm_attempts')).to eq(1)
      expect(pending.fetch('filled_value')).to eq(50)
      expect(described_class.pending_buy_reserved_total(state)).to eq(150)
      expect(described_class.daily_buy_total(state)).to eq(50)
    end

    it 'retries cancellation with backoff instead of firing every run' do
      client = double('client')
      orders = double('orders')
      allow(client).to receive(:grpc_orders).and_return(orders)
      active = OpenStruct.new(
        order_id: 'broker-retry',
        order_request_id: 'client-retry',
        execution_report_status: 'EXECUTION_REPORT_STATUS_NEW',
        lots_requested: 2,
        lots_executed: 0
      )
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: [active]))
      allow(client).to receive(:cancel_order)
        .with(account_id: 'acc', order_id: 'broker-retry')
        .and_return(OpenStruct.new(success?: true))

      state = described_class.default_state
      info = {
        'client_order_id' => 'client-retry',
        'broker_order_id' => 'broker-retry',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => (Time.now.utc - 1_200).iso8601,
        'status' => 'sent_not_filled',
        'planned_value' => 200.0,
        'filled_value' => 0.0,
        'reserved_value' => 200.0
      }
      state['pending_orders']['AAA'] = info

      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10)
      expect(info.fetch('cancel_attempts')).to eq(1)

      # Сразу следующий прогон cron — backoff ещё не истёк.
      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10)
      expect(info.fetch('cancel_attempts')).to eq(1)

      info['cancel_requested_at'] = (Time.now.utc - 600).iso8601
      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10)
      expect(info.fetch('cancel_attempts')).to eq(2)
      expect(client).to have_received(:cancel_order).twice
      expect(described_class.pending_buy_reserved_total(state)).to eq(200)
    end

    it 'applies backoff and the stuck threshold to unsuccessful cancel requests' do
      previous_max_attempts = ENV.fetch('BUY_CANCEL_MAX_ATTEMPTS', nil)
      ENV['BUY_CANCEL_MAX_ATTEMPTS'] = '2'

      client = double('client')
      orders = double('orders')
      logger = double('logger', debug: nil, info: nil, warn: nil, error: nil)
      allow(client).to receive(:grpc_orders).and_return(orders)
      active = OpenStruct.new(
        order_id: 'broker-failing-cancel',
        order_request_id: 'client-failing-cancel',
        execution_report_status: 'EXECUTION_REPORT_STATUS_NEW',
        lots_requested: 1,
        lots_executed: 0
      )
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: [active]))
      allow(client).to receive(:cancel_order)
        .with(account_id: 'acc', order_id: 'broker-failing-cancel')
        .and_return(OpenStruct.new(success?: false))

      state = described_class.default_state
      info = {
        'client_order_id' => 'client-failing-cancel',
        'broker_order_id' => 'broker-failing-cancel',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => (Time.now.utc - 1_200).iso8601,
        'status' => 'sent_not_filled',
        'planned_value' => 100.0,
        'filled_value' => 0.0,
        'reserved_value' => 100.0
      }
      state['pending_orders']['AAA'] = info

      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10, logger: logger)
      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10, logger: logger)
      expect(info.fetch('cancel_attempts')).to eq(1)
      expect(client).to have_received(:cancel_order).once

      info['cancel_requested_at'] = (Time.now.utc - 600).iso8601
      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10, logger: logger)
      described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 10, logger: logger)

      expect(info.fetch('cancel_attempts')).to eq(2)
      expect(client).to have_received(:cancel_order).twice
      expect(logger).to have_received(:error).with(/BUY CANCEL STUCK AAA/).once
      expect(described_class.pending_buy_reserved_total(state)).to eq(100)
    ensure
      ENV['BUY_CANCEL_MAX_ATTEMPTS'] = previous_max_attempts
    end

    it 'raises one error alert after repeated unconfirmed cancellations' do
      client = double('client')
      orders = double('orders')
      logger = double('logger', debug: nil, info: nil, warn: nil, error: nil)
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: []))
      still_active = OpenStruct.new(
        execution_report_status: 'EXECUTION_REPORT_STATUS_NEW',
        lots_requested: 1,
        lots_executed: 0
      )
      allow(client).to receive(:order_state)
        .with(account_id: 'acc', order_id: 'broker-stuck')
        .and_return(OpenStruct.new(success?: true, payload: still_active))

      state = described_class.default_state
      info = {
        'client_order_id' => 'client-stuck',
        'broker_order_id' => 'broker-stuck',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => (Time.now.utc - 1_200).iso8601,
        'status' => 'sent_not_filled',
        'planned_value' => 100.0,
        'filled_value' => 0.0,
        'reserved_value' => 100.0,
        'cancel_requested_at' => Time.now.utc.iso8601
      }
      state['pending_orders']['AAA'] = info

      6.times { described_class.cleanup_pending_orders!(client, 'acc', state, logger: logger) }

      expect(info.fetch('terminal_confirm_attempts')).to eq(6)
      expect(logger).to have_received(:error).with(/BUY CANCEL STUCK AAA/).once
      expect(described_class.pending_buy_reserved_total(state)).to eq(100)
    end

    it 'keeps the remaining reservation when a partial fill disappears from GetOrders' do
      client = double('client')
      orders = double('orders')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      partial = OpenStruct.new(
        execution_report_status: 'EXECUTION_REPORT_STATUS_PARTIALLYFILL',
        lots_requested: 4,
        lots_executed: 1
      )
      allow(client).to receive(:order_state)
        .with(account_id: 'acc', order_id: 'broker-partial')
        .and_return(OpenStruct.new(success?: true, payload: partial))

      state = described_class.default_state
      described_class.register_daily_buy!(state, 50)
      state['pending_orders']['AAA'] = {
        'client_order_id' => 'client-partial',
        'broker_order_id' => 'broker-partial',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => (Time.now.utc - 600).iso8601,
        'status' => 'partially_filled',
        'planned_value' => 200.0,
        'filled_value' => 50.0,
        'reserved_value' => 150.0
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(described_class.daily_buy_total(state)).to eq(50)
      expect(described_class.pending_buy_reserved_total(state)).to eq(150)
    end

    it 'alerts once when a partial fill stays unresolved with cancellation disabled' do
      previous_max_attempts = ENV.fetch('BUY_CANCEL_MAX_ATTEMPTS', nil)
      ENV['BUY_CANCEL_MAX_ATTEMPTS'] = '5'

      client = double('client')
      orders = double('orders')
      logger = double('logger', debug: nil, info: nil, warn: nil, error: nil)
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: []))
      partial = OpenStruct.new(
        execution_report_status: 'EXECUTION_REPORT_STATUS_PARTIALLYFILL',
        lots_requested: 4,
        lots_executed: 1
      )
      allow(client).to receive(:order_state)
        .with(account_id: 'acc', order_id: 'broker-no-ttl')
        .and_return(OpenStruct.new(success?: true, payload: partial))

      state = described_class.default_state
      info = {
        'client_order_id' => 'client-no-ttl',
        'broker_order_id' => 'broker-no-ttl',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => (Time.now.utc - 14_400).iso8601,
        'status' => 'partially_filled',
        'planned_value' => 200.0,
        'filled_value' => 0.0,
        'reserved_value' => 200.0
      }
      state['pending_orders']['AAA'] = info

      6.times do
        described_class.cleanup_pending_orders!(client, 'acc', state, ttl_minutes: 0, logger: logger)
      end

      expect(state.fetch('pending_orders')).to have_key('AAA')
      expect(info.fetch('cancel_requested_at', nil)).to be_nil
      expect(info.fetch('terminal_confirm_attempts')).to eq(6)
      expect(info.fetch('cancel_alerted')).to be true
      expect(described_class.daily_buy_total(state)).to eq(50)
      expect(described_class.pending_buy_reserved_total(state)).to eq(150)
      expect(logger).to have_received(:error).with(/BUY PENDING STUCK AAA/).once
      expect(logger).to have_received(:warn)
        .with(/pending order for AAA left untouched — terminal status unknown/)
        .at_least(:once)
    ensure
      ENV['BUY_CANCEL_MAX_ATTEMPTS'] = previous_max_attempts
    end

    it 'does not grow the reservation when a later active-order snapshot omits lot counters' do
      client = double('client')
      orders = double('orders')
      allow(client).to receive(:grpc_orders).and_return(orders)
      incomplete = OpenStruct.new(
        order_id: 'broker-partial',
        order_request_id: 'client-partial',
        execution_report_status: 'EXECUTION_REPORT_STATUS_PARTIALLYFILL'
      )
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: [incomplete]))

      state = described_class.default_state
      described_class.register_daily_buy!(state, 50)
      state['pending_orders']['AAA'] = {
        'client_order_id' => 'client-partial',
        'broker_order_id' => 'broker-partial',
        'figi' => 'F_AAA',
        'ticker' => 'AAA',
        'ts' => Time.now.utc.iso8601,
        'status' => 'partially_filled',
        'planned_value' => 200.0,
        'filled_value' => 50.0,
        'reserved_value' => 150.0
      }

      described_class.cleanup_pending_orders!(client, 'acc', state)

      pending = state.fetch('pending_orders').fetch('AAA')
      expect(pending.fetch('filled_value')).to eq(50)
      expect(pending.fetch('reserved_value')).to eq(150)
      expect(pending.fetch('filled_value') + pending.fetch('reserved_value')).to eq(200)
      expect(described_class.daily_buy_total(state)).to eq(50)
    end
  end

  describe 'momentum rule variants' do
    around do |example|
      previous = ENV.fetch('MOMENTUM_RULE', nil)
      example.run
    ensure
      ENV['MOMENTUM_RULE'] = previous
    end

    it 'scores all four rules from the same four closes' do
      expect(described_class.momentum_verdicts([10, 11, 12, 13])).to eq(
        'strict3' => true, 'last2' => true, 'two_of_three' => true, 'cumulative' => true
      )
      expect(described_class.momentum_verdicts([10, 9, 11, 12])).to eq(
        'strict3' => false, 'last2' => true, 'two_of_three' => true, 'cumulative' => true
      )
      expect(described_class.momentum_verdicts([10, 11, 12, 9])).to eq(
        'strict3' => false, 'last2' => false, 'two_of_three' => true, 'cumulative' => false
      )
      expect(described_class.momentum_verdicts([10, 11, 9, 10])).to eq(
        'strict3' => false, 'last2' => false, 'two_of_three' => true, 'cumulative' => false
      )
    end

    it 'defaults to strict3 and warns once on an unknown rule' do
      ENV.delete('MOMENTUM_RULE')
      expect(described_class.momentum_rule).to eq('strict3')

      ENV['MOMENTUM_RULE'] = 'ma5'
      logger = double('logger')
      expect(logger).to receive(:warn).once.with(/unknown MOMENTUM_RULE="ma5"/)
      expect(described_class.momentum_rule(logger: logger)).to eq('strict3')
    end

    it 'keeps strict3 rejecting a candidate that only rose on the last two days' do
      market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
      index_cache = write_cache([{ 'ticker' => 'AAA' }])
      client, = build_buy_flow_client(market_candles: dip_then_rising_daily_candles)
      ENV['MOMENTUM_RULE'] = 'strict3'

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

    it 'lets the same candidate through when MOMENTUM_RULE=last2' do
      market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
      index_cache = write_cache([{ 'ticker' => 'AAA' }])
      client, = build_buy_flow_client(market_candles: dip_then_rising_daily_candles)
      ENV['MOMENTUM_RULE'] = 'last2'

      logic = double('logic')
      allow(logic).to receive_messages(last_price_for: 100.0, dip_today?: true,
                                       entry_stretch_metrics: {}, nearest_support: nil)
      expect(logic).to receive(:confirm_and_place_order_with_result).once.and_return(
        { ok: true, category: :filled, order: OpenStruct.new(order_id: 'o1') }
      )

      result = described_class.buy_one_momentum_from_intersection!(
        client, logic, described_class.default_state,
        market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
        max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc'
      )

      expect(result).to be true
    ensure
      market_cache&.close!
      index_cache&.close!
    end

    it 'logs every rule verdict in a single parsable shadow line' do
      market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
      index_cache = write_cache([{ 'ticker' => 'AAA' }])
      client, = build_buy_flow_client(market_candles: dip_then_rising_daily_candles)
      ENV['MOMENTUM_RULE'] = 'strict3'

      lines = []
      logger = double('logger')
      allow(logger).to receive(:debug) { |message| lines << message }
      allow(logger).to receive(:warn)

      described_class.buy_one_momentum_from_intersection!(
        client, double('logic'), described_class.default_state,
        market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
        max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc', logger: logger,
        scan_id: 'scan-shadow'
      )

      shadow = lines.find { |line| line.start_with?('momentum_shadow ') }
      expect(shadow).to eq(
        'momentum_shadow ticker=AAA closes=[10.0, 9.0, 11.0, 12.0] ' \
        'strict3=0 last2=1 two_of_three=1 cumulative=1 active=strict3 pass=0 scan_id=scan-shadow'
      )
    ensure
      market_cache&.close!
      index_cache&.close!
    end

    it 'logs one terminal funnel event with the same scan id when momentum rejects a ticker' do
      market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
      index_cache = write_cache([{ 'ticker' => 'AAA' }])
      client, = build_buy_flow_client(market_candles: dip_then_rising_daily_candles)
      ENV['MOMENTUM_RULE'] = 'strict3'

      lines = []
      logger = double('logger')
      allow(logger).to receive(:debug) { |message| lines << message }
      allow(logger).to receive(:warn)

      result = described_class.buy_one_momentum_from_intersection!(
        client, double('logic'), described_class.default_state,
        market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
        max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc', logger: logger,
        scan_id: 'scan-funnel-reject'
      )

      funnel = lines.grep(/^buy_funnel /)
      expect(result).to be false
      expect(funnel.size).to eq(1)
      expect(JSON.parse(funnel.first.delete_prefix('buy_funnel '))).to include(
        'scan_id' => 'scan-funnel-reject',
        'ticker' => 'AAA',
        'path' => 'intersection',
        'stage' => 'momentum',
        'outcome' => 'rejected',
        'reason' => 'active_rule_failed',
        'active_rule' => 'strict3'
      )
    ensure
      market_cache&.close!
      index_cache&.close!
    end
  end

  it 'logs the broker outcome as the terminal funnel event for an eligible ticker' do
    market_cache = write_cache([{ 'ticker' => 'AAA', 'figi' => 'F_AAA', 'lot' => 1 }])
    index_cache = write_cache([{ 'ticker' => 'AAA' }])
    client, = build_buy_flow_client(market_candles: rising_daily_candles)

    logic = double('logic')
    allow(logic).to receive_messages(last_price_for: 100.0, dip_today?: true,
                                     entry_stretch_metrics: {}, nearest_support: nil)
    allow(logic).to receive(:confirm_and_place_order_with_result).and_return(
      {
        ok: false,
        category: :sent_not_filled,
        response: OpenStruct.new(order_id: 'broker-1', order_request_id: 'client-1')
      }
    )

    lines = []
    logger = double('logger')
    allow(logger).to receive(:debug) { |message| lines << message }
    allow(logger).to receive(:warn)

    result = described_class.buy_one_momentum_from_intersection!(
      client, logic, described_class.default_state,
      market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc', logger: logger,
      scan_id: 'scan-funnel-order'
    )

    funnel = lines.grep(/^buy_funnel /)
    expect(result).to be true
    expect(funnel.size).to eq(1)
    expect(JSON.parse(funnel.first.delete_prefix('buy_funnel '))).to include(
      'scan_id' => 'scan-funnel-order',
      'ticker' => 'AAA',
      'path' => 'intersection',
      'stage' => 'order',
      'outcome' => 'committed',
      'reason' => 'sent_not_filled',
      'client_order_id' => 'client-1',
      'broker_order_id' => 'broker-1'
    )
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

  it 'stores both broker_order_id and client_order_id for pending orders' do
    state = described_class.default_state
    response = OpenStruct.new(order_id: '82057073067', order_request_id: 'req-uuid-42')

    described_class.sync_pending_order!(
      state,
      'AAA',
      { category: :sent_not_filled, response: response, client_order_id: 'fallback-client', figi: 'F_AAA' }
    )

    pending = state.fetch('pending_orders').fetch('AAA')
    expect(pending.fetch('broker_order_id')).to eq('82057073067')
    expect(pending.fetch('client_order_id')).to eq('req-uuid-42')
  end

  it 'stores pending ts from submitted_at when present' do
    state = described_class.default_state
    submitted_at = '2026-07-23T10:00:00Z'

    described_class.sync_pending_order!(
      state,
      'AAA',
      { category: :sent_not_filled, client_order_id: 'fallback-client', figi: 'F_AAA', submitted_at: submitted_at }
    )

    pending = state.fetch('pending_orders').fetch('AAA')
    expect(pending.fetch('ts')).to eq(submitted_at)
  end

  describe '.restore_pending_buy_orders!' do
    it 'restores pending ts from protobuf order_date and marks last_buy when lots_executed > 0' do
      client = double('client')
      orders = double('orders')
      instruments = double('instruments')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_instruments).and_return(instruments)

      order_time = Time.utc(2026, 7, 23, 9, 15, 0)
      order_date = Google::Protobuf::Timestamp.new(seconds: order_time.to_i)
      restored = OpenStruct.new(
        direction: 'ORDER_DIRECTION_BUY',
        execution_report_status: 'EXECUTION_REPORT_STATUS_PARTIALLYFILL',
        figi: 'F_AAA',
        order_id: '82057073067',
        order_request_id: 'req-uuid-restored',
        order_date: order_date,
        lots_executed: 1
      )
      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: [restored]))
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F_AAA').and_return(OpenStruct.new(ticker: 'AAA'))

      state = described_class.default_state
      described_class.restore_pending_buy_orders!(client, 'acc', state)

      pending = state.fetch('pending_orders').fetch('AAA')
      expect(pending.fetch('ts')).to eq(order_time.iso8601)
      expect(state.fetch('last_buy').fetch(Time.now.utc.strftime('%Y-%m-%d')).fetch('AAA')).to be true
    end

    it 'restores today filled amount and remaining reservation without understating the budget' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      instruments = double('instruments')
      allow(client).to receive_messages(
        grpc_orders: orders,
        grpc_operations: operations,
        grpc_instruments: instruments
      )

      buy_op = OpenStruct.new(
        type: 'OPERATION_TYPE_BUY',
        figi: 'F_AAA',
        date: Time.now.utc.iso8601,
        quantity_done: 1,
        payment: q(-50)
      )
      allow(operations).to receive(:operations_by_cursor)
        .and_return(OpenStruct.new(items: [buy_op]))
      active = OpenStruct.new(
        direction: 'ORDER_DIRECTION_BUY',
        execution_report_status: 'EXECUTION_REPORT_STATUS_PARTIALLYFILL',
        figi: 'F_AAA',
        order_id: 'broker-restore-budget',
        order_request_id: 'client-restore-budget',
        order_date: Google::Protobuf::Timestamp.new(seconds: Time.now.utc.to_i),
        lots_requested: 4,
        lots_executed: 1,
        initial_order_price: q(200),
        total_order_amount: q(201.2)
      )
      allow(orders).to receive(:get_orders)
        .with(account_id: 'acc')
        .and_return(OpenStruct.new(orders: [active]))
      allow(instruments).to receive(:get_instrument_by)
        .with(:figi, 'F_AAA')
        .and_return(OpenStruct.new(ticker: 'AAA'))

      state = described_class.default_state
      described_class.restore_state_from_broker_if_empty!(client, 'acc', state)

      pending = state.fetch('pending_orders').fetch('AAA')
      expect(described_class.daily_buy_total(state)).to eq(50)
      expect(pending.fetch('filled_value')).to eq(50)
      expect(pending.fetch('reserved_value')).to eq(150)
      expect(described_class.daily_buy_committed_total(state)).to eq(200)
    end
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
    lines = []
    logger = double('logger', warn: nil)
    allow(logger).to receive(:debug) { |message| lines << message }

    result = described_class.buy_one_momentum_from_intersection!(
      double('client'), logic, described_class.default_state,
      market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc',
      logger: logger, scan_id: 'scan-stale'
    )

    scan_lines = lines.grep(/^buy_funnel_scan /)
    scan_event = JSON.parse(scan_lines.fetch(0).delete_prefix('buy_funnel_scan '))
    expect(result).to be false
    expect(scan_lines.size).to eq(1)
    expect(scan_event).to include(
      'scan_id' => 'scan-stale',
      'path' => 'intersection',
      'outcome' => 'stale_cache',
      'max_age_hours' => 72
    )
  ensure
    market_cache&.close!
    index_cache&.close!
  end

  it 'logs a scan-level outcome when the cache intersection is empty' do
    market_cache = write_cache([{ 'ticker' => 'AAA' }])
    index_cache = write_cache([{ 'ticker' => 'BBB' }])
    lines = []
    logger = double('logger')
    allow(logger).to receive(:debug) { |message| lines << message }

    result = described_class.buy_one_momentum_from_intersection!(
      double('client'), double('logic'), described_class.default_state,
      market_cache_path: market_cache.path, moex_index_cache_path: index_cache.path,
      max_lot_rub: 1_000.0, lots_per_order: 1, account_id: 'acc',
      logger: logger, scan_id: 'scan-empty'
    )

    scan_lines = lines.grep(/^buy_funnel_scan /)
    scan_event = JSON.parse(scan_lines.fetch(0).delete_prefix('buy_funnel_scan '))
    expect(result).to be false
    expect(scan_lines.size).to eq(1)
    expect(scan_event).to eq(
      'scan_id' => 'scan-empty',
      'path' => 'intersection',
      'outcome' => 'empty_intersection',
      'market_tickers' => 1,
      'index_tickers' => 1
    )
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
      orders = double('orders')
      allow(client).to receive(:grpc_operations).and_return(ops)
      allow(client).to receive(:grpc_instruments).and_return(instruments)
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      allow(ops).to receive(:portfolio).and_return(OpenStruct.new(positions: [position]))
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F1').and_return(OpenStruct.new(lot: 10))

      logic = double('logic')
      allow(logic).to receive(:should_sell?).and_return(true)
      allow(logic).to receive(:last_price_for).with('F1').and_return(50.0)
      captured = nil
      allow(logic).to receive(:confirm_and_place_order_with_result) do |**kw|
        captured = kw
        { ok: false, category: :sent_not_filled, response: OpenStruct.new(order_id: 'o') }
      end

      described_class.try_sell_positions_with_logic!(
        client, logic, 'acc', described_class.default_state,
        figi_cache: { 'F1' => 'AAA' }, trend: :side
      )

      # 100 бумаг / лот 10 = 10 лотов, продаём 1 лот
      expect(captured[:quantity]).to eq(1)
    end

    it 'skips the signal SELL when the broker already has an active SELL for the figi' do
      position = OpenStruct.new(figi: 'F1', instrument_type: 'SHARE', quantity: OpenStruct.new(units: 10))
      active_sell = OpenStruct.new(
        figi: 'F1', direction: 'ORDER_DIRECTION_SELL', order_id: 'active-sell',
        execution_report_status: 'EXECUTION_REPORT_STATUS_NEW'
      )
      client = double('client')
      allow(client).to receive(:grpc_orders).and_return(
        double('orders', get_orders: OpenStruct.new(orders: [active_sell]))
      )
      allow(client).to receive(:grpc_operations).and_return(
        double('ops', portfolio: OpenStruct.new(positions: [position]))
      )
      allow(client).to receive(:grpc_instruments)

      logic = double('logic')
      expect(logic).not_to receive(:should_sell?)
      expect(logic).not_to receive(:confirm_and_place_order_with_result)

      described_class.try_sell_positions_with_logic!(
        client, logic, 'acc', described_class.default_state, figi_cache: { 'F1' => 'AAA' }
      )
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
      orders = double('orders')
      allow(client).to receive(:grpc_operations).and_return(ops)
      allow(client).to receive(:grpc_instruments).and_return(instruments)
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      allow(ops).to receive(:portfolio).and_return(OpenStruct.new(positions: [position]))
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F1').and_return(OpenStruct.new(lot: 10, ticker: 'AAA'))

      logic = double('logic')
      allow(logic).to receive(:should_force_exit?).with(position, 'F1').and_return(true)
      allow(logic).to receive(:last_price_for).with('F1').and_return(150.0)
      captured = nil
      allow(logic).to receive(:confirm_and_place_order_with_result) do |**kw|
        captured = kw
        { ok: false, category: :sent_not_filled, response: OpenStruct.new(order_id: 'force-1') }
      end

      state = described_class.default_state
      described_class.try_force_exit_positions_with_logic!(
        client, logic, 'acc', state: state, figi_cache: { 'F1' => 'AAA' }
      )

      expect(captured[:figi]).to eq('F1')
      expect(captured[:quantity]).to eq(10)
      expect(state.fetch('last_sell').fetch('AAA').fetch('reason')).to eq('force_exit')
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
      orders = double('orders')
      allow(client).to receive(:grpc_operations).and_return(ops)
      allow(client).to receive(:grpc_instruments).and_return(instruments)
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: []))
      allow(ops).to receive(:portfolio).and_return(OpenStruct.new(positions: [position]))
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F1').and_raise(StandardError, 'lookup failed')

      logic = double('logic')
      allow(logic).to receive(:should_force_exit?).with(position, 'F1').and_return(true)
      expect(logic).not_to receive(:last_price_for)
      expect(logic).not_to receive(:confirm_and_place_order_with_result)

      described_class.try_force_exit_positions_with_logic!(
        client, logic, 'acc', figi_cache: { 'F1' => 'AAA' }
      )
    end

    it 'does not submit a duplicate force-exit while an active SELL exists' do
      position = OpenStruct.new(
        figi: 'F1', instrument_type: 'SHARE', quantity: OpenStruct.new(units: 100),
        average_position_price: q(100)
      )
      active_sell = OpenStruct.new(
        figi: 'F1', direction: 'ORDER_DIRECTION_SELL', order_id: 'active-sell',
        execution_report_status: 'EXECUTION_REPORT_STATUS_PARTIALLYFILL'
      )
      client = double('client')
      allow(client).to receive(:grpc_orders).and_return(
        double('orders', get_orders: OpenStruct.new(orders: [active_sell]))
      )
      allow(client).to receive(:grpc_operations).and_return(
        double('ops', portfolio: OpenStruct.new(positions: [position]))
      )
      allow(client).to receive(:grpc_instruments)

      logic = double('logic')
      allow(logic).to receive(:should_force_exit?).with(position, 'F1').and_return(true)
      expect(logic).not_to receive(:last_price_for)
      expect(logic).not_to receive(:confirm_and_place_order_with_result)

      described_class.try_force_exit_positions_with_logic!(
        client, logic, 'acc', figi_cache: { 'F1' => 'AAA' }
      )
    end

    it 'fails closed before reading the portfolio when active orders are unavailable' do
      client = double('client')
      orders = double('orders')
      operations = double('operations')
      allow(client).to receive(:grpc_orders).and_return(orders)
      allow(client).to receive(:grpc_operations).and_return(operations)
      allow(orders).to receive(:get_orders).with(account_id: 'acc').and_raise(StandardError, 'outage')
      expect(operations).not_to receive(:portfolio)

      logic = double('logic')
      expect(logic).not_to receive(:confirm_and_place_order_with_result)

      expect(
        described_class.try_force_exit_positions_with_logic!(client, logic, 'acc')
      ).to be false
    end
  end

  describe '.position_within_limit?' do
    def make_portfolio(total_shares:, positions: [])
      OpenStruct.new(total_amount_shares: q(total_shares), total_amount_currencies: q(10_000), positions: positions)
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

  # Ограничители downside: расширение универсума повышает частоту покупок,
  # поэтому нужны потолок дневных трат и запас кэша.
  describe '.daily_buy_within_limit?' do
    it 'is disabled when the limit is not set' do
      state = described_class.default_state
      expect(described_class.daily_buy_within_limit?(state, 1_000_000, max_daily_rub: 0)).to be true
    end

    it 'blocks a buy that would exceed the daily budget and counts executed buys' do
      state = described_class.default_state

      expect(described_class.daily_buy_within_limit?(state, 400, max_daily_rub: 1_000)).to be true
      described_class.register_daily_buy!(state, 400)
      expect(described_class.daily_buy_total(state)).to eq(400)

      expect(described_class.daily_buy_within_limit?(state, 500, max_daily_rub: 1_000)).to be true
      expect(described_class.daily_buy_within_limit?(state, 700, max_daily_rub: 1_000)).to be false
    end

    # Лимитная заявка исполняется асинхронно, поэтому бюджет занимаем при отправке.
    it 'treats an unfilled sent order as committed money' do
      expect(described_class.buy_committed_result?({ category: 'sent_not_filled' })).to be true
      expect(described_class.buy_committed_result?({ category: 'filled' })).to be true
      expect(described_class.buy_committed_result?({ category: 'rejected' })).to be_falsey
    end

    it 'keeps filled money and an unfilled order reservation separate' do
      state = described_class.default_state
      # total_order_amount у брокера — итоговая стоимость ЗАЯВКИ с комиссиями,
      # она положительна и когда не исполнено ни одного лота.
      response = OpenStruct.new(lots_requested: 2, lots_executed: 0, total_order_amount: q(201.2))

      described_class.account_buy_result!(
        state,
        'AAA',
        { category: :sent_not_filled, response: response, figi: 'F_AAA' },
        planned_value: 200
      )

      expect(described_class.daily_buy_total(state)).to eq(0)
      expect(described_class.pending_buy_reserved_total(state)).to eq(200)
      expect(described_class.daily_buy_committed_total(state)).to eq(200)
      expect(described_class.daily_buy_within_limit?(state, 800, max_daily_rub: 1_000)).to be true
      expect(described_class.daily_buy_within_limit?(state, 801, max_daily_rub: 1_000)).to be false
    end

    # Регрессия: раньше total_order_amount читался как исполненная сумма, поэтому
    # неисполненная заявка занимала бюджет дважды — и как filled, и как reserved.
    it 'ignores total_order_amount above planned when nothing is executed' do
      response = OpenStruct.new(lots_requested: 2, lots_executed: 0, total_order_amount: q(250))

      accounting = described_class.buy_result_accounting(
        { category: :sent_not_filled, response: response },
        planned_value: 200
      )

      expect(accounting[:filled_value]).to eq(0)
      expect(accounting[:reserved_value]).to eq(200)
      expect(accounting[:filled_value] + accounting[:reserved_value]).to eq(200)
    end

    it 'registers only the executed amount and reserves only the remainder after a partial fill' do
      state = described_class.default_state
      response = OpenStruct.new(lots_requested: 2, lots_executed: 1, total_order_amount: q(201.2))

      described_class.account_buy_result!(
        state,
        'AAA',
        { category: :partially_filled, response: response, figi: 'F_AAA' },
        planned_value: 200
      )

      pending = state.fetch('pending_orders').fetch('AAA')
      expect(described_class.daily_buy_total(state)).to eq(100)
      expect(pending.fetch('filled_value')).to eq(100)
      expect(pending.fetch('reserved_value')).to eq(100)
      expect(described_class.daily_buy_committed_total(state)).to eq(200)
    end

    it 'reads partial-fill accounting from the REST camelCase order payload' do
      response = {
        'lotsRequested' => 4,
        'lotsExecuted' => 3,
        'totalOrderAmount' => { 'units' => 201, 'nano' => 200_000_000 }
      }

      accounting = described_class.buy_result_accounting(
        { category: :partially_filled, response: response },
        planned_value: 200
      )

      expect(accounting[:filled_value]).to eq(150)
      expect(accounting[:reserved_value]).to eq(50)
    end

    # Регрессия: filled брался из total_order_amount, поэтому восстановленная из
    # брокера живая заявка получала reserved_value = 0 и не занимала бюджет вовсе.
    it 'reserves the unfilled remainder when restoring a live order from the broker' do
      order = OpenStruct.new(
        order_id: 'broker-restore',
        order_request_id: 'client-restore',
        figi: 'F_AAA',
        lots_requested: 4,
        lots_executed: 1,
        initial_order_price: q(200),
        total_order_amount: q(201.2)
      )

      payload = described_class.restored_pending_order_payload(order, 'AAA', 'partially_filled')

      expect(payload.fetch('planned_value')).to eq(200)
      expect(payload.fetch('filled_value')).to eq(50)
      expect(payload.fetch('reserved_value')).to eq(150)
    end

    it 'fails closed when a legacy active pending order has no reservation metadata' do
      state = described_class.default_state
      state['pending_orders']['AAA'] = { 'status' => 'sent_not_filled' }
      logger = double('logger', warn: nil)

      result = described_class.daily_buy_within_limit?(
        state, 100, max_daily_rub: 1_000, logger: logger
      )

      expect(result).to be false
      expect(logger).to have_received(:warn).with(include('unknown reservation'))
    end

    it 'keeps only recent days in state' do
      state = described_class.default_state
      state['daily_buys'] = (1..10).to_h { |i| ["2026-07-#{i.to_s.rjust(2, '0')}", 100.0] }
      described_class.register_daily_buy!(state, 50)

      expect(state['daily_buys'].size).to eq(7)
      expect(state['daily_buys']).to have_key(described_class.today_key)
    end
  end

  describe '.shares_share_within_limit?' do
    def portfolio_with_cash(shares:, cash:)
      OpenStruct.new(total_amount_shares: q(shares), total_amount_currencies: q(cash), positions: [])
    end

    it 'is disabled when max_share is not set' do
      port = portfolio_with_cash(shares: 10_000, cash: 0)
      expect(described_class.shares_share_within_limit?(nil, nil, portfolio: port, max_share: 0)).to be true
    end

    it 'blocks a buy that pushes the shares share above the cap' do
      port = portfolio_with_cash(shares: 6_000, cash: 4_000)

      expect(
        described_class.shares_share_within_limit?(nil, nil, portfolio: port, planned_buy_value: 500, max_share: 0.7)
      ).to be true
      expect(
        described_class.shares_share_within_limit?(nil, nil, portfolio: port, planned_buy_value: 1_500, max_share: 0.7)
      ).to be false
    end

    it 'falls back to shares+cash when total_amount_portfolio is absent' do
      port = portfolio_with_cash(shares: 1_000, cash: 1_000)
      expect(described_class.portfolio_total_amount(port)).to eq(2_000)
    end

    # Портфель читается один раз за проход, поэтому вызывающий обязан накапливать уже
    # занятые в этом проходе рубли — иначе две заявки подряд пройдут по одному снимку.
    it 'blocks the second buy of a run when accumulated value crosses the cap' do
      port = portfolio_with_cash(shares: 6_800, cash: 3_200)
      first = 150
      second = 150

      expect(
        described_class.shares_share_within_limit?(nil, nil, portfolio: port, planned_buy_value: first, max_share: 0.7)
      ).to be true
      expect(
        described_class.shares_share_within_limit?(
          nil, nil, portfolio: port, planned_buy_value: second + first, max_share: 0.7
        )
      ).to be false
    end

    # Гейт на общий риск счёта: «не смогли посчитать» не должно означать «разрешено».
    it 'fails closed when the portfolio cannot be read' do
      broken = double('client')
      allow(broken).to receive(:grpc_operations).and_raise(StandardError, 'boom')

      expect(described_class.shares_share_within_limit?(broken, 'acc', planned_buy_value: 100, max_share: 0.7)).to be false
    end

    it 'fails closed when the portfolio total is non-positive' do
      port = portfolio_with_cash(shares: 0, cash: 0)
      expect(
        described_class.shares_share_within_limit?(nil, nil, portfolio: port, planned_buy_value: 100, max_share: 0.7)
      ).to be false
    end
  end

  describe '.cash_sufficient_for_buy?' do
    it 'allows a buy only when available RUB covers the order and commission buffer' do
      positions = positions_snapshot(rub: 1_000)

      expect(
        described_class.cash_sufficient_for_buy?(
          nil, nil, positions: positions, planned_buy_value: 990, buffer_rate: 0.01
        )
      ).to be true
      expect(
        described_class.cash_sufficient_for_buy?(
          nil, nil, positions: positions, planned_buy_value: 995, buffer_rate: 0.01
        )
      ).to be false
    end

    it 'does not count foreign currency or RUB blocked by pending orders' do
      positions = positions_snapshot(rub: 1_000, blocked: 300)
      positions.money << OpenStruct.new(currency: 'usd', units: 100, nano: 0)

      expect(
        described_class.cash_sufficient_for_buy?(
          nil, nil, positions: positions, planned_buy_value: 700, buffer_rate: 0
        )
      ).to be true
      expect(
        described_class.cash_sufficient_for_buy?(
          nil, nil, positions: positions, planned_buy_value: 701, buffer_rate: 0
        )
      ).to be false
    end

    it 'parses the literal payload shape returned by the live REST GetPositions client' do
      positions = {
        'money' => [
          { 'currency' => 'rub', 'units' => '188', 'nano' => 350_000_000 },
          { 'currency' => 'usd', 'units' => '0', 'nano' => 100_000_000 }
        ],
        'blocked' => [],
        'limitsLoadingInProgress' => false
      }

      expect(described_class.available_currency_amount(positions, currency: 'rub')).to eq(188.35)
    end

    it 'fails closed while position limits are loading' do
      positions = positions_snapshot(rub: 1_000, loading: true)

      expect(
        described_class.cash_sufficient_for_buy?(
          nil, nil, positions: positions, planned_buy_value: 100, buffer_rate: 0
        )
      ).to be false
    end
  end
end
