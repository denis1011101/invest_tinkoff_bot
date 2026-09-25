# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/strategy_helpers'
require_relative '../lib/strategy_log_formatter'
require 'json'
require 'logger'
require 'ostruct'
require 'stringio'
require 'tmpdir'

RSpec.describe TradingLogic::StrategyHelpers do
  let(:log) { StringIO.new }
  let(:logger) do
    Logger.new(log).tap { |l| l.formatter = TradingLogic::StrategyLogFormatter.new }
  end
  let(:state) { described_class.default_state }

  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  def log_lines(pattern)
    log.string.lines.grep(pattern)
  end

  def order_state(status, requested: 1, executed: 0)
    OpenStruct.new(
      success?: true,
      payload: {
        'executionReportStatus' => "EXECUTION_REPORT_STATUS_#{status}",
        'lotsRequested' => requested,
        'lotsExecuted' => executed
      }
    )
  end

  def active_sell(order_id:, figi: 'F1', executed: 0, requested: 1, status: 'NEW', submitted_at: nil)
    OpenStruct.new(
      order_id: order_id, order_request_id: "client-#{order_id}", figi: figi,
      direction: 'ORDER_DIRECTION_SELL', execution_report_status: "EXECUTION_REPORT_STATUS_#{status}",
      lots_requested: requested, lots_executed: executed, order_date: submitted_at
    )
  end

  # GetOrders отдаёт active_orders; order_states — ответы GetOrderState по order_id
  # (значение-исключение имитирует сбой API); operations — операции для даты исполнения.
  def broker(active_orders: [], order_states: {}, operations: [])
    client = double('client')
    orders = double('orders')
    allow(client).to receive(:grpc_orders).and_return(orders)
    allow(client).to receive(:grpc_operations).and_return(
      double('ops', operations_by_cursor: OpenStruct.new(items: operations, has_next: false))
    )
    allow(orders).to receive(:get_orders).with(account_id: 'acc').and_return(OpenStruct.new(orders: active_orders))
    allow(client).to receive(:order_state) do |account_id:, order_id:|
      expect(account_id).to eq('acc')
      response = order_states.fetch(order_id) { raise KeyError, "unexpected order_state #{order_id}" }
      raise response if response.is_a?(Exception)

      response
    end
    client
  end

  def reconcile(client, now: Time.now.utc)
    described_class.reconcile_pending_sells!(client, 'acc', state, figi_cache: { 'F1' => 'AAA' }, logger: logger,
                                                                   now: now)
  end

  def place_sell(order_id: 'sell-1', lots: 1, category: :sent_not_filled, executed: 0, reason: 'signal')
    response = OpenStruct.new(order_id: order_id, lots_requested: lots, lots_executed: executed)
    result = { ok: category == :filled, category: category, response: response, client_order_id: "client-#{order_id}" }
    described_class.register_sell_order!(state, 'AAA', figi: 'F1', result: result, lots: lots, reason: reason,
                                                       logger: logger)
  end

  describe '.register_sell_order!' do
    it 'keeps an unfilled SELL pending under its broker order id and still blocks a same-day repeat' do
      place_sell

      expect(state['pending_sells'].keys).to eq(['sell-1'])
      expect(state['pending_sells']['sell-1']).to include(
        'ticker' => 'AAA', 'figi' => 'F1', 'reason' => 'signal', 'status' => 'sent_not_filled',
        'lots_requested' => 1, 'lots_executed' => 0, 'client_order_id' => 'client-sell-1'
      )
      expect(state['last_sell']['AAA']).to include('order_id' => 'sell-1', 'lots_requested' => 1, 'lots_executed' => 0)
      expect(described_class.acted_today?(state, 'last_sell', 'AAA')).to be true
    end

    it 'records an immediately filled SELL as executed without a pending entry' do
      place_sell(category: :filled)

      expect(state['pending_sells']).to eq({})
      expect(state['last_sell']['AAA']).to include('order_id' => 'sell-1', 'lots_executed' => 1)
    end

    it 'remembers the previous last_sell so a cancellation can restore it' do
      yesterday = { 'figi' => 'F1', 'ts' => '2026-09-14T15:45:14Z', 'reason' => 'signal' }
      state['last_sell']['AAA'] = yesterday

      place_sell

      expect(state['pending_sells']['sell-1']['previous_last_sell']).to eq(yesterday)
    end
  end

  describe '.reconcile_pending_sells!' do
    it 'clears last_sell after a confirmed cancellation with nothing executed, so the signal is re-evaluated' do
      place_sell
      client = broker(order_states: { 'sell-1' => order_state('CANCELLED') })

      reconcile(client)

      expect(state['pending_sells']).to eq({})
      expect(state['last_sell']).not_to have_key('AAA')
      expect(described_class.acted_today?(state, 'last_sell', 'AAA')).to be false
      expect(log_lines(/WARN: SELL CANCELLED AAA order_id=sell-1 status=EXECUTION_REPORT_STATUS_CANCELLED/).size).to eq(1)
    end

    it 'restores the previous last_sell entry instead of dropping history' do
      yesterday = { 'figi' => 'F1', 'ts' => '2026-09-14T15:45:14Z', 'reason' => 'signal' }
      state['last_sell']['AAA'] = yesterday
      place_sell

      reconcile(broker(order_states: { 'sell-1' => order_state('REJECTED') }))

      expect(state['last_sell']['AAA']).to eq(yesterday)
    end

    it 'keeps the sale and records the remainder when a cancelled order was partially executed' do
      place_sell(lots: 3, reason: 'force_exit')
      client = broker(order_states: { 'sell-1' => order_state('CANCELLED', requested: 3, executed: 1) })

      reconcile(client)

      expect(state['pending_sells']).to eq({})
      expect(state['last_sell']['AAA']).to include(
        'order_id' => 'sell-1', 'reason' => 'force_exit',
        'lots_requested' => 3, 'lots_executed' => 1, 'lots_remaining' => 2
      )
      expect(described_class.acted_today?(state, 'last_sell', 'AAA')).to be true
      expect(log_lines(%r{WARN: SELL PARTIAL AAA .* lots_executed=1/3 remaining=2}).size).to eq(1)
    end

    it 'finalizes a fully filled order as executed' do
      place_sell(lots: 2)

      reconcile(broker(order_states: { 'sell-1' => order_state('FILL', requested: 2, executed: 2) }))

      expect(state['pending_sells']).to eq({})
      expect(state['last_sell']['AAA']).to include('lots_executed' => 2)
      expect(log_lines(/INFO: SELL executed AAA/).size).to eq(1)
    end

    it 'tracks progress of an active order and does not query its terminal status' do
      place_sell(lots: 3)
      client = broker(active_orders: [active_sell(order_id: 'sell-1', requested: 3, executed: 2, status: 'PARTIALLYFILL')])

      reconcile(client)

      expect(client).not_to have_received(:order_state)
      expect(state['pending_sells']['sell-1']).to include('lots_executed' => 2, 'status' => 'partially_filled')
      expect(state['last_sell']['AAA']['lots_executed']).to eq(2)
    end

    it 'warns once when a SELL stays active longer than SELL_PENDING_ALERT_MIN' do
      place_sell
      state['pending_sells']['sell-1']['ts'] = '2026-09-15T10:45:09Z'
      client = broker(active_orders: [active_sell(order_id: 'sell-1')])

      reconcile(client, now: Time.utc(2026, 9, 15, 11, 30))
      reconcile(client, now: Time.utc(2026, 9, 15, 11, 50))
      reconcile(client, now: Time.utc(2026, 9, 15, 20, 50))

      expect(log_lines(/WARN: SELL PENDING LONG AAA order_id=sell-1 age_min=65 /).size).to eq(1)
      expect(log_lines(/SELL PENDING LONG/).size).to eq(1)
    end

    context 'when the outcome is not confirmed' do
      it 'does not treat a vanished order as cancelled while GetOrderState still reports it live' do
        place_sell

        reconcile(broker(order_states: { 'sell-1' => order_state('NEW') }))

        expect(state['pending_sells']).to have_key('sell-1')
        expect(described_class.acted_today?(state, 'last_sell', 'AAA')).to be true
      end

      it 'keeps everything when GetOrderState fails or answers unsuccessfully' do
        place_sell(order_id: 'sell-1')
        place_sell(order_id: 'sell-2')
        client = broker(order_states: {
                          'sell-1' => StandardError.new('deadline exceeded'),
                          'sell-2' => OpenStruct.new(success?: false)
                        })

        reconcile(client)

        expect(state['pending_sells'].keys).to contain_exactly('sell-1', 'sell-2')
        expect(state['last_sell']['AAA']['order_id']).to eq('sell-2')
      end

      it 'does nothing at all when active orders are unavailable' do
        place_sell
        client = double('client')
        orders = double('orders')
        allow(client).to receive(:grpc_orders).and_return(orders)
        allow(orders).to receive(:get_orders).and_raise(StandardError, 'unavailable')
        allow(client).to receive(:order_state)

        expect(reconcile(client)).to be false

        expect(client).not_to have_received(:order_state)
        expect(state['pending_sells']).to have_key('sell-1')
        expect(log_lines(/WARN: SELL reconciliation skipped/).size).to eq(1)
      end

      it 'raises one ERROR after SELL_TERMINAL_MAX_ATTEMPTS unconfirmed lookups, not one per run' do
        place_sell
        client = broker(order_states: { 'sell-1' => StandardError.new('boom') })

        7.times { reconcile(client) }

        expect(log_lines(/ERROR: SELL PENDING STUCK AAA order_id=sell-1 terminal_confirm_attempts=5/).size).to eq(1)
        expect(log_lines(/ERROR:/).size).to eq(1)
        expect(state['pending_sells']).to have_key('sell-1')
      end
    end

    it 'honours SELL_TERMINAL_MAX_ATTEMPTS for the stuck alert' do
      place_sell
      client = broker(order_states: { 'sell-1' => StandardError.new('boom') })

      with_env('SELL_TERMINAL_MAX_ATTEMPTS' => '2') { 2.times { reconcile(client) } }

      expect(log_lines(/ERROR: SELL PENDING STUCK AAA order_id=sell-1 terminal_confirm_attempts=2/).size).to eq(1)
    end

    it 'leaves last_sell alone when it already belongs to a newer order' do
      place_sell(order_id: 'old')
      place_sell(order_id: 'new')

      reconcile(broker(active_orders: [active_sell(order_id: 'new')],
                       order_states: { 'old' => order_state('CANCELLED') }))

      expect(state['pending_sells'].keys).to eq(['new'])
      expect(state['last_sell']['AAA']['order_id']).to eq('new')
    end

    it 'survives a restart: pending SELLs are persisted and resolved by the next process' do
      place_sell
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'strategy_state.json')
        described_class.save_state(path, state)
        reloaded = described_class.load_state(path)

        described_class.reconcile_pending_sells!(
          broker(order_states: { 'sell-1' => order_state('CANCELLED') }), 'acc', reloaded, logger: logger
        )

        expect(reloaded['pending_sells']).to eq({})
        expect(reloaded['last_sell']).not_to have_key('AAA')
      end
    end

    it 'adopts an active broker SELL unknown to a lost state and resolves it later' do
      submitted = Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 9, 15, 10, 45).to_i) if defined?(Google::Protobuf)
      order = active_sell(order_id: 'orphan', requested: 2, submitted_at: submitted || Time.utc(2026, 9, 15, 10, 45))

      reconcile(broker(active_orders: [order]))

      expect(state['pending_sells']['orphan']).to include(
        'ticker' => 'AAA', 'reason' => 'broker_restore', 'lots_requested' => 2, 'ts' => '2026-09-15T10:45:00Z'
      )
      expect(state['last_sell']['AAA']).to include('order_id' => 'orphan', 'reason' => 'broker_restore')
      expect(log_lines(/INFO: SELL order adopted from broker AAA order_id=orphan/).size).to eq(1)

      reconcile(broker(active_orders: [order]))
      expect(log_lines(/adopted from broker/).size).to eq(1)

      reconcile(broker(order_states: { 'orphan' => order_state('CANCELLED', requested: 2) }))
      expect(state['last_sell']).not_to have_key('AAA')
    end
  end

  describe 'two orders on one instrument' do
    it 'does not resurrect an already cancelled order when the newer one is cancelled too' do
      place_sell(order_id: 'old')
      place_sell(order_id: 'new')

      reconcile(broker(order_states: { 'old' => order_state('CANCELLED'), 'new' => order_state('CANCELLED') }))

      expect(state['pending_sells']).to be_empty
      expect(state['last_sell']).not_to have_key('AAA')
      expect(described_class.state_last_sell_count_for_day(state)).to eq(0)
    end

    it 'ends with no sale whichever of the two cancellations is seen first' do
      place_sell(order_id: 'old')
      place_sell(order_id: 'new')

      reconcile(broker(active_orders: [active_sell(order_id: 'old')], order_states: { 'new' => order_state('CANCELLED') }))
      expect(state['last_sell']['AAA']['order_id']).to eq('old')

      reconcile(broker(order_states: { 'old' => order_state('CANCELLED') }))
      expect(state['last_sell']).not_to have_key('AAA')
    end

    it 'falls back to the executed older order, with its outcome, when the newer one is cancelled' do
      place_sell(order_id: 'old', lots: 2)
      place_sell(order_id: 'new')

      reconcile(broker(active_orders: [active_sell(order_id: 'new')],
                       order_states: { 'old' => order_state('FILL', requested: 2, executed: 2) }))
      reconcile(broker(order_states: { 'new' => order_state('CANCELLED') }))

      expect(state['last_sell']['AAA']).to include('order_id' => 'old', 'lots_executed' => 2)
      expect(state['last_sell']['AAA']).to have_key('executed_at')
    end
  end

  describe 'blocking a new SELL while an earlier outcome is unknown' do
    def blocked_run(force:)
      position = OpenStruct.new(figi: 'F1', instrument_type: 'SHARE', quantity: OpenStruct.new(units: 3))
      client = broker(order_states: { 'sell-1' => order_state('NEW') })
      instruments = double('instruments')
      allow(client).to receive_messages(grpc_operations: double('ops', portfolio: OpenStruct.new(positions: [position])),
                                        grpc_instruments: instruments)
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F1').and_return(OpenStruct.new(lot: 1))
      allow(described_class).to receive(:sell_session_open?).and_return(true)
      logic = double('logic', should_force_exit?: true, should_sell?: true, last_price_for: 700.0)
      allow(logic).to receive(:confirm_and_place_order_with_result)

      reconcile(client)
      expect(state['pending_sells']).to have_key('sell-1')
      if force
        described_class.try_force_exit_positions_with_logic!(client, logic, 'acc', state: state,
                                                                                   figi_cache: { 'F1' => 'AAA' }, logger: logger)
      else
        described_class.try_sell_positions_with_logic!(client, logic, 'acc', state, figi_cache: { 'F1' => 'AAA' },
                                                                                    logger: logger)
      end
      expect(logic).not_to have_received(:confirm_and_place_order_with_result)
    end

    it 'blocks force exit, which never looks at last_sell' do
      place_sell

      blocked_run(force: true)
    end

    it 'blocks the signal SELL on the next day as well' do
      current = Time.now.utc
      allow(Time).to receive(:now).and_return(current - 86_400)
      place_sell
      allow(Time).to receive(:now).and_return(current)

      blocked_run(force: false)
    end
  end

  describe 'execution day' do
    let(:today) { Time.now.utc }
    let(:yesterday) { today - 86_400 }

    def place_yesterday
      allow(Time).to receive(:now).and_return(yesterday)
      place_sell
      allow(Time).to receive(:now).and_return(today)
    end

    def filled_with_stage(time)
      state = order_state('FILL')
      state.payload['stages'] = [{ 'executionTime' => time.iso8601 }]
      state
    end

    it 'counts a previous-day order filled today as a sale today' do
      place_yesterday

      reconcile(broker(order_states: { 'sell-1' => order_state('FILL') }), now: today)

      expect(described_class.acted_today?(state, 'last_sell', 'AAA')).to be true
      expect(described_class.state_last_sell_count_for_day(state)).to eq(1)
      expect(state['last_sell']['AAA']).to include('executed_at_source' => 'observed')
    end

    it 'takes the execution time from the order trades when the broker reports them' do
      place_yesterday

      reconcile(broker(order_states: { 'sell-1' => filled_with_stage(yesterday + 60) }), now: today)

      expect(state['last_sell']['AAA']).to include('executed_at' => (yesterday + 60).utc.iso8601,
                                                   'executed_at_source' => 'order_stages')
      expect(described_class.acted_today?(state, 'last_sell', 'AAA')).to be false
      expect(described_class.state_last_sell_count_for_day(state)).to eq(0)
    end

    it 'dates a partial fill seen on an active order today, even without stages' do
      place_yesterday
      partial = active_sell(order_id: 'sell-1', requested: 3, executed: 1, status: 'PARTIALLYFILL')

      reconcile(broker(active_orders: [partial]), now: today)

      expect(state['last_sell']['AAA']).to include('executed_at' => today.iso8601, 'executed_at_source' => 'observed')
      expect(described_class.state_last_sell_count_for_day(state)).to eq(1)
    end

    it 'keeps a known execution time when the remainder is cancelled without new fills' do
      allow(Time).to receive(:now).and_return(yesterday)
      place_sell(lots: 3)
      partial = active_sell(order_id: 'sell-1', requested: 3, executed: 1, status: 'PARTIALLYFILL')
      partial.stages = [{ 'executionTime' => yesterday.iso8601 }]
      reconcile(broker(active_orders: [partial]), now: yesterday)
      allow(Time).to receive(:now).and_return(today)

      reconcile(broker(order_states: { 'sell-1' => order_state('CANCELLED', requested: 3, executed: 1) }), now: today)

      expect(state['last_sell']['AAA']).to include('executed_at' => yesterday.utc.iso8601,
                                                   'executed_at_source' => 'order_stages', 'lots_remaining' => 2)
      expect(described_class.acted_today?(state, 'last_sell', 'AAA')).to be false
    end

    it 'dates a partial fill already reported by PostOrder at submission' do
      place_sell(lots: 3, executed: 1)

      expect(state['pending_sells']['sell-1']).to include('executed_at_source' => 'order_response')
      expect(state['last_sell']['AAA']).to include('executed_at_source' => 'order_response')
    end

    it 'falls back to the SELL operation time for the instrument' do
      place_yesterday
      operations = [
        OpenStruct.new(type: 'OPERATION_TYPE_SELL', figi: 'OTHER', quantity_done: 1, date: (today - 30).iso8601),
        OpenStruct.new(type: 'OPERATION_TYPE_SELL', figi: 'F1', quantity_done: 1, date: (today - 600).iso8601)
      ]

      reconcile(broker(order_states: { 'sell-1' => order_state('FILL') }, operations: operations), now: today)

      expect(state['last_sell']['AAA']).to include('executed_at' => (today - 600).utc.iso8601,
                                                   'executed_at_source' => 'operations')
    end
  end

  describe 'binding an operation to the order' do
    let(:submitted) { Time.utc(2026, 9, 26, 0, 0, 30) }
    let(:observed) { Time.utc(2026, 9, 26, 0, 5) }

    def sell_op(time, figi: 'F1')
      OpenStruct.new(type: 'OPERATION_TYPE_SELL', figi: figi, quantity_done: 1, date: time.iso8601)
    end

    def fill_with(operations)
      allow(Time).to receive(:now).and_return(submitted)
      place_sell
      allow(Time).to receive(:now).and_return(observed)
      reconcile(broker(order_states: { 'sell-1' => order_state('FILL') }, operations: operations), now: observed)
      state['last_sell']['AAA']
    end

    it 'ignores a sale of the same instrument executed before the order was submitted' do
      entry = fill_with([sell_op(Time.utc(2026, 9, 25, 23, 59, 30))])

      expect(entry).to include('executed_at' => observed.iso8601, 'executed_at_source' => 'observed')
      expect(described_class.state_last_sell_count_for_day(state, day: '2026-09-25')).to eq(0)
    end

    it 'uses the only matching operation after submission' do
      entry = fill_with([sell_op(submitted + 60)])

      expect(entry).to include('executed_at' => (submitted + 60).iso8601, 'executed_at_source' => 'operations')
    end

    it 'falls back to observed when two sales of the instrument could be this order' do
      entry = fill_with([sell_op(submitted + 60), sell_op(submitted + 120)])

      expect(entry).to include('executed_at' => observed.iso8601, 'executed_at_source' => 'observed')
    end
  end

  describe '.check_sell_consistency!' do
    def broker_with_sells(count)
      ops = double('ops')
      client = double('client', grpc_operations: ops)
      items = Array.new(count) { OpenStruct.new(type: 'OPERATION_TYPE_SELL') }
      allow(ops).to receive(:operations_by_cursor).and_return(OpenStruct.new(items: items))
      client
    end

    it 'does not count a pending SELL without executed lots as a sale' do
      place_sell

      described_class.check_sell_consistency!(broker_with_sells(0), 'acc', state, logger: logger)

      expect(log_lines(/mismatch/)).to be_empty
    end

    it 'raises one ERROR only when the mismatch persists, then reports recovery' do
      place_sell(category: :filled)
      client = broker_with_sells(0)
      start = Time.now.utc

      described_class.check_sell_consistency!(client, 'acc', state, logger: logger, now: start)
      described_class.check_sell_consistency!(client, 'acc', state, logger: logger, now: start + (29 * 60))
      expect(log_lines(/ERROR:/)).to be_empty

      described_class.check_sell_consistency!(client, 'acc', state, logger: logger, now: start + (31 * 60))
      described_class.check_sell_consistency!(client, 'acc', state, logger: logger, now: start + (120 * 60))
      expect(log_lines(/ERROR: sell consistency mismatch broker=0 state_last_sell=1 age_min=31.0/).size).to eq(1)
      expect(log_lines(/ERROR:/).size).to eq(1)

      described_class.check_sell_consistency!(broker_with_sells(1), 'acc', state, logger: logger, now: start + (125 * 60))
      expect(log_lines(/INFO: sell consistency restored broker=1 state_last_sell=1/).size).to eq(1)
      expect(state).not_to have_key('sell_consistency')
    end
  end

  describe 'SELL paths' do
    def sell_client(position)
      client = double('client')
      ops = double('ops', portfolio: OpenStruct.new(positions: [position]))
      orders = double('orders', get_orders: OpenStruct.new(orders: []))
      instruments = double('instruments')
      allow(client).to receive_messages(grpc_operations: ops, grpc_orders: orders, grpc_instruments: instruments,
                                        trading_schedules: nil)
      allow(instruments).to receive(:get_instrument_by).with(:figi, 'F1').and_return(OpenStruct.new(lot: 1))
      client
    end

    def unfilled(order_id)
      { ok: false, category: :sent_not_filled, response: OpenStruct.new(order_id: order_id, lots_executed: 0) }
    end

    it 'places a new signal SELL the same day once the previous one is confirmed cancelled' do
      position = OpenStruct.new(figi: 'F1', instrument_type: 'SHARE', quantity: OpenStruct.new(units: 5))
      client = sell_client(position)
      allow(described_class).to receive(:sell_session_open?).and_return(true)
      logic = double('logic', should_sell?: true, last_price_for: 671.6)
      allow(logic).to receive(:confirm_and_place_order_with_result).and_return(unfilled('sell-1'), unfilled('sell-2'))
      run = lambda do
        described_class.try_sell_positions_with_logic!(client, logic, 'acc', state, figi_cache: { 'F1' => 'AAA' },
                                                                                    logger: logger)
      end

      run.call
      run.call
      expect(logic).to have_received(:confirm_and_place_order_with_result).once

      allow(client).to receive(:order_state).and_return(order_state('CANCELLED'))
      reconcile(client)
      run.call

      expect(logic).to have_received(:confirm_and_place_order_with_result).twice
      expect(state['pending_sells'].keys).to eq(['sell-2'])
    end

    it 'tracks a force exit SELL with its reason and full lot count' do
      position = OpenStruct.new(figi: 'F1', instrument_type: 'SHARE', quantity: OpenStruct.new(units: 3))
      client = sell_client(position)
      allow(described_class).to receive(:sell_session_open?).and_return(true)
      logic = double('logic', should_force_exit?: true, last_price_for: 700.0)
      allow(logic).to receive(:confirm_and_place_order_with_result).and_return(unfilled('force-1'))

      described_class.try_force_exit_positions_with_logic!(client, logic, 'acc', state: state,
                                                                                 figi_cache: { 'F1' => 'AAA' }, logger: logger)

      expect(state['pending_sells']['force-1']).to include('reason' => 'force_exit', 'lots_requested' => 3)
    end
  end
end
