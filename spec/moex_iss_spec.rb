# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/moex_iss'
require 'stringio'
require 'tempfile'

RSpec.describe TradingLogic::MoexISS do
  def bundle_file
    f = Tempfile.new(['moex-roots', '.pem'])
    f.write("# certs\n")
    f.flush
    f
  end

  def stub_http_session(body: { 'securities' => { 'columns' => %w[SECID BOARDID], 'data' => [%w[SBER TQBR]] } })
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:use_ssl?).and_return(true)
    allow(http).to receive(:ca_file=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)

    res = instance_double(Net::HTTPOK, body: JSON.generate(body))
    allow(res).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(http).to receive(:request).and_return(res)
    allow(Net::HTTP).to receive(:new).and_return(http)
    http
  end

  describe 'CA bundle resolution and Net::HTTP scoping' do
    it 'prefers MOEX_CA_BUNDLE over BROKER_CA_BUNDLE and GRPC_DEFAULT_SSL_ROOTS_FILE_PATH' do
      moex = bundle_file
      broker = bundle_file
      grpc = bundle_file
      http = stub_http_session

      iss = described_class.new(
        env: {
          'MOEX_CA_BUNDLE' => moex.path,
          'BROKER_CA_BUNDLE' => broker.path,
          'GRPC_DEFAULT_SSL_ROOTS_FILE_PATH' => grpc.path
        }
      )
      expect(iss.securities.map { |s| s[:secid] }).to eq(['SBER'])
      expect(http).to have_received(:ca_file=).with(moex.path)
    ensure
      moex&.close!
      broker&.close!
      grpc&.close!
    end

    it 'falls back to BROKER_CA_BUNDLE and GRPC_DEFAULT_SSL_ROOTS_FILE_PATH' do
      grpc = bundle_file
      http = stub_http_session

      iss = described_class.new(env: { 'MOEX_CA_BUNDLE' => '  ', 'GRPC_DEFAULT_SSL_ROOTS_FILE_PATH' => grpc.path })
      iss.securities

      expect(http).to have_received(:ca_file=).with(grpc.path)
    ensure
      grpc&.close!
    end

    it 'leaves ca_file unset when no CA bundle is configured' do
      http = stub_http_session

      iss = described_class.new(env: {})
      iss.securities

      expect(http).not_to have_received(:ca_file=)
    end

    it 'warns and falls back to the system store when the CA bundle is unreadable' do
      http = stub_http_session
      io = StringIO.new

      iss = described_class.new(env: { 'MOEX_CA_BUNDLE' => '/nope/moex_roots.pem' }, warn_io: io)
      iss.securities

      expect(io.string).to include('/nope/moex_roots.pem')
      expect(http).not_to have_received(:ca_file=)
    end

    it 'supports an explicit ca_file option override' do
      custom = bundle_file
      http = stub_http_session

      iss = described_class.new(ca_file: custom.path, env: {})
      iss.securities

      expect(http).to have_received(:ca_file=).with(custom.path)
    ensure
      custom&.close!
    end
  end
end
