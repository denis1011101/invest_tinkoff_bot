# frozen_string_literal: true

require_relative 'spec_helper'
require 'ostruct'
require_relative '../lib/investing_parser'

RSpec.describe TradingLogic::InvestingParser do
  let(:sleep_calls) { [] }
  let(:warnings) { [] }
  let(:current_time) { Time.utc(2026, 3, 29, 10, 0, 0) }
  let(:now_proc) { -> { current_time } }
  let(:sleep_proc) { ->(seconds) { sleep_calls << seconds } }
  let(:warn_proc) { ->(message) { warnings << message } }

  it 'parses price and daily change from the top quote block' do
    html = <<~HTML
      <html>
        <body>
          <div>Цена в USD</div>
          <div>Добавить в список наблюдения</div>
          <div>6.352,00</div>
          <div>-125,10(-1,93%)</div>
          <div>Закрыт·27/03</div>
        </body>
      </html>
    HTML

    parser = described_class.new(
      http_getter: ->(_uri, _headers) { OpenStruct.new(code: '200', body: html) },
      now_proc: now_proc,
      sleep_proc: sleep_proc,
      warn_proc: warn_proc
    )

    quote = parser.fetch_quote('/indices/us-spx-500')

    expect(quote[:price]).to eq(6352.0)
    expect(quote[:delta]).to eq(-125.1)
    expect(quote[:delta_pct]).to eq(-1.93)
    expect(quote[:path]).to eq('/indices/us-spx-500')
    expect(warnings).to include('InvestingParser: selectors not found, falling back to text parsing')
  end

  it 'normalizes absolute urls and fetches live data on every call' do
    calls = 0
    html = <<~HTML
      <html>
        <body>
          <div>Цена в RUB</div>
          <div>Добавить в список наблюдения</div>
          <div>81,50</div>
          <div>+0,1250(+0,15%)</div>
        </body>
      </html>
    HTML

    parser = described_class.new(
      sleep_range: 0.0..0.0,
      http_getter: lambda { |uri, _headers|
        calls += 1
        expect(uri.to_s).to eq('https://ru.investing.com/currencies/usd-rub')
        OpenStruct.new(code: '200', body: html)
      },
      now_proc: now_proc,
      sleep_proc: sleep_proc,
      warn_proc: warn_proc
    )

    first = parser.fetch_quote('https://ru.investing.com/currencies/usd-rub')
    second = parser.fetch_quote('/currencies/usd-rub')

    expect(calls).to eq(2)
    expect(first[:price]).to eq(81.5)
    expect(second[:price]).to eq(81.5)
    expect(second[:path]).to eq('/currencies/usd-rub')
  end

  it 'retries on retriable responses' do
    attempt = 0
    html = <<~HTML
      <html>
        <body>
          <div>Цена в USD</div>
          <div>Добавить в список наблюдения</div>
          <div>105,32</div>
          <div>+3,43(+3,37%)</div>
        </body>
      </html>
    HTML

    parser = described_class.new(
      http_getter: lambda { |_uri, _headers|
        attempt += 1
        if attempt == 1
          OpenStruct.new(code: '503', body: 'Service unavailable')
        else
          OpenStruct.new(code: '200', body: html)
        end
      },
      now_proc: now_proc,
      sleep_proc: sleep_proc,
      warn_proc: warn_proc
    )

    quote = parser.fetch_quote('/commodities/brent-oil')

    expect(attempt).to eq(2)
    expect(quote[:price]).to eq(105.32)
    expect(sleep_calls).to include(1)
  end

  it 'warns when quote anchors are missing and still scans from top of document' do
    html = <<~HTML
      <html>
        <body>
          <div>81,50</div>
          <div>+0,1250(+0,15%)</div>
        </body>
      </html>
    HTML

    parser = described_class.new(
      http_getter: ->(_uri, _headers) { OpenStruct.new(code: '200', body: html) },
      now_proc: now_proc,
      sleep_proc: sleep_proc,
      warn_proc: warn_proc
    )

    quote = parser.fetch_quote('/currencies/usd-rub')

    expect(quote[:price]).to eq(81.5)
    expect(warnings).to include('InvestingParser: anchor text not found, scanning from top of document')
  end
end
