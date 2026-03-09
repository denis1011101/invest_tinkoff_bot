# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/trading_logic'

RSpec.describe TradingLogic::Runner do
  let(:client) { double('client') }
  let(:market_data) { double('market_data') }
  let(:instruments) { double('instruments') }

  before do
    allow(client).to receive(:grpc_market_data).and_return(market_data)
    allow(client).to receive(:grpc_instruments).and_return(instruments)
  end

  subject { described_class.new(client, tickers: %w[SBER ROSN], max_lot_rub: 1_000.0, dip_pct: 0.01) }

  def q(units, nano = 0)
    OpenStruct.new(units: units, nano: nano)
  end

  it 'converts protobuf money (units/nano) to decimal' do
    expect(subject.q_to_decimal(q(123, 500_000_000))).to eq(123.5)
  end

  describe '#trend' do
    it 'returns :up for 3 consecutive rising closes' do
      closes = [q(10), q(11), q(12), q(13)].map { |x| OpenStruct.new(close: x) }
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: closes))
      expect(subject.trend('IDX')).to eq(:up)
    end

    it 'returns :down for 3 consecutive falling closes' do
      closes = [q(20), q(19), q(18), q(17)].map { |x| OpenStruct.new(close: x) }
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: closes))
      expect(subject.trend('IDX')).to eq(:down)
    end

    it 'returns :side when not enough data' do
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: []))
      expect(subject.trend('IDX')).to eq(:side)
    end
  end

  describe 'dip_today? and should_buy?' do
    it 'detects intraday dip when cur <= today_high*(1-dip_pct)' do
      # today_high = 100, cur = 99 -> dip if dip_pct = 0.01 => 100*(1-0.01)=99 -> cur <= 99 => true
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(99))]))
      highs = [OpenStruct.new(high: q(100))]
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: highs))
      expect(subject.dip_today?('FIGI')).to be true
      expect(subject.should_buy?({ figi: 'FIGI', price: 99 })).to be true
    end

    it 'returns false if no price or no highs' do
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: []))
      allow(market_data).to receive(:candles).and_return(OpenStruct.new(candles: []))
      expect(subject.dip_today?('FIGI')).to be false
    end
  end

  describe 'selling helpers' do
    it 'should_sell? returns true when current >= avg * 1.10 (default side threshold 1.04)' do
      position = OpenStruct.new(quantity: OpenStruct.new(units: 2), average_position_price: q(100))
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(110))]))
      it_hash = { figi: 'F' }
      expect(subject.should_sell?(position, it_hash)).to be true
    end

    it 'should_sell? uses lower threshold for :down trend' do
      position = OpenStruct.new(quantity: OpenStruct.new(units: 2), average_position_price: q(100))
      # price 103 => 1.03 ratio, above DOWN threshold (1.02) but below SIDE (1.04)
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(103))]))
      it_hash = { figi: 'F' }
      expect(subject.should_sell?(position, it_hash, trend: :down)).to be true
      expect(subject.should_sell?(position, it_hash, trend: :side)).to be false
    end

    it 'should_sell? uses higher threshold for :up trend' do
      position = OpenStruct.new(quantity: OpenStruct.new(units: 2), average_position_price: q(100))
      # price 105 => 1.05 ratio, above SIDE (1.04) but below UP (1.10)
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(105))]))
      it_hash = { figi: 'F' }
      expect(subject.should_sell?(position, it_hash, trend: :up)).to be false
      expect(subject.should_sell?(position, it_hash, trend: :side)).to be true
    end

    it 'sell_threshold_for_trend respects ENV overrides' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SELL_THRESHOLD_DOWN').and_return('1.05')
      expect(subject.sell_threshold_for_trend(:down)).to eq(1.05)
    end

    it 'profit_multiple and should_force_exit? works' do
      position = OpenStruct.new(average_position_price: q(100))
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(131))]))
      expect(subject.profit_multiple(position, 'F')).to be_within(0.001).of(1.31)
      expect(subject.should_force_exit?(position, 'F')).to be true
    end
  end

  describe '#build_universe' do
    it 'builds universe entries when instrument and price present' do
      allow(instruments).to receive(:share_by_ticker).with(ticker: 'SBER', class_code: 'TQBR').and_return(
        OpenStruct.new(instrument: OpenStruct.new(figi: 'F1', lot: 1))
      )
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(300))]))
      u = subject.build_universe
      expect(u.size).to be >= 1
      expect(u.first[:ticker]).to eq('SBER')
      expect(u.first[:figi]).to eq('F1')
    end

    it 'filters out by max_lot_rub' do
      # set tiny max_lot to force filter
      runner = described_class.new(client, tickers: %w[SBER], max_lot_rub: 10.0)
      allow(instruments).to receive(:share_by_ticker).and_return(OpenStruct.new(instrument: OpenStruct.new(figi: 'F1',
                                                                                                           lot: 1)))
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(300))]))
      expect(runner.build_universe).to eq([])
    end

    it 'does not request volume metrics when volume features are disabled' do
      runner = described_class.new(client, tickers: %w[SBER], volume_compare_mode: 'none')
      allow(instruments).to receive(:share_by_ticker).and_return(OpenStruct.new(instrument: OpenStruct.new(figi: 'F1',
                                                                                                           lot: 1)))
      allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(300))]))

      expect(runner).not_to receive(:relative_daily_volume)
      expect(runner).not_to receive(:daily_turnover_rub)

      runner.build_universe
    end
  end

  describe '#relative_daily_volume' do
    it 'uses exactly configured lookback window and returns nil if not enough daily candles' do
      runner = described_class.new(client, tickers: %w[SBER], volume_lookback_days: 5)
      short = 5.times.map { OpenStruct.new(volume: 100) }
      allow(TradingLogic::Utils).to receive(:fetch_candles).and_return(OpenStruct.new(candles: short))
      expect(runner.relative_daily_volume('F1')).to be_nil

      enough = 6.times.map { OpenStruct.new(volume: 100) }
      enough[-1] = OpenStruct.new(volume: 200)
      allow(TradingLogic::Utils).to receive(:fetch_candles).and_return(OpenStruct.new(candles: enough))
      expect(runner.relative_daily_volume('F1')).to be_within(0.001).of(2.0)
    end
  end

  # Helper: строим mock дневную свечу с заданными low/high/close
  def day_candle(low:, high:, close: nil, time_offset_days: 0)
    base = Time.utc(2024, 1, 1).to_i + (time_offset_days * 86_400)
    OpenStruct.new(
      low: q(low),
      high: q(high),
      close: q(close || ((low + high) / 2)),
      time: OpenStruct.new(seconds: base)
    )
  end

  describe 'support/resistance levels' do
    # Строим 15 свечей: pivot_window=2, на индексе 3 явный low=80 (support), на индексе 11 явный high=130 (resistance)
    def make_candles_with_levels
      data = [
        { low: 95, high: 105 }, # 0
        { low: 90, high: 102 }, # 1
        { low: 85, high: 100 }, # 2
        { low: 80, high: 95  }, # 3 — pivot low (support at 80)
        { low: 85, high: 100 }, # 4
        { low: 90, high: 102 }, # 5
        { low: 92, high: 108 }, # 6
        { low: 94, high: 112 }, # 7
        { low: 95, high: 118 }, # 8
        { low: 96, high: 122 }, # 9
        { low: 97, high: 126 }, # 10
        { low: 98, high: 130 }, # 11 — pivot high (resistance at 130)
        { low: 96, high: 124 }, # 12
        { low: 94, high: 120 }, # 13
        { low: 92, high: 115 }  # 14 (последняя — будет "закрытой")
      ]
      data.each_with_index.map { |d, i| day_candle(low: d[:low], high: d[:high], time_offset_days: i) }
    end

    let(:runner_with_levels) do
      described_class.new(
        client,
        tickers: %w[SBER],
        use_levels: true,
        level_pivot_window: 2,
        level_proximity_pct: 0.05,
        level_sell_min_profit: 1.005,
        level_cluster_pct: 0.03
      )
    end

    before do
      candles = make_candles_with_levels
      # Возвращаем все свечи кроме "сегодняшней" (последняя = сегодня по времени)
      # Для теста используем все свечи с временем в прошлом
      allow(TradingLogic::Utils).to receive(:fetch_candles).and_return(OpenStruct.new(candles: candles))
      allow(TradingLogic::Utils).to receive(:now_utc).and_return(Time.utc(2024, 1, 20)) # после всех свечей
    end

    describe '#compute_support_resistance' do
      it 'finds at least one support level around 80' do
        levels = runner_with_levels.compute_support_resistance('FIGI')
        supports = levels.select { |l| l[:type] == :support }
        expect(supports).not_to be_empty
        expect(supports.any? { |s| (s[:price] - 80).abs < 5 }).to be true
      end

      it 'finds at least one resistance level around 130' do
        levels = runner_with_levels.compute_support_resistance('FIGI')
        resistances = levels.select { |l| l[:type] == :resistance }
        expect(resistances).not_to be_empty
        expect(resistances.any? { |r| (r[:price] - 130).abs < 10 }).to be true
      end

      it 'returns [] when not enough candles for pivot window' do
        allow(TradingLogic::Utils).to receive(:fetch_candles).and_return(OpenStruct.new(candles: [day_candle(low: 90, high: 100)]))
        expect(runner_with_levels.compute_support_resistance('FIGI')).to eq([])
      end

      it 'returns [] on API error' do
        allow(TradingLogic::Utils).to receive(:fetch_candles).and_raise(StandardError, 'network error')
        expect(runner_with_levels.compute_support_resistance('FIGI')).to eq([])
      end

      it 'ignores candles from today when building levels' do
        candles = make_candles_with_levels + [day_candle(low: 1, high: 200, time_offset_days: 19)]
        allow(TradingLogic::Utils).to receive(:fetch_candles).and_return(OpenStruct.new(candles: candles))
        allow(TradingLogic::Utils).to receive(:now_utc).and_return(Time.utc(2024, 1, 20, 12, 0, 0))

        levels = runner_with_levels.compute_support_resistance('FIGI')

        expect(levels.any? { |level| level[:price] == 1 || level[:price] == 200 }).to be false
      end

      it 'returns [] when all candles are filtered out' do
        today_only = [day_candle(low: 90, high: 100, time_offset_days: 19)]
        allow(TradingLogic::Utils).to receive(:fetch_candles).and_return(OpenStruct.new(candles: today_only))
        allow(TradingLogic::Utils).to receive(:now_utc).and_return(Time.utc(2024, 1, 20, 12, 0, 0))

        expect(runner_with_levels.compute_support_resistance('FIGI')).to eq([])
      end
    end

    describe '#levels_for caching' do
      it 'calls compute_support_resistance only once per figi per run' do
        expect(runner_with_levels).to receive(:compute_support_resistance).with('FIGI').once.and_call_original
        runner_with_levels.levels_for('FIGI')
        runner_with_levels.levels_for('FIGI')
        runner_with_levels.levels_for('FIGI')
      end

      it 'recomputes levels after cache ttl expires' do
        runner = described_class.new(client, tickers: %w[SBER], use_levels: true, levels_cache_ttl_seconds: 1)
        allow(runner).to receive(:compute_support_resistance).with('FIGI').and_return([{ price: 80, type: :support }])

        now = Time.utc(2024, 1, 20, 10, 0, 0)
        allow(Time).to receive(:now).and_return(now, now, now + 2, now + 2)

        runner.levels_for('FIGI')
        runner.levels_for('FIGI')
        runner.levels_for('FIGI')

        expect(runner).to have_received(:compute_support_resistance).with('FIGI').twice
      end

      it 'recomputes levels when clustering params change on the same instance' do
        allow(runner_with_levels).to receive(:compute_support_resistance).with('FIGI').and_return([{ price: 80, type: :support }])

        runner_with_levels.levels_for('FIGI')
        runner_with_levels.instance_variable_set(:@level_cluster_pct, 0.05)
        runner_with_levels.levels_for('FIGI')

        expect(runner_with_levels).to have_received(:compute_support_resistance).with('FIGI').twice
      end
    end

    describe 'USE_LEVELS=false disables all level access' do
      let(:runner_no_levels) do
        described_class.new(client, tickers: %w[SBER], use_levels: false)
      end

      it 'nearest_support returns nil without hitting API' do
        expect(runner_no_levels).not_to receive(:compute_support_resistance)
        expect(runner_no_levels.nearest_support('FIGI', 100)).to be_nil
      end

      it 'nearest_resistance returns nil without hitting API' do
        expect(runner_no_levels).not_to receive(:compute_support_resistance)
        expect(runner_no_levels.nearest_resistance('FIGI', 100)).to be_nil
      end

      it 'should_buy? ignores levels even in :up trend' do
        allow(runner_no_levels).to receive(:dip_today?).and_return(true)
        allow(runner_no_levels).to receive(:volume_spike?).and_return(true)
        expect(runner_no_levels).not_to receive(:compute_support_resistance)
        expect(runner_no_levels.should_buy?({ figi: 'FIGI', price: 100 }, trend: :up)).to be true
      end
    end

    describe '#nearest_support and #nearest_resistance' do
      it 'returns nearest support below price' do
        sup = runner_with_levels.nearest_support('FIGI', 95)
        expect(sup).not_to be_nil
        expect(sup[:price]).to be <= 95
        expect(sup[:type]).to eq(:support)
      end

      it 'returns nearest resistance above price' do
        res = runner_with_levels.nearest_resistance('FIGI', 100)
        expect(res).not_to be_nil
        expect(res[:price]).to be >= 100
        expect(res[:type]).to eq(:resistance)
      end

      it 'returns nil when no support below price' do
        sup = runner_with_levels.nearest_support('FIGI', 5)
        expect(sup).to be_nil
      end
    end

    describe '#near_support? and #near_resistance?' do
      it 'returns true when price is within proximity_pct of support' do
        levels = runner_with_levels.levels_for('FIGI')
        support_price = levels.select { |l| l[:type] == :support }.map { |l| l[:price] }.min
        expect(support_price).not_to be_nil

        close_price = support_price * 1.03 # 3% above support, within 5%
        expect(runner_with_levels.near_support?('FIGI', close_price)).to be true
      end

      it 'returns false when price is far from support' do
        expect(runner_with_levels.near_support?('FIGI', 999)).to be false
      end

      it 'returns false when no resistance above price' do
        expect(runner_with_levels.near_resistance?('FIGI', 9999)).to be false
      end

      it 'returns true when price is within proximity_pct of resistance' do
        levels = runner_with_levels.levels_for('FIGI')
        resistance_price = levels.select { |l| l[:type] == :resistance }.map { |l| l[:price] }.max
        expect(resistance_price).not_to be_nil

        close_price = resistance_price * 0.98
        expect(runner_with_levels.near_resistance?('FIGI', close_price)).to be true
      end

      it 'returns false when support level price is zero' do
        allow(runner_with_levels).to receive(:nearest_support).with('FIGI', 10).and_return({ price: 0.0 })

        expect(runner_with_levels.near_support?('FIGI', 10)).to be false
      end

      it 'returns false when support level price is effectively zero' do
        allow(runner_with_levels).to receive(:nearest_support).with('FIGI', 10).and_return({ price: Float::EPSILON / 2 })

        expect(runner_with_levels.near_support?('FIGI', 10)).to be false
      end
    end

    describe '#should_buy? with levels (UP trend = hard filter)' do
      let(:runner_up) do
        described_class.new(
          client,
          tickers: %w[SBER],
          use_levels: true,
          level_pivot_window: 2,
          level_proximity_pct: 0.05,
          level_cluster_pct: 0.03
        )
      end

      before do
        candles = make_candles_with_levels
        allow(TradingLogic::Utils).to receive(:fetch_candles).and_return(OpenStruct.new(candles: candles))
        allow(TradingLogic::Utils).to receive(:now_utc).and_return(Time.utc(2024, 1, 20))
        allow(runner_up).to receive(:dip_today?).and_return(true)
        allow(runner_up).to receive(:volume_spike?).and_return(true)
      end

      it 'blocks buy in :up trend when price is far from support' do
        expect(runner_up.should_buy?({ figi: 'FIGI', price: 999 }, trend: :up)).to be false
      end

      it 'allows buy in :up trend when price is near support' do
        levels = runner_up.levels_for('FIGI')
        support_price = levels.select { |l| l[:type] == :support }.map { |l| l[:price] }.min
        expect(support_price).not_to be_nil

        near_price = support_price * 1.02
        expect(runner_up.should_buy?({ figi: 'FIGI', price: near_price }, trend: :up)).to be true
      end

      it 'graceful degradation: allows buy in :up when levels are empty' do
        allow(runner_up).to receive(:levels_for).and_return([])
        expect(runner_up.should_buy?({ figi: 'FIGI', price: 100 }, trend: :up)).to be true
      end

      it 'does not apply level filter in :side trend' do
        expect(runner_up.should_buy?({ figi: 'FIGI', price: 999 }, trend: :side)).to be true
      end

      it 'does not apply level filter in :down trend' do
        expect(runner_up.should_buy?({ figi: 'FIGI', price: 999 }, trend: :down)).to be true
      end
    end

    describe '#should_sell? with resistance level trigger' do
      let(:runner_sell) do
        described_class.new(
          client,
          tickers: %w[SBER],
          use_levels: true,
          level_pivot_window: 2,
          level_proximity_pct: 0.05,
          level_sell_min_profit: 1.005,
          level_cluster_pct: 0.03
        )
      end

      before do
        candles = make_candles_with_levels
        allow(TradingLogic::Utils).to receive(:fetch_candles).and_return(OpenStruct.new(candles: candles))
        allow(TradingLogic::Utils).to receive(:now_utc).and_return(Time.utc(2024, 1, 20))
      end

      it 'triggers sell when price near resistance with min profit met' do
        levels = runner_sell.levels_for('FIGI')
        res = levels.select { |l| l[:type] == :resistance }.map { |l| l[:price] }.max
        expect(res).not_to be_nil

        # avg buy at res * 0.97 (so profit ~3%, above 0.5% min)
        avg_price = (res * 0.97).to_i
        cur_price = (res * 0.99).to_i # within 5% of resistance

        position = OpenStruct.new(quantity: OpenStruct.new(units: 1), average_position_price: q(avg_price))
        allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(cur_price))]))

        expect(runner_sell.should_sell?(position, { figi: 'FIGI' })).to be true
      end

      it 'does not sell at resistance if min profit not met' do
        levels = runner_sell.levels_for('FIGI')
        res = levels.select { |l| l[:type] == :resistance }.map { |l| l[:price] }.max
        expect(res).not_to be_nil

        # bought right below resistance — no profit
        avg_price = (res * 0.999).to_i
        cur_price = (res * 0.999).to_i

        position = OpenStruct.new(quantity: OpenStruct.new(units: 1), average_position_price: q(avg_price))
        allow(market_data).to receive(:last_prices).and_return(OpenStruct.new(last_prices: [OpenStruct.new(price: q(cur_price))]))

        expect(runner_sell.should_sell?(position, { figi: 'FIGI' })).to be false
      end

      it 'reports debug info for nearest support and resistance' do
        info = runner_sell.level_debug_info('FIGI', 100)

        expect(info).to include('support=')
        expect(info).to include('resistance=')
        expect(info).to include('total levels:')
      end

      it 'merges nearby levels when cluster pct is large' do
        runner = described_class.new(client, tickers: %w[SBER], use_levels: true, level_cluster_pct: 0.5)
        levels = runner.send(:cluster_levels, [100.0, 105.0, 145.0], 0.5)

        expect(levels.size).to eq(1)
        expect(levels.first.last).to eq(3)
      end
    end
  end

  describe 'level settings validation' do
    it 'rejects non-positive pivot window' do
      expect do
        described_class.new(client, tickers: %w[SBER], level_pivot_window: 0)
      end.to raise_error(ArgumentError, /level_pivot_window must be > 0/)
    end

    it 'rejects negative proximity pct' do
      expect do
        described_class.new(client, tickers: %w[SBER], level_proximity_pct: -0.01)
      end.to raise_error(ArgumentError, /level_proximity_pct must be > 0/)
    end
  end

  describe 'volume-aware buy filters' do
    it 'requires relative volume spike when min_relative_volume is set' do
      runner = described_class.new(client, tickers: %w[SBER], min_relative_volume: 1.5)
      allow(runner).to receive(:dip_today?).and_return(true)
      allow(runner).to receive(:relative_daily_volume).and_return(1.8)

      expect(runner.should_buy?({ figi: 'F1', price: 100 })).to be true

      allow(runner).to receive(:relative_daily_volume).and_return(1.1)
      expect(runner.should_buy?({ figi: 'F1', price: 100 })).to be false
    end

    it 'can rank universe by relative volume or turnover' do
      runner = described_class.new(client, tickers: %w[SBER VTBR], volume_compare_mode: 'relative')
      universe = [
        { ticker: 'SBER', relative_volume: 1.2, daily_turnover_rub: 500.0 },
        { ticker: 'VTBR', relative_volume: 2.4, daily_turnover_rub: 100.0 }
      ]

      expect(runner.rank_universe_by_volume(universe).first[:ticker]).to eq('VTBR')

      runner_turnover = described_class.new(client, tickers: %w[SBER VTBR], volume_compare_mode: 'turnover')
      expect(runner_turnover.rank_universe_by_volume(universe).first[:ticker]).to eq('SBER')
    end
  end
end
