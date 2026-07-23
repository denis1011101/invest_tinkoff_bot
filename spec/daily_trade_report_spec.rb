# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/daily_trade_report'
require_relative '../lib/daily_report_delivery'
require 'tmpdir'

# Лёгкие протобаф-подобные заглушки.
def q(value)
  units = value.to_i
  nano = ((value - units) * 1_000_000_000).round
  OpenStruct.new(units: units, nano: nano)
end

def ts(time)
  OpenStruct.new(seconds: time.to_i)
end

def op(type:, figi: 'F', name: 'N', payment: 0.0, price: 0.0, qty: 0, state: 'OPERATION_STATE_EXECUTED', at: Time.utc(2026, 7, 23, 10))
  OpenStruct.new(type: type, figi: figi, name: name, payment: q(payment), price: q(price),
                 quantity_done: qty, state: state, date: ts(at))
end

def page(items, has_next: false, next_cursor: '')
  OpenStruct.new(items: items, has_next: has_next, next_cursor: next_cursor)
end

def candle(date_utc, close:, high: nil, low: nil)
  OpenStruct.new(time: ts(date_utc), close: q(close), high: q(high || close), low: q(low || close))
end

RSpec.describe TradingLogic::DailyTradeReport do
  let(:client) { double('client') }
  let(:operations) { double('operations') }
  let(:instruments) { double('instruments') }
  let(:market_data) { double('market_data') }
  let(:users) { double('users') }
  # Отчёт за 2026-07-23, cutoff 21:00 +05:00 → окно [22.07 16:00 UTC, 23.07 16:00 UTC)
  let(:now) { Time.utc(2026, 7, 23, 16, 5) }

  before do
    allow(client).to receive_messages(grpc_operations: operations, grpc_instruments: instruments,
                                      grpc_market_data: market_data, grpc_users: users)
    allow(users).to receive(:accounts).and_return(OpenStruct.new(accounts: [OpenStruct.new(id: 'ACC')]))
    allow(instruments).to receive(:indicatives).and_return([OpenStruct.new(ticker: 'IMOEX', uid: 'IDX')])
    allow(instruments).to receive(:get_instrument_by).and_return(nil)
    allow(operations).to receive(:portfolio).and_return(OpenStruct.new(daily_yield: q(-18.42), daily_yield_relative: q(-0.37)))
    # индекс: предыдущее закрытие 22.07, текущее (неполное) 23.07
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: [
                                                                        candle(Time.utc(2026, 7, 22), close: 2121.76),
                                                                        candle(Time.utc(2026, 7, 23), close: 2134.28, high: 2145.10, low: 2108.40)
                                                                      ]))
  end

  def report
    described_class.new(client: client, now: now, market_cache_path: nil)
  end

  it 'aggregates buys and sells only from executed trades, ignoring canceled/progress' do
    allow(operations).to receive(:operations_by_cursor).and_return(page([
                                                                          op(type: 'OPERATION_TYPE_BUY', figi: 'RUAL', payment: -227.85,
                                                                             price: 22.79, qty: 10),
                                                                          op(type: 'OPERATION_TYPE_SELL', figi: 'SBER', payment: 263.0, price: 263.0,
                                                                             qty: 1),
                                                                          op(type: 'OPERATION_TYPE_BUY', figi: 'X', payment: -1.0,
                                                                             state: 'OPERATION_STATE_PROGRESS'),
                                                                          op(type: 'OPERATION_TYPE_SELL', figi: 'Y', payment: -1.0,
                                                                             state: 'OPERATION_STATE_CANCELED')
                                                                        ]))
    agg = report.build[:aggregates]
    expect(agg[:buys_count]).to eq(1)
    expect(agg[:sells_count]).to eq(1)
    expect(agg[:buy_turnover]).to eq(227.85)
    expect(agg[:sell_turnover]).to eq(263.0)
  end

  it 'follows pagination across two pages, terminating on has_next=false' do
    pages = [
      page([op(type: 'OPERATION_TYPE_BUY', figi: 'A', payment: -10)], has_next: true, next_cursor: 'c1'),
      page([op(type: 'OPERATION_TYPE_BUY', figi: 'B', payment: -20)], has_next: false)
    ]
    call = 0
    allow(operations).to receive(:operations_by_cursor) { pages[call].tap { call += 1 } }
    agg = report.build[:aggregates]
    expect(agg[:buys_count]).to eq(2)
    expect(call).to eq(2)
  end

  it 'raises instead of silently truncating when has_next set but cursor repeats' do
    pages = [
      page([op(type: 'OPERATION_TYPE_BUY', figi: 'A', payment: -10)], has_next: true, next_cursor: 'c1'),
      page([op(type: 'OPERATION_TYPE_BUY', figi: 'B', payment: -20)], has_next: true, next_cursor: 'c1')
    ]
    call = 0
    allow(operations).to receive(:operations_by_cursor) { pages[call].tap { call += 1 } }
    expect { report.build }.to raise_error(described_class::BrokerError, /pagination anomaly/)
  end

  it 'sums broker-fee operations and does not double count' do
    allow(operations).to receive(:operations_by_cursor).and_return(page([
                                                                          op(type: 'OPERATION_TYPE_BUY', figi: 'A', payment: -100),
                                                                          op(type: 'OPERATION_TYPE_BROKER_FEE', figi: 'A', payment: -0.68),
                                                                          op(type: 'OPERATION_TYPE_BROKER_FEE', figi: 'A', payment: -1.39)
                                                                        ]))
    expect(report.build[:aggregates][:fees]).to eq(2.07)
  end

  it 'reports no trades cleanly' do
    allow(operations).to receive(:operations_by_cursor).and_return(page([]))
    result = report.build
    expect(result[:aggregates][:buys_count]).to eq(0)
    expect(result[:text]).to include('Сделок сегодня не было.')
  end

  it 'uses the incomplete current candle as value and previous as baseline (up)' do
    allow(operations).to receive(:operations_by_cursor).and_return(page([]))
    idx = report.build[:index]
    expect(idx[:current]).to eq(2134.28)
    expect(idx[:previous]).to eq(2121.76)
    expect(idx[:delta_points]).to eq(12.52)
    expect(report.build[:text]).to include('▲ вырос на 12.52 п. (+0.59%)')
  end

  it 'formats a down move' do
    allow(operations).to receive(:operations_by_cursor).and_return(page([]))
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: [
                                                                        candle(Time.utc(2026, 7, 22), close: 2140.0),
                                                                        candle(Time.utc(2026, 7, 23), close: 2121.66)
                                                                      ]))
    expect(report.build[:text]).to include('▼ упал на 18.34 п.')
  end

  it 'formats a flat move' do
    allow(operations).to receive(:operations_by_cursor).and_return(page([]))
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: [
                                                                        candle(Time.utc(2026, 7, 22), close: 2100.0),
                                                                        candle(Time.utc(2026, 7, 23), close: 2100.0)
                                                                      ]))
    expect(report.build[:text]).to include('без изменений')
  end

  it 'handles missing index data without faking yesterday' do
    allow(operations).to receive(:operations_by_cursor).and_return(page([]))
    allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: [candle(Time.utc(2026, 7, 22), close: 2100.0)]))
    expect(report.build[:text]).to include('данные временно недоступны')
  end

  it 'raises BrokerError instead of pretending 0 trades on operations failure' do
    allow(operations).to receive(:operations_by_cursor).and_raise(StandardError, 'boom')
    expect { report.build }.to raise_error(described_class::BrokerError, /boom/)
  end

  it 'omits the portfolio block for a historical REPORT_DAY (avoids mislabeled today yield)' do
    allow(operations).to receive(:operations_by_cursor).and_return(page([]))
    text = described_class.new(client: client, now: now, market_cache_path: nil).build('2026-07-20')[:text]
    expect(text).not_to include('Портфель')
  end

  it 'respects the +05:00 window boundaries' do
    captured = nil
    allow(operations).to receive(:operations_by_cursor) do |args|
      captured = args
      page([])
    end
    report.build
    expect(captured[:from]).to eq(Time.utc(2026, 7, 22, 16, 0))
    expect(captured[:to]).to eq(Time.utc(2026, 7, 23, 16, 0))
  end
end

RSpec.describe TradingLogic::DailyReportDelivery do
  let(:sent) { [] }
  let(:sender) do
    lambda { |bot_token:, chat_id:, text:|
      _ = [bot_token, chat_id]
      sent << text
      true
    }
  end

  def delivery(dir)
    described_class.new(state_path: File.join(dir, 'state.json'),
                        archive_dir: File.join(dir, 'reports'), sender: sender)
  end

  def result(day: '2026-07-23', text: 'hello')
    { day: day, text: text,
      aggregates: { buys_count: 1, sells_count: 0, buy_turnover: 10.0, sell_turnover: 0.0, fees: 0.1, realized: 0.0 },
      index: { ok: true, current: 2134.28, delta_points: 12.52, delta_percent: 0.59 },
      portfolio: { ok: false } }
  end

  it 'dry-run prints and does not change state or archive' do
    Dir.mktmpdir do |dir|
      d = delivery(dir)
      expect { d.deliver(result, bot_token: 'B', chat_id: 'C', dry_run: true) }.to output(/hello/).to_stdout
      expect(sent).to be_empty
      expect(File).not_to exist(File.join(dir, 'state.json'))
    end
  end

  it 'blocks a duplicate send for the same day, force overrides' do
    Dir.mktmpdir do |dir|
      d = delivery(dir)
      expect(d.deliver(result, bot_token: 'B', chat_id: 'C')).to be true
      expect(d.deliver(result, bot_token: 'B', chat_id: 'C')).to be true # dedup, no new send
      expect(sent.size).to eq(1)
      expect(d.deliver(result, bot_token: 'B', chat_id: 'C', force: true)).to be true
      expect(sent.size).to eq(2)
    end
  end

  it 'archives text and jsonl after a successful send' do
    Dir.mktmpdir do |dir|
      delivery(dir).deliver(result, bot_token: 'B', chat_id: 'C')
      txt = File.read(File.join(dir, 'reports', '2026-07.txt'))
      jsonl = File.read(File.join(dir, 'reports', '2026-07.jsonl'))
      expect(txt).to include('hello')
      expect(JSON.parse(jsonl)['buys']).to eq(1)
    end
  end

  it 'splits a long message into chunks and sends all parts' do
    Dir.mktmpdir do |dir|
      long = (['line'] * 2000).join("\n")
      d = delivery(dir)
      expect(d.deliver(result(text: long), bot_token: 'B', chat_id: 'C')).to be true
      expect(sent.size).to be > 1
    end
  end

  it 'sends a service message (no aggregates) without touching state or archive' do
    Dir.mktmpdir do |dir|
      d = delivery(dir)
      expect(d.deliver({ day: 'error', text: 'oops' }, bot_token: 'B', chat_id: 'C', force: true)).to be true
      expect(sent).to eq(['oops'])
      expect(File).not_to exist(File.join(dir, 'state.json'))
      expect(Dir).not_to exist(File.join(dir, 'reports'))
    end
  end

  it 'hard-splits a single over-limit line into multiple parts' do
    Dir.mktmpdir do |dir|
      d = delivery(dir)
      giant = 'x' * ((TradingLogic::DailyReportDelivery::CHUNK_LIMIT * 2) + 10)
      parts = d.chunk(giant)
      expect(parts.size).to be >= 3
      expect(parts.map(&:length).max).to be <= TradingLogic::DailyReportDelivery::CHUNK_LIMIT
    end
  end

  it 'marks day sent only after all parts succeed' do
    Dir.mktmpdir do |dir|
      flaky = ->(**) { false }
      d = described_class.new(state_path: File.join(dir, 's.json'), archive_dir: File.join(dir, 'r'), sender: flaky)
      expect(d.deliver(result, bot_token: 'B', chat_id: 'C')).to be false
      expect(d.already_sent?('2026-07-23')).to be false
    end
  end
end
