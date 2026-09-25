# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/sell_order_recovery'
require 'json'
require 'ostruct'
require 'tmpdir'

RSpec.describe TradingLogic::SellOrderRecovery do
  let(:helpers) { TradingLogic::StrategyHelpers }
  let(:dir) { Dir.mktmpdir }
  let(:state_path) { File.join(dir, 'strategy_state.json') }
  let(:lock_path) { File.join(dir, 'current_strategy.lock') }

  after { FileUtils.remove_entry(dir) }

  def order_state(status, requested: 1, executed: 0)
    OpenStruct.new(success?: true, payload: {
                     'executionReportStatus' => "EXECUTION_REPORT_STATUS_#{status}",
                     'lotsRequested' => requested, 'lotsExecuted' => executed
                   })
  end

  def client(active_orders: [], order_states: {})
    client = double('client')
    allow(client).to receive(:grpc_orders).and_return(double('orders', get_orders: OpenStruct.new(orders: active_orders)))
    allow(client).to receive(:order_state) do |order_id:, **|
      response = order_states.fetch(order_id)
      raise response if response.is_a?(Exception)

      response
    end
    client
  end

  def place(state, order_id, ticker: 'AAA')
    result = { ok: false, category: :sent_not_filled, response: OpenStruct.new(order_id: order_id, lots_executed: 0) }
    helpers.register_sell_order!(state, ticker, figi: 'F1', result: result, lots: 1, reason: 'signal')
  end

  def write_state(yesterday_sale: nil)
    state = helpers.default_state
    state['last_sell']['AAA'] = yesterday_sale if yesterday_sale
    yield state
    helpers.save_state(state_path, state)
    File.read(state_path)
  end

  def recovery(broker)
    described_class.new(client: broker, account_id: 'acc', state_path: state_path, lock_path: lock_path)
  end

  it 'shows the broker-confirmed outcome as a diff and writes nothing by default' do
    before = write_state { |state| place(state, 'sell-1') }

    report = recovery(client(order_states: { 'sell-1' => order_state('CANCELLED') })).run

    expect(report).to include(ok: true, applied: false)
    expect(report[:orders]).to eq([{ key: 'sell-1', ticker: 'AAA', outcome: :cancelled }])
    expect(report[:changes].map { |c| [c[:section], c[:key], c[:after]] }).to contain_exactly(
      ['last_sell', 'AAA', nil], ['pending_sells', 'sell-1', nil]
    )
    expect(File.read(state_path)).to eq(before)
    expect(described_class.format(report)).to include('outcome=cancelled', 'last_sell[AAA]:', 'rerun with APPLY=1')
  end

  it 'applies the shared finalization, restoring history and relinking the other order' do
    yesterday = { 'figi' => 'F1', 'ts' => '2026-09-25T10:00:00Z', 'reason' => 'signal' }
    write_state(yesterday_sale: yesterday) do |state|
      place(state, 'old')
      place(state, 'new')
    end
    broker = client(active_orders: [OpenStruct.new(order_id: 'new', direction: 'ORDER_DIRECTION_SELL', figi: 'F1')],
                    order_states: { 'old' => order_state('CANCELLED') })

    report = recovery(broker).run(order_id: 'old', apply: true)

    expect(report).to include(ok: true, applied: true)
    saved = helpers.load_state(state_path)
    expect(saved['pending_sells'].keys).to eq(['new'])
    expect(saved['pending_sells']['new']['previous_last_sell']).to eq(yesterday)
    expect(saved['last_sell']['AAA']['order_id']).to eq('new')
  end

  it 'keeps history relinked earlier in the same pass when a later order stays unknown' do
    write_state do |state|
      place(state, 'old')
      place(state, 'new')
    end

    first = recovery(client(order_states: { 'old' => order_state('CANCELLED'),
                                            'new' => StandardError.new('unavailable') })).run(apply: true)

    expect(first[:orders].map { |o| o[:outcome] }).to eq(%i[cancelled unknown])
    saved = helpers.load_state(state_path)
    expect(saved['pending_sells']['new']).not_to have_key('previous_last_sell')
    expect(saved['pending_sells']['new']).not_to have_key('terminal_confirm_attempts')

    recovery(client(order_states: { 'new' => order_state('CANCELLED') })).run(apply: true)

    saved = helpers.load_state(state_path)
    expect(saved['pending_sells']).to be_empty
    expect(saved['last_sell']).not_to have_key('AAA')
    expect(helpers.state_last_sell_count_for_day(saved)).to eq(0)
  end

  it 'records a confirmed fill in last_sell and the sale ledger' do
    write_state { |state| place(state, 'sell-1') }

    recovery(client(order_states: { 'sell-1' => order_state('FILL') })).run(apply: true)

    saved = helpers.load_state(state_path)
    expect(saved['pending_sells']).to eq({})
    expect(saved['sell_orders']['sell-1']).to include('lots_executed' => 1, 'executed_at_source' => 'observed')
    expect(saved['last_sell']['AAA']).to include('lots_executed' => 1)
  end

  it 'changes nothing for an active order or an unconfirmed outcome, not even the attempt counter' do
    before = write_state do |state|
      place(state, 'active', ticker: 'AAA')
      place(state, 'unknown', ticker: 'BBB')
    end
    broker = client(active_orders: [OpenStruct.new(order_id: 'active', direction: 'ORDER_DIRECTION_SELL', figi: 'F1')],
                    order_states: { 'unknown' => StandardError.new('deadline exceeded') })

    report = recovery(broker).run(apply: true)

    expect(report[:orders].map { |o| o[:outcome] }).to eq(%i[active unknown])
    expect(report).to include(changes: [], applied: false)
    expect(File.read(state_path)).to eq(before)
  end

  it 'refuses when GetOrders is unavailable' do
    before = write_state { |state| place(state, 'sell-1') }
    broker = double('client')
    allow(broker).to receive(:grpc_orders).and_raise(StandardError, 'unavailable')

    report = recovery(broker).run(apply: true)

    expect(report).to eq(ok: false, reason: :active_orders_unavailable)
    expect(File.read(state_path)).to eq(before)
  end

  it 'refuses to apply while a strategy run holds the cron lock' do
    before = write_state { |state| place(state, 'sell-1') }
    broker = client(order_states: { 'sell-1' => order_state('CANCELLED') })

    File.open(lock_path, File::RDWR | File::CREAT) do |held|
      held.flock(File::LOCK_EX)
      report = recovery(broker).run(apply: true)
      expect(report).to eq(ok: false, reason: :strategy_running)
      expect(described_class.format(report)).to include('strategy run holds the lock')
    end
    expect(File.read(state_path)).to eq(before)
  end

  it 'reports when ORDER_ID matches no pending SELL' do
    write_state { |state| place(state, 'sell-1') }

    report = recovery(client).run(order_id: 'missing')

    expect(report).to include(ok: true, orders: [], changes: [])
    expect(described_class.format(report)).to include('no pending SELL orders matched')
  end
end
