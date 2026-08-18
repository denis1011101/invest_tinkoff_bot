# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/strategy_heartbeat_monitor'
require 'fileutils'
require 'tmpdir'

RSpec.describe TradingLogic::StrategyHeartbeatMonitor do
  def touch(path, at:)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "2026-08-18T17:35:03Z DEBUG: scan_id=abc\n")
    File.utime(at, at, path)
  end

  def build(dir, now:, sent:, processes: [], **overrides)
    described_class.new(
      state_path: File.join(dir, 'heartbeat.json'),
      config: described_class.default_config({}).merge(path: File.join(dir, 'current_strategy.log'), **overrides),
      now_proc: -> { now },
      notifier: lambda { |text|
        sent << text
        true
      },
      process_lookup: -> { processes }
    )
  end

  it 'walks silence up through warning and critical, throttles repeats, and reports recovery once' do
    Dir.mktmpdir do |dir|
      now = Time.utc(2026, 8, 18, 18, 0, 0)
      sent = []
      log = File.join(dir, 'current_strategy.log')

      touch(log, at: now - 300)
      monitor = build(dir, now: now, sent: sent)
      expect(monitor.check[:level]).to eq('ok')
      expect(sent).to be_empty

      # Тишина 25 минут: два пропущенных пятиминутных прогона это уже поломка.
      touch(log, at: now - (25 * 60))
      expect(build(dir, now: now, sent: sent).check[:level]).to eq('warning')
      expect(sent.size).to eq(1)
      expect(sent.last).to include('no log write for 25.0min')

      # Тот же уровень и тот же mtime — молчим, пока не истечёт repeat_hours.
      build(dir, now: now + 60, sent: sent).check
      expect(sent.size).to eq(1)

      later = now + (7 * 3600)
      build(dir, now: later, sent: sent).check
      expect(sent.size).to eq(2)

      touch(log, at: later - (90 * 60))
      result = build(dir, now: later, sent: sent).check
      expect(result[:level]).to eq('critical')
      expect(sent.last).to include('critical')
      expect(sent.last).to include('1.5h')

      touch(log, at: later + 60)
      recovered = build(dir, now: later + 120, sent: sent).check
      expect(recovered[:level]).to eq('ok')
      expect(sent.last).to include('restored')

      # Восстановление шлём один раз, а не на каждом тике.
      build(dir, now: later + 180, sent: sent).check
      expect(sent.size).to eq(4)
    end
  end

  it 'treats a missing log as critical rather than healthy' do
    Dir.mktmpdir do |dir|
      sent = []
      result = build(dir, now: Time.utc(2026, 8, 18, 18, 0, 0), sent: sent).check

      expect(result[:level]).to eq('critical')
      expect(result[:age_minutes]).to be_nil
      expect(sent.last).to include('is missing')
    end
  end

  it 'names the hung run in the alert and explains why later runs are skipped' do
    Dir.mktmpdir do |dir|
      now = Time.utc(2026, 8, 18, 20, 20, 0)
      sent = []
      touch(File.join(dir, 'current_strategy.log'), at: now - (165 * 60))
      processes = [{ pid: 3_362_270, elapsed_seconds: 160 * 60, command: 'ruby bin/current_strategy.rb' }]

      result = build(dir, now: now, sent: sent, processes: processes).check

      expect(result[:hung_run][:pid]).to eq(3_362_270)
      expect(sent.last).to include('pid 3362270')
      expect(sent.last).to include('holds the cron lock')
    end
  end

  it 'ignores a normal short run' do
    Dir.mktmpdir do |dir|
      now = Time.utc(2026, 8, 18, 20, 20, 0)
      sent = []
      touch(File.join(dir, 'current_strategy.log'), at: now - (30 * 60))
      processes = [{ pid: 42, elapsed_seconds: 40, command: 'ruby bin/current_strategy.rb' }]

      result = build(dir, now: now, sent: sent, processes: processes).check

      expect(result[:hung_run]).to be_nil
      expect(sent.last).not_to include('Hung run')
    end
  end

  it 'keeps the alert unacknowledged when Telegram delivery fails' do
    Dir.mktmpdir do |dir|
      now = Time.utc(2026, 8, 18, 18, 0, 0)
      touch(File.join(dir, 'current_strategy.log'), at: now - (25 * 60))
      attempts = 0
      failing = described_class.new(
        state_path: File.join(dir, 'heartbeat.json'),
        config: described_class.default_config({}).merge(path: File.join(dir, 'current_strategy.log')),
        now_proc: -> { now },
        notifier: lambda { |_text|
          attempts += 1
          false
        },
        process_lookup: -> { [] }
      )

      failing.check
      failing.check

      # Недоставленный алерт не считается отправленным, иначе первый же сбой
      # Telegram навсегда проглотил бы инцидент.
      expect(attempts).to eq(2)
    end
  end

  describe 'process lookup' do
    it 'picks the ruby process and skips the flock/bash wrappers that carry the same command line' do
      monitor = described_class.new(state_path: '/dev/null', notifier: nil, process_lookup: nil)
      ps_output = <<~PS
        3362095 9676 /bin/sh -c /usr/bin/flock -n /tmp/current_strategy.lock /bin/bash -lc 'cd /root/apps/invest_tinkoff_bot && bundle exec ruby bin/current_strategy.rb'
        3362098 9676 /usr/bin/flock -n /tmp/current_strategy.lock /bin/bash -lc cd /root/apps/invest_tinkoff_bot && bundle exec ruby bin/current_strategy.rb
        3362270 9670 /usr/local/rvm/rubies/ruby-4.0.6/bin/ruby bin/current_strategy.rb
        3400000 12 /usr/bin/ruby bin/price_monitor.rb
      PS
      allow(monitor).to receive(:`).with(/ps -eo/).and_return(ps_output)

      found = monitor.send(:running_strategy_processes)

      expect(found.map { |p| p[:pid] }).to eq([3_362_270])
      expect(found.first[:elapsed_seconds]).to eq(9670)
    end
  end
end
