# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/strategy_log_summary'
require_relative '../lib/strategy_helpers'
require_relative '../lib/strategy_log_formatter'
require 'logger'
require 'stringio'
require 'tmpdir'

RSpec.describe TradingLogic::StrategyLogSummary do
  let(:from) { Time.utc(2026, 9, 3, 16) }
  let(:to) { Time.utc(2026, 9, 4, 16) }
  let(:unknown) { 'proceeding with unknown session — trading_session reason=schedule_unavailable exchange=MOEX' }
  let(:unresolved) { 'skipped — reason=instrument_unresolved figi=BBG008F2T3T2 lot=nil' }

  def summarize(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'current_strategy.log')
      File.write(path, contents)
      described_class.new(path: path).build(from: from, to: to)
    end
  end

  it 'counts both SELL paths in the half-open window, grouping unresolved instruments by FIGI' do
    result = summarize(<<~LOG)
      #{(from - 1).iso8601} WARN: SELL AFLT #{unknown}
      #{from.iso8601} WARN: SELL AFLT #{unknown}
      2026-09-04T20:59:59+05:00 WARN: FORCE SELL AFLT #{unknown}
      #{to.iso8601} WARN: SELL AFLT #{unknown}
      #{from.iso8601} WARN: SELL RUAL #{unresolved}
      #{from.iso8601} WARN: FORCE SELL RUAL #{unresolved}
      #{from.iso8601} WARN: SELL AAA skipped — reason=instrument_unresolved figi=F2 lot=nil
      #{to.iso8601} WARN: SELL RUAL #{unresolved}
      #{from.iso8601} WARN: SELL RUAL skipped — reason=invalid_lot figi=BBG008F2T3T2 lot=0
      #{from.iso8601} WARN: FORCE SELL RUAL skipped — reason=invalid_lot figi=BBG008F2T3T2 lot=nil
      #{to.iso8601} WARN: SELL RUAL skipped — reason=invalid_lot figi=BBG008F2T3T2 lot=-1
    LOG

    expect(result).to eq(ok: true, unknown_session_count: 2, instrument_unresolved: { 'BBG008F2T3T2' => 2, 'F2' => 1 },
                         invalid_lot: { 'BBG008F2T3T2' => 2 })
    text = described_class.format(result).join("\n")
    expect(text).to include('Предупреждения SELL о неизвестной сессии за 24ч: 2.', 'Пропусков за 24ч: 3.', 'BBG008F2T3T2: 2',
                            'SELL: некорректный лот. Пропусков за 24ч: 2.')
  end

  it 'ignores unrelated messages, other severities and malformed timestamps' do
    result = summarize(<<~LOG)
      #{from.iso8601} DEBUG: SELL AFLT #{unknown}
      #{from.iso8601} WARN: BUY AFLT #{unknown}
      #{from.iso8601} WARN: TradingSchedules failed for exchange=MOEX: outage
      #{from.iso8601} DEBUG: SELL AFLT skipped — trading_session reason=session_closed exchange=MOEX
      #{from.iso8601} DEBUG: SELL AFLT skipped — reason=invalid_lot figi=F1 lot=0
      #{from.iso8601} WARN: SELL AFLT error quoting proceeding with unknown session
      bad-date WARN: SELL AFLT #{unknown}
      #{from.iso8601} WARN: SELL RUAL skipped — reason=instrument_unresolved
    LOG

    expect(result).to eq(ok: true, unknown_session_count: 0, instrument_unresolved: {}, invalid_lot: {})
    expect(described_class.format(result).join).not_to include('⚠️')
  end

  it 'counts actual helper warnings formatted by the production Logger formatter' do
    output = StringIO.new
    logger = Logger.new(output)
    logger.formatter = TradingLogic::StrategyLogFormatter.new
    allow(Time).to receive(:now).and_return(from + 60)
    helpers = TradingLogic::StrategyHelpers
    client = double('client without TradingSchedules')
    instrument = OpenStruct.new(lot: 10, exchange: 'moex_mrng_evng_e_wknd_dlr')

    ['SELL', 'FORCE SELL'].each do |context|
      expect(helpers.sell_session_open?(client, instrument, ticker: 'RUAL', context: context, logger: logger)).to be true
      expect(helpers.sell_instrument_lot(nil, ticker: 'RUAL', figi: 'BBG008F2T3T2', context: context, logger: logger)).to be_nil
      invalid = OpenStruct.new(lot: 0)
      expect(helpers.sell_instrument_lot(invalid, ticker: 'RUAL', figi: 'BBG008F2T3T2', context: context, logger: logger)).to be_nil
    end

    expect(summarize(output.string)).to eq(
      ok: true, unknown_session_count: 2,
      instrument_unresolved: { 'BBG008F2T3T2' => 2 }, invalid_lot: { 'BBG008F2T3T2' => 2 }
    )
  end

  it 'recovers the report window from compressed and plain rotations after copytruncate' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'current_strategy.log')
      File.write(path, '')
      File.write("#{path}.1", "#{from.iso8601} WARN: SELL AFLT #{unknown}\n")
      Zlib::GzipWriter.open("#{path}.2.gz") do |writer|
        writer.write("#{(from - 1).iso8601} WARN: SELL AFLT #{unknown}\n")
        writer.write("#{from.iso8601} WARN: FORCE SELL RUAL #{unresolved}\n")
        writer.write("#{from.iso8601} WARN: SELL RUAL skipped — reason=invalid_lot figi=BBG008F2T3T2 lot=0\n")
        writer.write("#{to.iso8601} WARN: SELL AFLT #{unknown}\n")
      end
      # logrotate can leave both forms visible during compression.
      Zlib::GzipWriter.open("#{path}.1.gz") { |writer| writer.write(File.read("#{path}.1")) }
      File.write("#{path}.1.tmp", "#{from.iso8601} WARN: SELL AFLT #{unknown}\n")

      result = described_class.new(path: path).build(from: from, to: to)
      expect(result).to eq(ok: true, unknown_session_count: 1,
                           instrument_unresolved: { 'BBG008F2T3T2' => 1 }, invalid_lot: { 'BBG008F2T3T2' => 1 })
    end
  end

  it 'does not read old rotations, even a corrupt gzip, while counting the current log' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'current_strategy.log')
      File.write(path, "#{from.iso8601} WARN: SELL AFLT #{unknown}\n")
      File.write("#{path}.1", "#{(from - 60).iso8601} WARN: SELL AFLT #{unknown}\n")
      File.write("#{path}.2.gz", 'corrupt gzip')
      ["#{path}.1", "#{path}.2.gz"].each { |rotation| File.utime(from - 1, from - 1, rotation) }
      allow(File).to receive(:foreach).and_call_original
      expect(File).not_to receive(:foreach).with("#{path}.1")
      expect(Zlib::GzipReader).not_to receive(:open).with("#{path}.2.gz")

      result = described_class.new(path: path).build(from: from, to: to)
      expect(result).to eq(ok: true, unknown_session_count: 1, instrument_unresolved: {}, invalid_lot: {})
    end
  end

  ['.1', '.1.gz'].each do |suffix|
    it "reads #{suffix} when its mtime equals the inclusive window start" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'current_strategy.log')
        rotation = "#{path}#{suffix}"
        File.write(path, '')
        contents = "#{from.iso8601} WARN: SELL AFLT #{unknown}\n"
        if suffix.end_with?('.gz')
          Zlib::GzipWriter.open(rotation) { |writer| writer.write(contents) }
        else
          File.write(rotation, contents)
        end
        File.utime(from, from, rotation)

        result = described_class.new(path: path).build(from: from, to: to)
        expect(result).to eq(ok: true, unknown_session_count: 1, instrument_unresolved: {}, invalid_lot: {})
      end
    end
  end

  it 'reports a corrupt rotation as unavailable instead of returning partial counts' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'current_strategy.log')
      File.write(path, "#{from.iso8601} WARN: SELL AFLT #{unknown}\n")
      Zlib::GzipWriter.open("#{path}.1.gz") { |writer| writer.write("#{from.iso8601} WARN: SELL AFLT #{unknown}\n") }
      File.truncate("#{path}.1.gz", File.size("#{path}.1.gz") - 5)
      File.utime(from + 60, from + 60, "#{path}.1.gz")

      result = described_class.new(path: path).build(from: from, to: to)
      expect(result).to eq(ok: false, reason: :log_unavailable)
    end
  end

  it 'reports zero for an empty readable log' do
    expect(summarize('')).to eq(ok: true, unknown_session_count: 0, instrument_unresolved: {}, invalid_lot: {})
  end

  it 'reports missing logs as unavailable instead of zero' do
    Dir.mktmpdir do |dir|
      result = described_class.new(path: File.join(dir, 'missing.log')).build(from: from, to: to)
      expect(result).to eq(ok: false, reason: :log_unavailable)
      expect(described_class.format(result).join).to include('н/д (лог недоступен)')
    end
  end

  it 'reports read failures as unavailable' do
    allow(File).to receive(:foreach).with('/unreadable.log').and_raise(Errno::EACCES)
    result = described_class.new(path: '/unreadable.log').build(from: from, to: to)
    expect(result).to eq(ok: false, reason: :log_unavailable)
  end
end
