# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'net/http'
require 'uri'
require_relative 'utils'

module TradingLogic
  # Ежедневный Telegram-отчёт о реально исполненных сделках за rolling-24ч окно
  # (от предыдущего cutoff до текущего). Источник сделок — только
  # GetOperationsByCursor, не логи стратегии и не strategy_state.json.
  class DailyTradeReport
    class BrokerError < StandardError; end

    Config = Struct.new(:offset, :time_label, :cutoff, :index, keyword_init: true)

    def initialize(client:, account_id: nil, now: Time.now.utc, config: self.class.config_from_env,
                   market_cache_path: nil, logger: nil)
      @client = client
      @account_id = account_id
      @now = now.utc
      @config = config
      @figi_ticker = market_cache_path ? StrategyHelpers.build_figi_ticker_map(market_cache_path) : {}
      @ticker_cache = {}
      @logger = logger
    end

    def self.config_from_env(env = ENV)
      Config.new(
        offset: env['DAILY_REPORT_UTC_OFFSET'] || '+05:00',
        time_label: env['DAILY_REPORT_TIME_LABEL'] || 'YEKT',
        cutoff: env['DAILY_REPORT_CUTOFF'] || '21:00',
        index: env['DAILY_REPORT_INDEX'] || 'IMOEX'
      )
    end

    # Отчётная дата в локальной таймзоне (по умолчанию — сегодня в offset).
    def report_day(report_day_str = nil)
      return Date.parse(report_day_str) unless report_day_str.to_s.strip.empty?

      local = @now + offset_seconds
      Date.new(local.year, local.month, local.day)
    end

    # Rolling-24ч окно: [ (D-1) cutoff , D cutoff ) в UTC.
    def window_for(day)
      hh, mm = @config.cutoff.split(':').map(&:to_i)
      to_utc = Time.new(day.year, day.month, day.day, hh, mm, 0, @config.offset).utc
      from_utc = to_utc - 86_400
      [from_utc, to_utc]
    end

    def build(report_day_str = nil)
      day = report_day(report_day_str)
      from_utc, to_utc = window_for(day)
      operations = fetch_operations(from: from_utc, to: to_utc)
      trades = operations.select { |op| trade?(op) }
      fees = operations.select { |op| fee?(op) }
      aggregates = aggregate(day, trades, fees)
      index = index_snapshot(day)
      # daily_yield брокер отдаёт только за текущий торговый день — для
      # исторического REPORT_DAY он не соответствует дате отчёта, поэтому не выводим.
      portfolio = day == report_day(nil) ? portfolio_snapshot : { ok: false, reason: :historical }
      text = format_message(day, aggregates, index, portfolio, trades)
      { day: day.iso8601, text: text, aggregates: aggregates, index: index, portfolio: portfolio }
    end

    private

    def offset_seconds
      sign = @config.offset.start_with?('-') ? -1 : 1
      hh, mm = @config.offset.sub(/\A[+-]/, '').split(':').map(&:to_i)
      sign * ((hh * 3600) + (mm * 60))
    end

    # -- операции брокера с полной пагинацией -----------------------------------

    def account_id
      @account_id ||= @client.grpc_users.accounts.accounts.first&.id or
        raise(BrokerError, 'no broker account available')
    end

    def fetch_operations(from:, to:)
      items = []
      cursor = nil
      seen = Set.new
      loop do
        resp = @client.grpc_operations.operations_by_cursor(
          account_id: account_id, from: from, to: to, cursor: cursor, limit: 1000
        )
        raise BrokerError, 'operations_by_cursor returned nil' if resp.nil?

        items.concat(Array(resp.items))
        cursor = next_cursor(resp, seen)
        break unless cursor
      end
      items
    rescue StandardError => e
      raise BrokerError, "#{e.class}: #{e.message}" unless e.is_a?(BrokerError)

      raise
    end

    def next_cursor(resp, seen)
      return nil unless resp.respond_to?(:has_next) && resp.has_next

      # has_next=true, но курсора для продолжения нет/он повторился — это аномалия
      # API. Молча завершить = показать неполный список сделок как полный, поэтому
      # для финансового отчёта считаем это ошибкой, а не концом пагинации.
      nc = resp.respond_to?(:next_cursor) ? resp.next_cursor.to_s : ''
      raise BrokerError, 'pagination anomaly: has_next set but next_cursor is empty or repeated' if nc.empty? || seen.include?(nc)

      seen << nc
      nc
    end

    def trade?(op)
      executed?(op) && %w[OPERATION_TYPE_BUY OPERATION_TYPE_SELL].include?(op.type.to_s)
    end

    def fee?(op)
      executed?(op) && op.type.to_s == 'OPERATION_TYPE_BROKER_FEE'
    end

    def executed?(op)
      op.respond_to?(:state) && op.state.to_s == 'OPERATION_STATE_EXECUTED'
    end

    def buy?(op)
      op.type.to_s == 'OPERATION_TYPE_BUY'
    end

    # -- агрегаты ----------------------------------------------------------------

    def aggregate(day, trades, fees)
      buys, sells = trades.partition { |op| buy?(op) }
      {
        day: day.iso8601,
        buys_count: buys.size,
        sells_count: sells.size,
        buy_turnover: buys.sum { |op| payment_abs(op) }.round(2),
        sell_turnover: sells.sum { |op| payment_abs(op) }.round(2),
        fees: fees_total(trades, fees).round(2),
        realized: sells.empty? ? 0.0 : nil
      }
    end

    # Без двойного счёта: приоритет отдельным BROKER_FEE, иначе commission у сделок.
    def fees_total(trades, fees)
      return fees.sum { |op| payment_abs(op) } unless fees.empty?

      trades.sum do |op|
        c = op.respond_to?(:commission) ? Utils.q_to_decimal(op.commission) : nil
        c ? c.abs : 0.0
      end
    end

    def payment_abs(op)
      (Utils.q_to_decimal(op.payment) || 0.0).abs
    end

    # -- индекс IMOEX ------------------------------------------------------------

    def index_snapshot(day)
      uid = resolve_index_uid(@config.index)
      return { ok: false, reason: :no_uid } unless uid

      candles = index_daily_candles(uid, day)
      current = candles.find { |c| candle_date(c) == day }
      return { ok: false, reason: :no_today } unless current

      prev = candles.select { |c| candle_date(c) < day }.max_by { |c| Utils.candle_time_utc(c) }
      return { ok: false, reason: :no_prev } unless prev

      build_index_delta(current, prev)
    rescue StandardError => e
      @logger&.warn("index snapshot failed: #{e.class}: #{e.message}")
      { ok: false, reason: :error }
    end

    def build_index_delta(current, prev)
      cur_close = Utils.q_to_decimal(current.close)
      prev_close = Utils.q_to_decimal(prev.close)
      delta = cur_close - prev_close
      {
        ok: true, current: cur_close, previous: prev_close,
        delta_points: delta.round(2),
        delta_percent: (prev_close.zero? ? 0.0 : (delta / prev_close * 100)).round(2),
        high: Utils.q_to_decimal(current.high), low: Utils.q_to_decimal(current.low)
      }
    end

    def resolve_index_uid(ticker)
      list = @client.grpc_instruments.indicatives
      list.find { |i| i.respond_to?(:ticker) && i.ticker.to_s.upcase == ticker.to_s.upcase }&.uid
    rescue StandardError
      nil
    end

    def index_daily_candles(uid, day)
      to = Time.new(day.year, day.month, day.day, 23, 59, 59, @config.offset).utc + 1
      resp = Utils.fetch_candles(@client, instrument_id: uid, from: to - (14 * 86_400), to: to, interval: day_interval)
      Array(resp&.candles)
    end

    def day_interval
      ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY
    end

    def candle_date(candle)
      t = Utils.candle_time_utc(candle)
      return nil unless t

      local = t + offset_seconds
      Date.new(local.year, local.month, local.day)
    end

    # -- портфель (весь, вкл. старые позиции) -----------------------------------

    def portfolio_snapshot
      port = @client.grpc_operations.portfolio(account_id: account_id)
      yield_abs = port.respond_to?(:daily_yield) ? Utils.q_to_decimal(port.daily_yield) : nil
      yield_rel = port.respond_to?(:daily_yield_relative) ? Utils.q_to_decimal(port.daily_yield_relative) : nil
      return { ok: false } if yield_abs.nil? && yield_rel.nil?

      { ok: true, daily_yield: yield_abs&.round(2), daily_yield_relative: yield_rel&.round(2) }
    rescue StandardError => e
      @logger&.warn("portfolio snapshot failed: #{e.class}: #{e.message}")
      { ok: false }
    end

    # -- тикеры ------------------------------------------------------------------

    def resolve_ticker(op)
      figi = op.figi.to_s
      return op.respond_to?(:name) ? op.name.to_s : figi if figi.empty?
      return @ticker_cache[figi] if @ticker_cache.key?(figi)

      @ticker_cache[figi] = lookup_ticker(figi, op)
    end

    def lookup_ticker(figi, op)
      cached = @figi_ticker[figi].to_s.strip
      return cached.upcase unless cached.empty?

      begin
        tk = @client.grpc_instruments.get_instrument_by(:figi, figi)&.ticker.to_s.strip
        return tk.upcase unless tk.empty?
      rescue StandardError => e
        @logger&.debug("get_instrument_by failed for #{figi}: #{e.class}: #{e.message}")
      end

      name = op.respond_to?(:name) ? op.name.to_s.strip : ''
      name.empty? ? figi : name
    end

    # -- форматирование (plain text, без Markdown) ------------------------------

    def format_message(day, agg, index, portfolio, trades)
      lines = []
      lines << "📊 Торговый отчёт за #{day.strftime('%d.%m.%Y')}"
      lines << "Окно 24ч до #{@config.cutoff} #{@config.time_label}"
      lines << ''
      lines.concat(format_index(index))
      lines << ''
      lines.concat(format_totals(agg))
      lines.concat(format_portfolio(portfolio))
      lines << ''
      lines.concat(format_trades(trades))
      lines.join("\n")
    end

    def format_index(index)
      return ["#{@config.index}: данные временно недоступны."] unless index[:ok]

      arrow, word = index_direction(index[:delta_points])
      [
        "#{@config.index}: #{fmt(index[:current])}",
        "#{arrow} #{word} на #{fmt(index[:delta_points].abs)} п. (#{signed_pct(index[:delta_percent])})",
        "Предыдущее закрытие: #{fmt(index[:previous])}",
        "Диапазон дня: #{fmt(index[:low])}–#{fmt(index[:high])}"
      ]
    end

    def index_direction(delta)
      return ['▲', 'вырос'] if delta.positive?
      return ['▼', 'упал'] if delta.negative?

      ['▬', 'без изменений']
    end

    def format_totals(agg)
      lines = [
        "Сделки за 24ч: #{agg[:buys_count]} покупок / #{agg[:sells_count]} продаж",
        "Покупки: #{fmt(agg[:buy_turnover])} ₽",
        "Продажи: #{fmt(agg[:sell_turnover])} ₽",
        "Комиссии: #{fmt(agg[:fees])} ₽"
      ]
      lines << "Реализованный результат: #{agg[:realized].nil? ? 'н/д (нет cost basis)' : "#{fmt(agg[:realized])} ₽"}"
      lines
    end

    def format_portfolio(portfolio)
      return [] unless portfolio[:ok]

      rel = portfolio[:daily_yield_relative]
      abs = portfolio[:daily_yield]
      pct = rel ? " (#{signed_pct(rel)})" : ''
      ['', "Портфель (текущий торговый день брокера): #{abs ? "#{signed(abs)} ₽" : 'н/д'}#{pct}",
       'Включает изменение старых позиций.']
    end

    def format_trades(trades)
      return ['Сделок сегодня не было.'] if trades.empty?

      sorted = trades.sort_by { |op| Utils.timestamp_to_utc(op.date) || Time.at(0) }
      sorted.map { |op| format_trade_line(op) }
    end

    def format_trade_line(op)
      t = Utils.timestamp_to_utc(op.date)
      hhmm = t ? (t + offset_seconds).strftime('%H:%M') : '--:--'
      side = buy?(op) ? 'BUY ' : 'SELL'
      price = Utils.q_to_decimal(op.price)
      qty = op.respond_to?(:quantity_done) ? op.quantity_done.to_i : 0
      "#{hhmm} #{side} #{resolve_ticker(op).ljust(6)} ×#{qty} @ #{fmt(price)} = #{fmt(payment_abs(op))} ₽"
    end

    # Число с группировкой тысяч пробелом и 2 знаками.
    def fmt(value)
      return 'н/д' if value.nil?

      whole, frac = format('%.2f', value).split('.')
      sign = whole.start_with?('-') ? '-' : ''
      digits = whole.delete('-').reverse.scan(/\d{1,3}/).join(' ').reverse
      "#{sign}#{digits}.#{frac}"
    end

    def signed(value)
      "#{'+' if value.positive?}#{fmt(value)}"
    end

    def signed_pct(value)
      "#{'+' if value.positive?}#{format('%.2f', value)}%"
    end
  end
end
