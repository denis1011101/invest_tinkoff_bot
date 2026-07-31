# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'net/http'
require 'uri'
require_relative 'utils'
require_relative 'trade_execution_extractor'
# StrategyHelpers использовался и раньше (build_figi_ticker_map), но подтягивался
# только через точку входа — при загрузке одного daily_trade_report был NameError.
require_relative 'strategy_helpers'

module TradingLogic
  # Ежедневный Telegram-отчёт о реально исполненных сделках за rolling-24ч окно
  # (от предыдущего cutoff до текущего). Источник сделок — только
  # GetOperationsByCursor, не логи стратегии и не strategy_state.json.
  class DailyTradeReport
    class BrokerError < StandardError; end

    Config = Struct.new(:offset, :time_label, :cutoff, :index, :operation_lookback_days, keyword_init: true)
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
        index: env['DAILY_REPORT_INDEX'] || 'IMOEX',
        operation_lookback_days: (env['DAILY_REPORT_OPERATION_LOOKBACK_DAYS'] || '7').to_i
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
      # GetOperationsByCursor filters by the order timestamp, while an execution
      # may happen hours later. Read an overlap and assign each individual fill by
      # trades_info.trades[].date instead of assigning the whole order by op.date.
      lookback_days = [@config.operation_lookback_days.to_i, 0].max
      query_from = from_utc - (lookback_days * 86_400)
      operations = fetch_operations(from: query_from, to: to_utc)
      extractor = TradeExecutionExtractor.new
      trades = extractor.extract(operations, from: from_utc, to: to_utc)
      fees = extractor.fees(operations, from: from_utc, to: to_utc)
      aggregates = aggregate(day, trades, fees)
      index = index_snapshot(day)
      # daily_yield брокер отдаёт только за текущий торговый день — для
      # исторического REPORT_DAY он не соответствует дате отчёта, поэтому не выводим.
      # Баланс всегда «на сейчас», поэтому в исторический отчёт он не идёт — иначе
      # текущий кэш читался бы как остаток на отчётную дату.
      current = day == report_day(nil)
      portfolio = current ? portfolio_snapshot : { ok: false, reason: :historical }
      balance = current ? balance_snapshot : { ok: false, reason: :historical }
      text = format_message(day, aggregates, index, portfolio, balance, trades)
      { day: day.iso8601, text: text, aggregates: aggregates, index: index, portfolio: portfolio,
        balance: balance, window_from: from_utc.iso8601, window_to: to_utc.iso8601,
        trades: structured_trades(trades) }
    rescue TradeExecutionExtractor::ExtractionError => e
      raise BrokerError, e.message
    end

    # Окно ещё не закрылось (текущий день до cutoff) или дата в будущем — реальную
    # отправку такого отчёта надо запрещать, иначе неполный отчёт займёт day в
    # state и вечерний cron ничего не пришлёт. DRY_RUN/FORCE_SEND — в обход.
    def premature?(report_day_str = nil)
      day = report_day(report_day_str)
      today = report_day(nil)
      return true if day > today

      _, to_utc = window_for(day)
      day == today && @now < to_utc
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
        c = op.respond_to?(:commission) ? op.commission : nil
        c ? c.to_f.abs : 0.0
      end
    end

    def payment_abs(op)
      return op.amount.to_f.abs if op.respond_to?(:amount)

      (Utils.q_to_decimal(op.payment) || 0.0).abs
    end

    # Структурированные сделки для JSONL-архива (помесячный анализ по бумагам).
    def structured_trades(trades)
      trades.sort_by { |op| Utils.timestamp_to_utc(op.date) || Time.at(0) }.map do |op|
        {
          time: Utils.timestamp_to_utc(op.date)&.iso8601,
          side: buy?(op) ? 'BUY' : 'SELL',
          ticker: resolve_ticker(op),
          qty: op.quantity.to_i,
          price: op.price,
          amount: payment_abs(op).round(2)
        }
      end
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

    # Один GetPortfolio на отчёт: его читают и portfolio_snapshot (daily_yield),
    # и balance_snapshot (итоговые суммы).
    def broker_portfolio
      return @broker_portfolio if defined?(@broker_portfolio)

      @broker_portfolio = @client.grpc_operations.portfolio(account_id: account_id)
    rescue StandardError => e
      @logger&.warn("portfolio fetch failed: #{e.class}: #{e.message}")
      @broker_portfolio = nil
    end

    def portfolio_snapshot
      port = broker_portfolio
      return { ok: false } unless port

      yield_abs = port.respond_to?(:daily_yield) ? Utils.q_to_decimal(port.daily_yield) : nil
      yield_rel = port.respond_to?(:daily_yield_relative) ? Utils.q_to_decimal(port.daily_yield_relative) : nil
      return { ok: false } if yield_abs.nil? && yield_rel.nil?

      { ok: true, daily_yield: yield_abs&.round(2), daily_yield_relative: yield_rel&.round(2) }
    end

    # Свободные рубли берём из GetPositions (money минус blocked), как в
    # cash-preflight стратегии: GetPortfolio отдаёт только суммарные деньги и
    # не показывает, сколько из них зажато под активными заявками.
    def balance_snapshot
      positions = positions_snapshot
      port = broker_portfolio
      return { ok: false } unless positions || port

      snapshot = { ok: true }
      if positions
        snapshot[:free_rub] = StrategyHelpers.available_currency_amount(positions, currency: 'rub').round(2)
        snapshot[:blocked_rub] = StrategyHelpers.currency_amount(
          StrategyHelpers.structured_value(positions, :blocked), 'rub'
        ).round(2)
      end
      snapshot.merge!(portfolio_totals(port)) if port
      snapshot
    rescue StandardError => e
      @logger&.warn("balance snapshot failed: #{e.class}: #{e.message}")
      { ok: false }
    end

    def positions_snapshot
      response = @client.positions(account_id: account_id)
      if response.respond_to?(:success?) && !response.success?
        raise(BrokerError, "GetPositions returned HTTP #{response.respond_to?(:http_code) ? response.http_code : '?'}")
      end

      response.respond_to?(:payload) ? response.payload : response
    rescue StandardError => e
      @logger&.warn("positions snapshot failed: #{e.class}: #{e.message}")
      nil
    end

    def portfolio_totals(port)
      {
        total: Utils.q_to_decimal(port.total_amount_portfolio)&.round(2),
        shares: Utils.q_to_decimal(port.total_amount_shares)&.round(2),
        currencies: Utils.q_to_decimal(port.total_amount_currencies)&.round(2),
        etf: Utils.q_to_decimal(port.total_amount_etf)&.round(2)
      }.compact
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

    def format_message(day, agg, index, portfolio, balance, trades)
      lines = []
      lines << "📊 Торговый отчёт за #{day.strftime('%d.%m.%Y')}"
      lines << "Окно 24ч до #{@config.cutoff} #{@config.time_label}"
      lines << ''
      lines.concat(format_index(index))
      lines << ''
      lines.concat(format_totals(agg))
      lines.concat(format_portfolio(portfolio))
      lines.concat(format_balance(balance))
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

    def format_balance(balance)
      return [] unless balance[:ok]

      lines = ['']
      if balance[:free_rub]
        blocked = balance[:blocked_rub].to_f
        # Заблокированное показываем только когда оно есть: ежедневное «0 ₽» — шум.
        suffix = blocked.positive? ? " (заблокировано #{fmt(blocked)} ₽)" : ''
        lines << "💰 Свободно: #{fmt(balance[:free_rub])} ₽#{suffix}"
      end
      if balance[:total]
        breakdown = portfolio_breakdown(balance)
        total_line = "Портфель: #{fmt(balance[:total])} ₽"
        total_line += " — #{breakdown}" unless breakdown.empty?
        lines << total_line
      end
      lines.size > 1 ? lines : []
    end

    def portfolio_breakdown(balance)
      parts = []
      parts << "акции #{fmt(balance[:shares])}" if balance[:shares]
      parts << "фонды #{fmt(balance[:etf])}" if balance[:etf]
      parts << "деньги #{fmt(balance[:currencies])}" if balance[:currencies]
      parts.join(' / ')
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
      price = op.price
      qty = op.quantity.to_i
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
