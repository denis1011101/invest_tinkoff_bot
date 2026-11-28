# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/public_market_quotes'

RSpec.describe TradingLogic::PublicMarketQuotes do
  let(:index_iss) { instance_double(TradingLogic::MoexISS) }
  let(:futures_iss) { instance_double(TradingLogic::MoexISS) }
  let(:now) { Time.iso8601('2026-12-01T02:00:00+03:00') }

  subject(:quotes) { described_class.new(index_iss: index_iss, futures_iss: futures_iss, now: now) }

  it 'reads the CBR effective date and calculates the change from the prior official rate' do
    allow(quotes).to receive(:get).with(described_class::CBR_URL).and_return(<<~XML)
      <ValCurs Date="01.12.2026">
        <Valute><CharCode>USD</CharCode><Nominal>10</Nominal><Value>806,2730</Value></Valute>
      </ValCurs>
    XML
    previous_url = "#{described_class::CBR_URL}?date_req=30%2F11%2F2026"
    allow(quotes).to receive(:get).with(previous_url).and_return(<<~XML)
      <ValCurs Date="30.11.2026">
        <Valute><CharCode>USD</CharCode><Nominal>1</Nominal><Value>80,1273</Value></Valute>
      </ValCurs>
    XML

    result = quotes.fetch(:cbr, 'USD')

    expect(result[:price]).to be_within(0.00001).of(80.6273)
    expect(result[:as_of]).to eq(Date.new(2026, 12, 1))
    expect(result[:delta]).to be_within(0.00001).of(0.5)
    expect(result[:delta_pct]).to be_within(0.001).of(0.624)
  end

  it 'keeps the current CBR rate if the previous rate cannot be loaded' do
    allow(quotes).to receive(:get).with(described_class::CBR_URL).and_return(<<~XML)
      <ValCurs Date="01.12.2026">
        <Valute><CharCode>USD</CharCode><Nominal>1</Nominal><Value>80,6273</Value></Valute>
      </ValCurs>
    XML
    previous_url = "#{described_class::CBR_URL}?date_req=30%2F11%2F2026"
    allow(quotes).to receive(:get).with(previous_url).and_raise(described_class::Unavailable, 'HTTP 503')

    expect(quotes.fetch(:cbr, 'USD')).to eq(price: 80.6273, as_of: Date.new(2026, 12, 1))
  end

  it 'uses the source timestamps and index daily change' do
    allow(quotes).to receive(:get).with("#{described_class::GOLD_API_URL}/XPD").and_return(
      '{"symbol":"XPD","price":1320.1,"updatedAt":"2026-11-30T21:22:00Z"}'
    )
    allow(index_iss).to receive(:board_data).with(board: 'SNDX', secid: 'IMOEX2', columns: anything).and_return(
      marketdata: [{ currentvalue: 2364.59, lastchange: 28.05, lastchangeprc: 1.2, tradedate: '2026-11-30', time: '22:15:00' }]
    )

    expect(quotes.fetch(:gold_api, 'XPD')).to eq(price: 1320.1, as_of: Time.utc(2026, 11, 30, 21, 22))
    expect(quotes.fetch(:moex_index, 'IMOEX2')).to eq(
      price: 2364.59, delta: 28.05, delta_pct: 1.2, as_of: Time.iso8601('2026-11-30T22:15:00+03:00')
    )
  end

  it 'rolls off the expiring futures and ignores spreads, with a single schedule lookup for both assets' do
    expect(futures_iss).to receive(:board_data).with(board: 'RFUD', columns: anything).once.and_return(
      securities: [
        { secid: 'BRZ6', shortname: 'BR-12.26', assetcode: 'BR', lasttradedate: '2026-12-01' },
        { secid: 'BRF7BRG7', shortname: 'BR-1.27-2.27', assetcode: 'BR', lasttradedate: '2026-12-02' },
        { secid: 'BRF7', shortname: 'BR-1.27', assetcode: 'BR', lasttradedate: '2027-01-04' },
        { secid: 'NCZ6', shortname: 'NICKEL-12.26', assetcode: 'NICKEL', lasttradedate: '2026-12-15' }
      ]
    )
    allow(futures_iss).to receive(:board_data).with(board: 'RFUD', secid: 'BRF7', columns: anything).and_return(
      securities: [{ prevprice: 90.0 }],
      marketdata: [{ last: 91.8, tradedate: '2026-11-30', time: '23:38:00' }]
    )
    allow(futures_iss).to receive(:board_data).with(board: 'RFUD', secid: 'NCZ6', columns: anything).and_return(
      securities: [{ prevprice: 15_705 }],
      marketdata: [{ last: 15_820, tradedate: '2026-11-30', time: '19:30:09' }]
    )

    brent = quotes.fetch(:moex_future, 'BR')
    expect(brent).to include(price: 91.8, contract: 'BR-1.27', state_symbol: 'BRF7')
    expect(brent[:delta_pct]).to be_within(0.01).of(2.0)
    expect(quotes.fetch(:moex_future, 'NICKEL')).to include(
      state_symbol: 'NCZ6', as_of: Time.iso8601('2026-11-30T19:30:09+03:00')
    )
  end
end
