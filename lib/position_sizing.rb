# frozen_string_literal: true

module TradingLogic
  # Динамический размер заявки: сколько лотов брать в текущем режиме рынка.
  #
  # Фиксированный LOTS_PER_ORDER одинаково рискует и в растущем рынке, и в падающем.
  # Здесь размер задаётся трендом индекса и силой его роста: DOWN/SIDE — минимум,
  # UP — средний размер, уверенный рост индекса — максимум.
  #
  # Сигнал только повышает ставку, а вниз её режут жёсткие потолки: число лотов
  # (LOTS_MAX), стоимость одной заявки (MAX_LOT_RUB) и реально доступный кэш.
  # При маленьком бюджете потолки важнее сигнала, поэтому любой из них может
  # урезать заявку до одного лота или до нуля — в последнем случае покупки нет.
  module PositionSizing
    DEFAULTS = {
      min_lots: 1,
      max_lots: 3,
      up_lots: 2,
      up_strong_pct: 0.02,
      index_lookback: 5,
      cash_buffer_rate: 0.01
    }.freeze

    # Считает лоты по одному снимку режима рынка: тренд и сила роста индекса
    # фиксируются на весь прогон, а рублёвый потолок и кэш применяются к каждой
    # бумаге отдельно — лот у всех разной цены.
    class Sizer
      attr_reader :trend, :growth, :base_lots, :min_lots, :max_lots, :max_order_rub, :dynamic

      def initialize(trend:, base_lots:, min_lots:, max_lots:, max_order_rub:, growth: nil,
                     cash_buffer_rate: DEFAULTS[:cash_buffer_rate], dynamic: true)
        @trend = trend
        @growth = growth
        @min_lots = [min_lots.to_i, 1].max
        @max_lots = [max_lots.to_i, @min_lots].max
        @base_lots = base_lots.to_i.clamp(0, @max_lots)
        @base_lots = @min_lots if @base_lots.positive? && @base_lots < @min_lots
        @max_order_rub = max_order_rub&.to_f
        @cash_buffer_rate = [cash_buffer_rate.to_f, 0.0].max
        @dynamic = dynamic
      end

      # Итоговое число лотов для конкретной бумаги; 0 означает «не покупаем».
      # cash_available — свободные рубли под эту заявку (уже за вычетом того, что
      # заняли предыдущие заявки этого прогона). nil — не ограничивать здесь,
      # тогда решение остаётся за отдельным cash-preflight.
      def lots_for(price_per_lot:, cash_available: nil)
        price_per_lot = price_per_lot.to_f
        return 0 unless price_per_lot.positive?
        return 0 unless @base_lots.positive?

        lots = @base_lots
        lots = [lots, (@max_order_rub / price_per_lot).floor].min if @max_order_rub&.positive?
        lots = [lots, affordable_lots(price_per_lot, cash_available)].min unless cash_available.nil?
        return 0 if lots < @min_lots

        lots
      end

      # Урезание уже согласованного размера под доступный кэш. Все денежные гейты
      # монотонны по стоимости заявки, поэтому уменьшать размер после их прохода
      # безопасно: меньшая сумма проходит там же, где прошла большая.
      def clamp_to_cash(lots, price_per_lot:, cash_available:)
        return 0 unless lots.to_i.positive?

        price_per_lot = price_per_lot.to_f
        return 0 unless price_per_lot.positive?

        lots = [lots.to_i, affordable_lots(price_per_lot, cash_available)].min
        return 0 if lots < @min_lots

        lots
      end

      def explain
        {
          mode: @dynamic ? 'dynamic' : 'fixed',
          trend: @trend,
          index_growth: @growth&.round(4),
          base_lots: @base_lots,
          min_lots: @min_lots,
          max_lots: @max_lots,
          max_order_rub: @max_order_rub
        }
      end

      def to_s
        explain.map { |k, v| "#{k}=#{v.inspect}" }.join(' ')
      end

      private

      # Комиссия и проскальзывание съедают часть кэша, поэтому лоты считаем по цене
      # с той же подушкой, что и BUY_CASH_BUFFER_RATE в cash-preflight.
      def affordable_lots(price_per_lot, cash_available)
        cash = cash_available.to_f
        return 0 unless cash.positive?

        (cash / (price_per_lot * (1.0 + @cash_buffer_rate))).floor
      end
    end

    module_function

    # Динамика включена по умолчанию; DYNAMIC_LOTS=0 возвращает прежнее поведение
    # с фиксированным LOTS_PER_ORDER.
    def dynamic_enabled?(env: ENV)
      env.fetch('DYNAMIC_LOTS', '1').to_s.strip != '0'
    end

    def from_env(trend:, index_closes: [], lots_per_order: 1, max_order_rub: nil, env: ENV, logger: nil)
      return fixed(lots_per_order, max_order_rub: max_order_rub, trend: trend) unless dynamic_enabled?(env: env)

      min_lots = env_int(env, 'LOTS_MIN', DEFAULTS[:min_lots])
      max_lots = env_int(env, 'LOTS_MAX', DEFAULTS[:max_lots])
      up_lots = env_int(env, 'LOTS_UP', DEFAULTS[:up_lots])
      strong_pct = env_float(env, 'LOTS_UP_STRONG_PCT', DEFAULTS[:up_strong_pct])
      lookback = env_int(env, 'LOTS_INDEX_LOOKBACK', DEFAULTS[:index_lookback])
      growth = index_growth(index_closes, lookback: lookback)

      sizer = Sizer.new(
        trend: trend,
        growth: growth,
        base_lots: base_lots_for(
          trend: trend, growth: growth, min_lots: min_lots, max_lots: max_lots,
          up_lots: up_lots, strong_pct: strong_pct
        ),
        min_lots: min_lots,
        max_lots: max_lots,
        max_order_rub: max_order_rub,
        cash_buffer_rate: env_float(env, 'BUY_CASH_BUFFER_RATE', DEFAULTS[:cash_buffer_rate])
      )
      logger&.info("position sizing: #{sizer}")
      sizer
    end

    # Нижняя граница размера заявки — ею фильтруется универсум: бумагу, которую
    # не взять максимальным размером, всё ещё можно взять минимальным.
    def min_lots(lots_per_order: 1, env: ENV)
      return [lots_per_order.to_i, 1].max unless dynamic_enabled?(env: env)

      [env_int(env, 'LOTS_MIN', DEFAULTS[:min_lots]), 1].max
    end

    def fixed(lots_per_order, max_order_rub: nil, trend: nil)
      lots = [lots_per_order.to_i, 0].max
      Sizer.new(
        trend: trend, base_lots: lots, min_lots: [lots, 1].max, max_lots: [lots, 1].max,
        max_order_rub: max_order_rub, dynamic: false
      )
    end

    # Базовая ставка режима рынка: чем увереннее растёт индекс, тем больше лотов.
    # UNKNOWN — данных по индексу нет, покупок не делаем вовсе (0 лотов).
    def base_lots_for(trend:, growth:, min_lots:, max_lots:, up_lots:, strong_pct:)
      case trend
      when :up
        growth && strong_pct.positive? && growth >= strong_pct ? max_lots : up_lots
      when :side, :down
        min_lots
      else
        0
      end
    end

    # Рост индекса за окно закрытий: last/first - 1. nil, если данных не хватает —
    # тогда UP берёт средний размер, а не максимальный.
    def index_growth(closes, lookback: DEFAULTS[:index_lookback])
      lookback = lookback.to_i
      return nil unless lookback.positive?

      values = Array(closes).compact.map(&:to_f).select(&:positive?)
      return nil if values.size < 2

      window = values.last(lookback + 1)
      (window.last / window.first) - 1.0
    end

    def env_int(env, key, default)
      raw = env[key].to_s.strip
      raw.empty? ? default : raw.to_i
    end

    def env_float(env, key, default)
      raw = env[key].to_s.strip
      raw.empty? ? default : raw.to_f
    end
  end
end
