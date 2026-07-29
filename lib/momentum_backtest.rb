# frozen_string_literal: true

require_relative 'strategy_helpers'

module TradingLogic
  # Сравнение вариантов правила momentum-входа (см. StrategyHelpers::MOMENTUM_RULES)
  # на исторических дневных свечах.
  #
  # Считаем не только число прошедших первый фильтр кандидатов, но и то, что идёт
  # в проде дальше: dip и потолок цены лота. Разбор 29.07.2026 показал, что одного
  # счётчика кандидатов недостаточно — «девять прошедших momentum» это ещё не
  # девять сделок.
  #
  # ПРИБЛИЖЕНИЯ (важны при чтении результата):
  #   * dip считается по дневной OHLC: low <= high * (1 - dip_pct). Это ВЕРХНЯЯ
  #     оценка: боевой dip_today? сравнивает цену с running high, а дневной high
  #     мог быть достигнут уже после минимума — тогда в бою входа бы не было.
  #     Точный ответ даёт только реплей внутридневных свечей.
  #   * цена входа — high * (1 - dip_pct), то есть уровень, на котором dip_today?
  #     впервые становится истинным. Running high в этот момент не выше дневного,
  #     поэтому вход слегка пессимистичен.
  #   * выход моделируется как удержание до горизонта; отдельно считаем долю
  #     сделок, чей максимум дотянулся до sell_threshold в пределах max_horizon.
  module MomentumBacktest
    Bar = Struct.new(:date, :close, :high, :low, keyword_init: true)

    DEFAULT_HORIZONS = [1, 3, 5, 10].freeze
    BASELINE = 'no_momentum'

    module_function

    # series_by_ticker: { "SBER" => { lot: 1, bars: [Bar, ...] } }, bars по возрастанию даты.
    def run(series_by_ticker:, dip_pct:, max_lot_rub:, lots_per_order: 1,
            horizons: DEFAULT_HORIZONS, sell_threshold: 1.04, entry_at: :trigger)
      signals = collect_signals(
        series_by_ticker: series_by_ticker, dip_pct: dip_pct, max_lot_rub: max_lot_rub,
        lots_per_order: lots_per_order, horizons: horizons, sell_threshold: sell_threshold,
        entry_at: entry_at
      )

      # baseline — те же дни входа без momentum-условия вообще. Без него цифры
      # правил нечитаемы: непонятно, отбирает ли фильтр что-то или просто повторяет
      # рынок за период.
      rules = { BASELINE => summarize(signals, horizons: horizons) }
      StrategyHelpers::MOMENTUM_RULES.each do |rule|
        passing = signals.select { |signal| signal[:verdicts].fetch(rule) }
        rules[rule] = summarize(passing, horizons: horizons)
      end
      rules
    end

    # Один сигнал = (тикер, день входа). Все фильтры прода посчитаны заранее,
    # чтобы правила сравнивались на одной и той же выборке.
    def collect_signals(series_by_ticker:, dip_pct:, max_lot_rub:, lots_per_order:,
                        horizons:, sell_threshold:, entry_at: :trigger)
      max_horizon = horizons.max
      series_by_ticker.flat_map do |ticker, series|
        bars = series[:bars]
        lot = series[:lot] || 1
        (4...bars.size).filter_map do |index|
          window = bars[(index - 4)...index].map(&:close)
          entry_bar = bars[index]
          next unless entry_bar.high&.positive? && entry_bar.low

          build_signal(
            ticker: ticker, lot: lot, window: window, entry_bar: entry_bar,
            future: bars[(index + 1)..] || [], dip_pct: dip_pct, max_lot_rub: max_lot_rub,
            lots_per_order: lots_per_order, horizons: horizons, max_horizon: max_horizon,
            sell_threshold: sell_threshold, entry_at: entry_at
          )
        end
      end
    end

    def build_signal(ticker:, lot:, window:, entry_bar:, future:, dip_pct:, max_lot_rub:,
                     lots_per_order:, horizons:, max_horizon:, sell_threshold:, entry_at: :trigger)
      trigger = entry_bar.high * (1.0 - dip_pct)
      # :trigger — уровень, на котором dip_today? впервые истинен (как в бою).
      # :close — контроль: тот же набор входов, но по цене закрытия дня. Разница
      # между режимами и есть цена того, что бот покупает у дневного хая.
      entry = entry_at == :close ? entry_bar.close : trigger
      {
        ticker: ticker,
        date: entry_bar.date,
        verdicts: StrategyHelpers.momentum_verdicts(window),
        # dip и потолок цены всегда считаем по trigger: между режимами должна
        # меняться только измеряемая цена входа, а не сам набор сделок.
        dip: entry_bar.low <= trigger,
        affordable: (trigger * lot * lots_per_order) <= max_lot_rub,
        entry: entry,
        returns: horizons.to_h { |h| [h, forward_return(entry, future, h)] },
        reached_target: reached_target?(entry * sell_threshold, future, max_horizon)
      }
    end

    def forward_return(entry, future, horizon)
      bar = future[horizon - 1]
      return nil unless bar&.close&.positive? && entry.positive?

      (bar.close / entry) - 1.0
    end

    def reached_target?(target, future, max_horizon)
      window = future.first(max_horizon)
      return false if window.empty?

      window.any? { |bar| bar.high && bar.high >= target }
    end

    # Воронка строится в том же порядке, что и прод: momentum -> dip -> цена лота.
    def summarize(signals, horizons:)
      after_dip = signals.select { |signal| signal[:dip] }
      tradable = after_dip.select { |signal| signal[:affordable] }
      one_per_day = pick_one_per_day(tradable)
      {
        signals: signals.size,
        after_dip: after_dip.size,
        tradable: tradable.size,
        trading_days: one_per_day.size,
        returns: horizons.to_h { |h| [h, return_stats(tradable.map { |s| s[:returns][h] }.compact)] },
        one_per_day_returns: horizons.to_h { |h| [h, return_stats(one_per_day.map { |s| s[:returns][h] }.compact)] },
        target_hit_rate: rate(tradable.map { |signal| signal[:reached_target] }.compact)
      }
    end

    # Прод покупает одну бумагу в день, ранжируя кандидатов по близости к support;
    # уровни офлайн не воспроизводятся, поэтому берём детерминированный выбор по
    # алфавиту — произвольная, но несмещённая выборка из дневного набора.
    def pick_one_per_day(signals)
      signals.group_by { |signal| signal[:date] }
             .sort_by { |date, _| date.to_s }
             .map { |_, group| group.min_by { |signal| signal[:ticker] } }
    end

    def return_stats(values)
      return { count: 0, mean: nil, median: nil, win_rate: nil } if values.empty?

      { count: values.size, mean: mean(values), median: median(values),
        win_rate: rate(values.map(&:positive?)) }
    end

    def mean(values)
      values.sum / values.size
    end

    def median(values)
      sorted = values.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def rate(flags)
      return nil if flags.empty?

      flags.count(true).to_f / flags.size
    end
  end
end
