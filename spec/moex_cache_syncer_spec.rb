# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/moex_cache_syncer'
require 'fileutils'
require 'tmpdir'

RSpec.describe TradingLogic::MoexCacheSyncer do
  def write_artifact(path, index: 'IMOEX', updated_at: Time.now.utc.iso8601, instruments_count: 25)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(
      path,
      JSON.pretty_generate(
        {
          'index' => index,
          'updated_at' => updated_at,
          'instruments' => Array.new(instruments_count) { |i| { 'secid' => "TICK#{i}" } }
        }
      )
    )
  end

  it 'supports dry run without ssh/scp' do
    Dir.mktmpdir do |dir|
      local_cache = File.join(dir, 'moex_index_cache.json')
      iss = instance_double(TradingLogic::MoexISS)
      allow(iss).to receive(:index_constituents) do |_index, cache_path:|
        write_artifact(cache_path)
        [{ secid: 'SBER' }]
      end

      runner = described_class.new(
        iss: iss,
        local_cache_path: local_cache,
        command_runner: ->(_cmd, *_args) { raise 'should not run commands in dry-run' },
        remote_host: 'host',
        remote_dir: '/srv/app'
      )

      result = runner.perform(index: 'IMOEX', dry_run: true)

      expect(result[:dry_run]).to be true
      expect(result[:instruments_count]).to eq(25)
    end
  end

  it 'raises on ssh install failure after upload' do
    Dir.mktmpdir do |dir|
      local_cache = File.join(dir, 'moex_index_cache.json')
      iss = instance_double(TradingLogic::MoexISS)
      allow(iss).to receive(:index_constituents) do |_index, cache_path:|
        write_artifact(cache_path)
        [{ secid: 'SBER' }]
      end

      commands = []
      statuses = [
        double('status', success?: true),
        double('status', success?: true),
        double('status', success?: false)
      ]
      runner = described_class.new(
        iss: iss,
        local_cache_path: local_cache,
        remote_host: 'host',
        remote_user: 'deploy',
        remote_dir: '/srv/app',
        command_runner: lambda do |*cmd|
          commands << cmd
          ['', commands.size == 3 ? 'ssh failed' : '', statuses[commands.size - 1]]
        end
      )

      expect { runner.perform(index: 'IMOEX') }
        .to raise_error(described_class::SyncError, /ssh install failed/)

      expect(commands.size).to eq(3)
      expect(commands[0].first).to eq('ssh')
      expect(commands[1].first).to eq('scp')
      expect(commands[2].first).to eq('ssh')
      # Remote install must go through the RVM wrapper: non-interactive SSH
      # has no `bundle` in PATH.
      expect(commands[2].last).to include('/srv/app/bin/systemd_exec rake moex_cache:install')
    end
  end
end
