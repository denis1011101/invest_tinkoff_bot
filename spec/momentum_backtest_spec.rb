# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/momentum_backtest'

RSpec.describe TradingLogic::MomentumBacktest do
  def bar(date, close, high: nil, low: nil)
    described_class::Bar.new(date: date, close: close, high: high || close, low: low || close)
  end

  # Окно momentum — четыре закрытия ДО дня входа; на входе просадка от high есть.
  def series(closes, entry:, future: [])
    bars = closes.each_with_index.map { |close, i| bar(format('2026-01-%02d', i + 1), close) }
    bars << entry
    bars.concat(future)
    { 'AAA' => { lot: 1, bars: bars } }
  end

  let(:dip_entry) { bar('2026-01-05', 100.0, high: 100.0, low: 98.0) }

  it 'reads the momentum window from the four closes before the entry day' do
    signals = described_class.collect_signals(
      series_by_ticker: series([10.0, 9.0, 11.0, 12.0], entry: dip_entry),
      dip_pct: 0.01, max_lot_rub: 1_000.0, lots_per_order: 1, horizons: [1], sell_threshold: 1.04
    )

    expect(signals.size).to eq(1)
    expect(signals.first[:verdicts]).to eq(
      'strict3' => false, 'last2' => true, 'two_of_three' => true, 'cumulative' => true
    )
    expect(signals.first[:date]).to eq('2026-01-05')
  end

  it 'treats dip as reached when the day low breaks below the trigger price' do
    signals = described_class.collect_signals(
      series_by_ticker: series([10.0, 11.0, 12.0, 13.0], entry: bar('2026-01-05', 100.0, high: 100.0, low: 99.5)),
      dip_pct: 0.01, max_lot_rub: 1_000.0, lots_per_order: 1, horizons: [1], sell_threshold: 1.04
    )
    expect(signals.first[:dip]).to be false

    deeper = described_class.collect_signals(
      series_by_ticker: series([10.0, 11.0, 12.0, 13.0], entry: bar('2026-01-05', 100.0, high: 100.0, low: 98.9)),
      dip_pct: 0.01, max_lot_rub: 1_000.0, lots_per_order: 1, horizons: [1], sell_threshold: 1.04
    )
    expect(deeper.first[:dip]).to be true
    # Вход по цене срабатывания dip, а не по закрытию.
    expect(deeper.first[:entry]).to be_within(1e-9).of(99.0)
  end

  it 'applies the lot price cap the same way the buy flow does' do
    signals = described_class.collect_signals(
      series_by_ticker: series([10.0, 11.0, 12.0, 13.0], entry: dip_entry),
      dip_pct: 0.01, max_lot_rub: 50.0, lots_per_order: 1, horizons: [1], sell_threshold: 1.04
    )
    expect(signals.first[:affordable]).to be false
  end

  it 'measures forward return from the entry price and target hits from later highs' do
    future = [bar('2026-01-06', 103.95, high: 104.0), bar('2026-01-07', 99.0, high: 99.0)]
    signals = described_class.collect_signals(
      series_by_ticker: series([10.0, 11.0, 12.0, 13.0], entry: dip_entry, future: future),
      dip_pct: 0.01, max_lot_rub: 1_000.0, lots_per_order: 1, horizons: [1, 2], sell_threshold: 1.04
    )

    signal = signals.first
    expect(signal[:returns][1]).to be_within(1e-6).of((103.95 / 99.0) - 1)
    expect(signal[:returns][2]).to be_within(1e-6).of((99.0 / 99.0) - 1)
    # 99.0 * 1.04 = 102.96, дневной high 104.0 его перекрывает.
    expect(signal[:reached_target]).to be true
  end

  it 'reports the funnel per rule and keeps one trade per day' do
    # Последний бар 06.01 тоже становится днём входа (окно сдвигается), но у него
    # low == high, поэтому dip его отсеивает — торгуемым остаётся только 05.01.
    both = {
      'AAA' => { lot: 1,
                 bars: [bar('2026-01-01', 10.0), bar('2026-01-02', 11.0), bar('2026-01-03', 12.0),
                        bar('2026-01-04', 13.0), bar('2026-01-05', 100.0, high: 100.0, low: 98.0),
                        bar('2026-01-06', 110.0, high: 110.0)] },
      'BBB' => { lot: 1,
                 bars: [bar('2026-01-01', 10.0), bar('2026-01-02', 9.0), bar('2026-01-03', 11.0),
                        bar('2026-01-04', 12.0), bar('2026-01-05', 100.0, high: 100.0, low: 98.0),
                        bar('2026-01-06', 110.0, high: 110.0)] }
    }

    result = described_class.run(
      series_by_ticker: both, dip_pct: 0.01, max_lot_rub: 1_000.0, lots_per_order: 1,
      horizons: [1], sell_threshold: 1.04
    )

    # strict3 проходит AAA дважды и BBB один раз, но dip оставляет один вход.
    expect(result['strict3']).to include(signals: 3, after_dip: 1, tradable: 1, trading_days: 1)
    # last2 добавляет вход BBB за 05.01 — на том же дне, где уже есть AAA.
    expect(result['last2']).to include(signals: 4, after_dip: 2, tradable: 2)
    expect(result['last2'][:trading_days]).to eq(1)
    expect(result['last2'][:one_per_day_returns][1][:count]).to eq(1)
    expect(result['last2'][:returns][1][:count]).to eq(2)
  end

  it 'returns empty stats instead of dividing by zero when a rule has no signals' do
    result = described_class.run(
      series_by_ticker: series([13.0, 12.0, 11.0, 10.0], entry: dip_entry),
      dip_pct: 0.01, max_lot_rub: 1_000.0, lots_per_order: 1, horizons: [1], sell_threshold: 1.04
    )

    expect(result[described_class::BASELINE][:signals]).to eq(1)
    expect(result['strict3'][:signals]).to eq(0)
    expect(result['strict3'][:returns][1]).to eq(count: 0, mean: nil, median: nil, win_rate: nil)
    expect(result['strict3'][:target_hit_rate]).to be_nil
  end
end
