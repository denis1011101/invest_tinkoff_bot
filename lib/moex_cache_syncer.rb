# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative 'moex_cache_artifact'
require_relative 'moex_iss'

module TradingLogic
  class MoexCacheSyncer
    class SyncError < StandardError; end

    def initialize(iss: TradingLogic::MoexISS.new, artifact: TradingLogic::MoexCacheArtifact,
                   command_runner: Open3.method(:capture3),
                   local_cache_path: TradingLogic::MoexISS::CACHE_PATH,
                   remote_host: ENV.fetch('MOEX_SYNC_HOST', nil), remote_user: ENV.fetch('MOEX_SYNC_USER', nil),
                   remote_dir: ENV['MOEX_SYNC_REMOTE_DIR'] || File.expand_path('..', __dir__),
                   ssh_key: ENV.fetch('MOEX_SYNC_SSH_KEY', nil))
      @iss = iss
      @artifact = artifact
      @command_runner = command_runner
      @local_cache_path = local_cache_path
      @remote_host = remote_host
      @remote_user = remote_user
      @remote_dir = remote_dir
      @ssh_key = ssh_key
    end

    def perform(index:, dry_run: false)
      Dir.mktmpdir('moex-cache-sync') do |dir|
        temp_artifact = File.join(dir, 'moex_index_cache.json')
        result = @iss.index_constituents(index, cache_path: temp_artifact)
        raise SyncError, "no instruments returned for index #{index}" if result.nil? || result.empty?

        metadata = @artifact.validate(temp_artifact, expected_index: index, previous_path: @local_cache_path)
        return metadata.merge(dry_run: true) if dry_run

        local_install = @artifact.install(temp_artifact, destination: @local_cache_path, expected_index: index)
        remote_target = File.join(@remote_dir, 'tmp', 'incoming', 'moex_index_cache.json')

        validate_remote_config!
        run_command!(mkdir_command, 'remote mkdir')
        run_command!(scp_command(@local_cache_path, remote_target), 'scp upload')
        run_command!(ssh_install_command(remote_target, local_install[:sha256], index), 'ssh install')

        local_install.merge(remote_path: remote_target, dry_run: false)
      end
    end

    private

    def validate_remote_config!
      raise SyncError, 'MOEX_SYNC_HOST is required' if @remote_host.to_s.strip.empty?
      raise SyncError, 'MOEX_SYNC_REMOTE_DIR is required' if @remote_dir.to_s.strip.empty?
    end

    def ssh_target
      return @remote_host if @remote_user.to_s.strip.empty?

      "#{@remote_user}@#{@remote_host}"
    end

    def base_ssh_options
      opts = ['-o', 'BatchMode=yes']
      opts += ['-i', @ssh_key] unless @ssh_key.to_s.strip.empty?
      opts
    end

    def mkdir_command
      ['ssh', *base_ssh_options, ssh_target, "mkdir -p #{Shellwords.escape(File.join(@remote_dir, 'tmp', 'incoming'))}"]
    end

    def scp_command(local_path, remote_target)
      ['scp', *base_ssh_options, local_path, "#{ssh_target}:#{remote_target}"]
    end

    def ssh_install_command(remote_target, sha256, index)
      # Non-interactive SSH does not load RVM, so a bare `bundle` is usually
      # missing from PATH; bin/systemd_exec builds the RVM environment itself.
      remote_cmd = [
        Shellwords.escape(File.join(@remote_dir, 'bin', 'systemd_exec')),
        'rake', 'moex_cache:install',
        "FILE=#{Shellwords.escape(remote_target)}",
        "SHA256=#{Shellwords.escape(sha256)}",
        "INDEX=#{Shellwords.escape(index)}"
      ].join(' ')
      ['ssh', *base_ssh_options, ssh_target, remote_cmd]
    end

    def run_command!(cmd, label)
      stdout, stderr, status = @command_runner.call(*cmd)
      return stdout if status.success?

      raise SyncError, "#{label} failed: #{stderr.to_s.strip}"
    end
  end
end
