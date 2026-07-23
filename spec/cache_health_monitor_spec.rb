# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/cache_health_monitor'
require 'fileutils'
require 'tmpdir'

RSpec.describe TradingLogic::CacheHealthMonitor do
  def write_cache(path, updated_at:)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate({ 'updated_at' => updated_at.iso8601, 'instruments' => [{ 'ticker' => 'SBER' }] }))
  end

  it 'sends warning, critical, stale, suppresses spam, and sends recovery once' do
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, 'health.json')
      moex_path = File.join(dir, 'moex.json')
      now = Time.utc(2026, 7, 23, 12, 0, 0)
      sent = []
      monitor = described_class.new(
        state_path: state_path,
        cache_configs: {
          'moex' => {
            path: moex_path,
            label: 'MOEX cache',
            warn_hours: 36,
            critical_hours: 60,
            stale_hours: 72,
            repeat_hours: 12,
            remediation: 'Run locally: bundle exec rake moex_cache:sync INDEX=IMOEX'
          }
        },
        now_proc: -> { now },
        notifier: lambda { |text|
          sent << text
          true
        }
      )

      write_cache(moex_path, updated_at: now - (37 * 3600))
      expect(monitor.check['moex'][:level]).to eq('warning')
      expect(sent.size).to eq(1)

      monitor.check
      expect(sent.size).to eq(1)

      now += (13 * 3600)
      monitor.check
      expect(sent.size).to eq(2)
      expect(sent.last).to include('warning')

      write_cache(moex_path, updated_at: now - (61 * 3600))
      monitor.check
      expect(sent.last).to include('critical')

      write_cache(moex_path, updated_at: now - (73 * 3600))
      monitor.check
      expect(sent.last).to include('Intersection buys are blocked')

      write_cache(moex_path, updated_at: now - 3600)
      monitor.check
      expect(sent.last).to include('restored')
    end
  end

  it 'uses different remediation text for market cache' do
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, 'health.json')
      market_path = File.join(dir, 'market.json')
      sent = []
      now = Time.utc(2026, 7, 23, 12, 0, 0)

      write_cache(market_path, updated_at: now - (65 * 3600))
      monitor = described_class.new(
        state_path: state_path,
        cache_configs: {
          'market' => {
            path: market_path,
            label: 'Market cache',
            warn_hours: 36,
            critical_hours: 60,
            stale_hours: 72,
            repeat_hours: 12,
            remediation: 'Run on server: bundle exec rake market_cache:refresh FORCE=true'
          }
        },
        now_proc: -> { now },
        notifier: lambda { |text|
          sent << text
          true
        }
      )

      monitor.check
      expect(sent.last).to include('market_cache:refresh FORCE=true')
    end
  end

  it 'retries failed sends immediately and retries recovery until delivery succeeds' do
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, 'health.json')
      moex_path = File.join(dir, 'moex.json')
      now = Time.utc(2026, 7, 23, 12, 0, 0)
      sent = []
      responses = [false, true, false, true]
      monitor = described_class.new(
        state_path: state_path,
        cache_configs: {
          'moex' => {
            path: moex_path,
            label: 'MOEX cache',
            warn_hours: 36,
            critical_hours: 60,
            stale_hours: 72,
            repeat_hours: 12,
            remediation: 'Run locally: bundle exec rake moex_cache:sync INDEX=IMOEX'
          }
        },
        now_proc: -> { now },
        notifier: lambda do |text|
          sent << text
          responses.shift
        end
      )

      write_cache(moex_path, updated_at: now - (37 * 3600))
      monitor.check
      state = JSON.parse(File.read(state_path))
      expect(state.dig('moex', 'last_notified_level')).to be_nil
      expect(state.dig('moex', 'last_alert_at')).to be_nil

      monitor.check
      state = JSON.parse(File.read(state_path))
      expect(state.dig('moex', 'last_notified_level')).to eq('warning')
      expect(sent.size).to eq(2)

      write_cache(moex_path, updated_at: now - 3600)
      monitor.check
      state = JSON.parse(File.read(state_path))
      expect(state.dig('moex', 'level')).to eq('ok')
      expect(state.dig('moex', 'last_notified_level')).to eq('warning')

      monitor.check
      state = JSON.parse(File.read(state_path))
      expect(state.dig('moex', 'last_notified_level')).to eq('ok')
      expect(sent.last).to include('restored')
    end
  end
end
