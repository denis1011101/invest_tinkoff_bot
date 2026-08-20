# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/position_sizing'

RSpec.describe TradingLogic::PositionSizing do
  # Закрытия индекса с заданным ростом за последние 5 шагов.
  def closes(growth_pct)
    base = 100.0
    [base, base, base, base, base, base * (1 + growth_pct)]
  end

  def sizer(trend:, index_closes: [], env: {}, max_order_rub: 10_000.0)
    described_class.from_env(
      trend: trend, index_closes: index_closes, max_order_rub: max_order_rub, env: env
    )
  end

  describe '.from_env' do
    it 'takes the maximum size when the index grows above the strong threshold' do
      expect(sizer(trend: :up, index_closes: closes(0.03)).lots_for(price_per_lot: 500.0)).to eq(3)
    end

    it 'takes the middle size in a weak UP trend' do
      expect(sizer(trend: :up, index_closes: closes(0.005)).lots_for(price_per_lot: 500.0)).to eq(2)
    end

    it 'takes the middle size in UP when the index history is too short for growth' do
      expect(sizer(trend: :up, index_closes: [100.0]).lots_for(price_per_lot: 500.0)).to eq(2)
    end

    it 'takes the minimum size in SIDE and DOWN regardless of growth' do
      expect(sizer(trend: :side, index_closes: closes(0.05)).lots_for(price_per_lot: 500.0)).to eq(1)
      expect(sizer(trend: :down, index_closes: closes(0.05)).lots_for(price_per_lot: 500.0)).to eq(1)
    end

    it 'buys nothing when the trend is unknown' do
      expect(sizer(trend: :unknown, index_closes: closes(0.05)).lots_for(price_per_lot: 500.0)).to eq(0)
    end

    it 'honours the env ladder' do
      env = { 'LOTS_MAX' => '5', 'LOTS_UP' => '4', 'LOTS_UP_STRONG_PCT' => '0.01' }
      strong = sizer(trend: :up, index_closes: closes(0.02), env: env)
      weak = sizer(trend: :up, index_closes: closes(0.001), env: env)

      expect(strong.lots_for(price_per_lot: 100.0)).to eq(5)
      expect(weak.lots_for(price_per_lot: 100.0)).to eq(4)
    end

    it 'falls back to the fixed size when DYNAMIC_LOTS=0' do
      fixed = described_class.from_env(
        trend: :up, index_closes: closes(0.05), lots_per_order: 2,
        max_order_rub: 10_000.0, env: { 'DYNAMIC_LOTS' => '0' }
      )

      expect(fixed.lots_for(price_per_lot: 500.0)).to eq(2)
      expect(fixed.explain[:mode]).to eq('fixed')
    end
  end

  describe 'order value ceiling' do
    it 'cuts the size down to what MAX_LOT_RUB allows' do
      strong = sizer(trend: :up, index_closes: closes(0.05), max_order_rub: 1_200.0)

      expect(strong.lots_for(price_per_lot: 500.0)).to eq(2)
    end

    it 'rejects an instrument whose single lot is above the ceiling' do
      strong = sizer(trend: :up, index_closes: closes(0.05), max_order_rub: 1_000.0)

      expect(strong.lots_for(price_per_lot: 1_500.0)).to eq(0)
    end

    it 'ignores a missing or non-positive price' do
      strong = sizer(trend: :up, index_closes: closes(0.05))

      expect(strong.lots_for(price_per_lot: nil)).to eq(0)
      expect(strong.lots_for(price_per_lot: 0.0)).to eq(0)
    end
  end

  describe 'cash ceiling' do
    it 'cuts the size down to available cash including the commission buffer' do
      strong = sizer(trend: :up, index_closes: closes(0.05))

      # 1010 рублей хватает ровно на один лот по 1000 с подушкой 1%.
      expect(strong.lots_for(price_per_lot: 1_000.0, cash_available: 1_010.0)).to eq(1)
      expect(strong.lots_for(price_per_lot: 1_000.0, cash_available: 1_009.0)).to eq(0)
    end

    it 'clamps an already sized order without raising it' do
      strong = sizer(trend: :up, index_closes: closes(0.05))

      expect(strong.clamp_to_cash(3, price_per_lot: 100.0, cash_available: 250.0)).to eq(2)
      expect(strong.clamp_to_cash(1, price_per_lot: 100.0, cash_available: 100_000.0)).to eq(1)
      expect(strong.clamp_to_cash(3, price_per_lot: 100.0, cash_available: 0.0)).to eq(0)
    end
  end

  describe '.min_lots' do
    it 'is the dynamic floor when sizing is dynamic' do
      expect(described_class.min_lots(lots_per_order: 3, env: {})).to eq(1)
      expect(described_class.min_lots(lots_per_order: 3, env: { 'LOTS_MIN' => '2' })).to eq(2)
    end

    it 'is the fixed size when sizing is disabled' do
      expect(described_class.min_lots(lots_per_order: 3, env: { 'DYNAMIC_LOTS' => '0' })).to eq(3)
    end
  end

  describe '.index_growth' do
    it 'measures the change across the lookback window' do
      expect(described_class.index_growth([100.0, 101.0, 102.0, 103.0], lookback: 2)).to be_within(1e-9).of((103.0 / 101.0) - 1)
    end

    it 'is nil without enough closes' do
      expect(described_class.index_growth([100.0], lookback: 5)).to be_nil
      expect(described_class.index_growth([], lookback: 5)).to be_nil
    end
  end
end
