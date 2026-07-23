# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/moex_cache_artifact'
require 'fileutils'
require 'tmpdir'

RSpec.describe TradingLogic::MoexCacheArtifact do
  def write_artifact(path, index: 'IMOEX', updated_at: Time.now.utc.iso8601, instruments: nil)
    instruments ||= Array.new(25) { |i| { 'secid' => "TICK#{i}" } }
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate({ 'index' => index, 'updated_at' => updated_at, 'instruments' => instruments }))
  end

  it 'accepts a valid artifact' do
    Dir.mktmpdir do |dir|
      artifact = File.join(dir, 'moex.json')
      write_artifact(artifact)

      result = described_class.validate(artifact, expected_index: 'IMOEX', previous_path: nil)

      expect(result[:index]).to eq('IMOEX')
      expect(result[:instruments_count]).to eq(25)
      expect(result[:sha256]).not_to be_empty
    end
  end

  it 'rejects broken, future, stale, and wrong-index artifacts' do
    Dir.mktmpdir do |dir|
      bad_json = File.join(dir, 'bad.json')
      File.write(bad_json, '{')
      expect { described_class.validate(bad_json, expected_index: 'IMOEX', previous_path: nil) }
        .to raise_error(described_class::ValidationError, /invalid JSON/)

      future = File.join(dir, 'future.json')
      write_artifact(future, updated_at: (Time.now.utc + 3600).iso8601)
      expect { described_class.validate(future, expected_index: 'IMOEX', previous_path: nil) }
        .to raise_error(described_class::ValidationError, /future/)

      stale = File.join(dir, 'stale.json')
      write_artifact(stale, updated_at: (Time.now.utc - (8 * 3600)).iso8601)
      expect { described_class.validate(stale, expected_index: 'IMOEX', previous_path: nil, max_age_hours: 6) }
        .to raise_error(described_class::ValidationError, /too old/)

      wrong = File.join(dir, 'wrong.json')
      write_artifact(wrong, index: 'RTSI')
      expect { described_class.validate(wrong, expected_index: 'IMOEX', previous_path: nil) }
        .to raise_error(described_class::ValidationError, /unexpected index/)
    end
  end

  it 'rejects artifacts with duplicate tickers after normalization' do
    Dir.mktmpdir do |dir|
      instruments = Array.new(25) { |i| { 'secid' => "TICK#{i}" } }
      instruments << { 'secid' => ' tick3 ' } # same as TICK3 after strip/upcase

      duplicated = File.join(dir, 'dup.json')
      write_artifact(duplicated, instruments: instruments)

      expect { described_class.validate(duplicated, expected_index: 'IMOEX', previous_path: nil) }
        .to raise_error(described_class::ValidationError, /duplicate ticker TICK3 at index 25 \(first seen at index 3\)/)
    end
  end

  it 'rejects empty or sharply shrunken artifacts' do
    Dir.mktmpdir do |dir|
      previous = File.join(dir, 'prev.json')
      write_artifact(previous, instruments: Array.new(60) { |i| { 'secid' => "TICK#{i}" } })

      empty = File.join(dir, 'empty.json')
      write_artifact(empty, instruments: [])
      expect { described_class.validate(empty, expected_index: 'IMOEX', previous_path: previous) }
        .to raise_error(described_class::ValidationError, /non-empty array/)

      shrunken = File.join(dir, 'small.json')
      write_artifact(shrunken, instruments: Array.new(21) { |i| { 'secid' => "TICK#{i}" } })
      expect { described_class.validate(shrunken, expected_index: 'IMOEX', previous_path: previous) }
        .to raise_error(described_class::ValidationError, /dropped too much/)
    end
  end

  it 'does not overwrite destination when install validation fails' do
    Dir.mktmpdir do |dir|
      destination = File.join(dir, 'moex_index_cache.json')
      write_artifact(destination, instruments: Array.new(30) { |i| { 'secid' => "OLD#{i}" } })
      source = File.join(dir, 'incoming.json')
      write_artifact(source, instruments: Array.new(5) { |i| { 'secid' => "NEW#{i}" } })

      expect do
        described_class.install(source, destination: destination, expected_index: 'IMOEX')
      end.to raise_error(described_class::ValidationError)

      payload = JSON.parse(File.read(destination))
      expect(payload.fetch('instruments').size).to eq(30)
      expect(File).to exist(source)
    end
  end

  it 'backs up the previous cache and renames atomically into place' do
    Dir.mktmpdir do |dir|
      destination = File.join(dir, 'moex_index_cache.json')
      backup_dir = File.join(dir, 'cache_backups')
      write_artifact(destination, instruments: Array.new(30) { |i| { 'secid' => "OLD#{i}" } })
      source_dir = Dir.mktmpdir('incoming-artifact')
      source = File.join(source_dir, 'incoming.json')
      write_artifact(source, instruments: Array.new(30) { |i| { 'secid' => "NEW#{i}" } })

      expect(File).to receive(:rename).with(match(%r{#{Regexp.escape(dir)}/\.moex_index_cache\.json\.incoming-}), destination)
                                      .and_call_original

      result = described_class.install(
        source,
        destination: destination,
        expected_index: 'IMOEX',
        backup_dir: backup_dir
      )

      expect(result[:backup_path]).to start_with(backup_dir)
      expect(File).to exist(result[:backup_path])
      expect(JSON.parse(File.read(destination)).fetch('instruments').first.fetch('secid')).to eq('NEW0')
      expect(File).not_to exist(source)
    ensure
      FileUtils.rm_rf(source_dir)
    end
  end
end
