# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/investing_parser'

RSpec.describe TradingLogic::InvestingParser, :integration do
  it 'parses a live quote page from ru.investing.com' do
    skip 'set INVESTING_INTEGRATION=1 to run live investing smoke test' unless ENV['INVESTING_INTEGRATION'] == '1'

    parser = described_class.new
    quote = parser.fetch_quote('/currencies/usd-rub')

    expect(quote[:price]).to be_a(Float)
    expect(quote[:price]).to be > 0
  end
end
