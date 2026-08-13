# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/broker_tls'
require 'tempfile'
require 'stringio'

RSpec.describe TradingLogic::BrokerTls do
  # Двойник HTTParty-класса: настоящий InvestTinkoff::V2::Client в специях не
  # грузим, чтобы прогон не тянул грузный гем и не зависел от его версии.
  def client_double
    Class.new do
      class << self
        attr_reader :applied

        def ssl_ca_file(path)
          @applied = path
        end
      end
    end
  end

  def bundle_file
    f = Tempfile.new(['roots', '.pem'])
    f.write("# certs\n")
    f.flush
    f
  end

  describe '.bundle_path' do
    it 'prefers the dedicated variable' do
      env = { 'BROKER_CA_BUNDLE' => '/a.pem', 'GRPC_DEFAULT_SSL_ROOTS_FILE_PATH' => '/b.pem' }
      expect(described_class.bundle_path(env)).to eq('/a.pem')
    end

    # Хост, где бандл уже подключён к gRPC, не должен требовать второй переменной.
    it 'falls back to the grpc variable' do
      env = { 'GRPC_DEFAULT_SSL_ROOTS_FILE_PATH' => '/b.pem' }
      expect(described_class.bundle_path(env)).to eq('/b.pem')
    end

    it 'treats blank values as unset' do
      env = { 'BROKER_CA_BUNDLE' => '  ', 'GRPC_DEFAULT_SSL_ROOTS_FILE_PATH' => '/b.pem' }
      expect(described_class.bundle_path(env)).to eq('/b.pem')
    end

    it 'returns nil when nothing is configured' do
      expect(described_class.bundle_path({})).to be_nil
    end
  end

  describe '.apply!' do
    it 'attaches the bundle to the broker client' do
      file = bundle_file
      klass = client_double

      expect(described_class.apply!(klass, path: file.path)).to eq(file.path)
      expect(klass.applied).to eq(file.path)
    ensure
      file&.close!
    end

    it 'does nothing when no bundle is configured' do
      klass = client_double

      expect(described_class.apply!(klass, path: nil)).to be_nil
      expect(klass.applied).to be_nil
    end

    # Молча оставить системный стор нельзя: покупки встанут, и надо понимать почему.
    it 'warns and leaves the system store when the bundle is unreadable' do
      klass = client_double
      io = StringIO.new

      expect(described_class.apply!(klass, path: '/nope/roots.pem', warn_io: io)).to be_nil
      expect(klass.applied).to be_nil
      expect(io.string).to include('/nope/roots.pem')
    end

    it 'ignores a client that is not an HTTParty class' do
      expect(described_class.apply!(Object.new, path: '/a.pem')).to be_nil
    end

    it 'ignores a missing client class' do
      expect(described_class.apply!(nil, path: '/a.pem')).to be_nil
    end
  end
end
