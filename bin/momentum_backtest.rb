#!/usr/bin/env ruby
# frozen_string_literal: true

# Сравнение вариантов MOMENTUM_RULE на истории дневных свечей по тому же
# универсуму IMOEX∩market, который использует SIDE/DOWN-ветка стратегии.
#
# Только чтение: ни одной заявки не отправляется.
#
#   bundle exec ruby bin/momentum_backtest.rb              # 180 дней
#   BACKTEST_DAYS=365 bundle exec ruby bin/momentum_backtest.rb
#   BACKTEST_REFRESH=1 ...                                 # игнорировать кеш свечей

require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require 'json'
require 'logger'
require 'time'
require_relative '../lib/utils'
require_relative '../lib/strategy_helpers'
require_relative '../lib/momentum_backtest'

LOGGER = Logger.new($stderr)
LOGGER.level = Logger.const_get(ENV.fetch('LOG_LEVEL', 'INFO').upcase)

ROOT = File.expand_path('..', __dir__)
# Универсум должен совпадать с боевым, а локальные кеши легко отстают — пути
# переопределяются, чтобы можно было подсунуть снимок с сервера.
MARKET_CACHE_PATH = ENV['BACKTEST_MARKET_CACHE'] || File.join(ROOT, 'tmp', 'market_instruments_cache.json')
MOEX_INDEX_CACHE_PATH = ENV['BACKTEST_INDEX_CACHE'] || File.join(ROOT, 'tmp', 'moex_index_cache.json')
CANDLE_CACHE_PATH = File.join(ROOT, 'tmp', 'momentum_backtest_candles.json')

DAYS = (ENV['BACKTEST_DAYS'] || '180').to_i
DIP_PCT = (ENV['DIP_PCT'] || '0.01').to_f
MAX_LOT_RUB = (ENV['MAX_LOT_RUB'] || '600.0').to_f
LOTS_PER_ORDER = (ENV['LOTS_PER_ORDER'] || '1').to_i
SELL_THRESHOLD = (ENV['SELL_THRESHOLD_SIDE'] || '1.04').to_f
REFRESH = %w[1 true yes on].include?(ENV['BACKTEST_REFRESH'].to_s.downcase)
# trigger (по умолчанию) — цена срабатывания dip, как в бою; close — контроль.
ENTRY_AT = ENV['BACKTEST_ENTRY'].to_s.downcase == 'close' ? :close : :trigger
DAY_INTERVAL = Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY

def intersection_tickers
  market = TradingLogic::StrategyHelpers.load_cache_normalized(MARKET_CACHE_PATH)
  index  = TradingLogic::StrategyHelpers.load_cache_normalized(MOEX_INDEX_CACHE_PATH)
  abort("empty market cache at #{MARKET_CACHE_PATH}") if market.empty?
  abort("empty index cache at #{MOEX_INDEX_CACHE_PATH}") if index.empty?

  (market.map { |i| i['ticker'] }.compact & index.map { |i| i['ticker'] }.compact).uniq.sort
end

def load_candle_cache
  return {} if REFRESH || !File.exist?(CANDLE_CACHE_PATH)

  cached = JSON.parse(File.read(CANDLE_CACHE_PATH))
  return {} unless cached['days'].to_i >= DAYS && cached['fetched_on'] == Time.now.utc.strftime('%Y-%m-%d')

  LOGGER.info("using cached candles from #{CANDLE_CACHE_PATH}")
  cached['series'] || {}
rescue StandardError => e
  LOGGER.warn("candle cache unreadable (#{e.class}: #{e.message}) — refetching")
  {}
end

def fetch_series(client, tickers)
  cached = load_candle_cache
  return cached unless cached.empty?

  series = {}
  tickers.each_with_index do |ticker, position|
    share = TradingLogic::StrategyHelpers.resolve_tradable_share(client, ticker, logger: LOGGER)
    next LOGGER.debug("skip #{ticker} — not tradable") unless share

    bars = fetch_bars(client, share[:figi])
    next LOGGER.debug("skip #{ticker} — no candles") if bars.size < 6

    series[ticker] = { 'lot' => share[:lot], 'bars' => bars }
    LOGGER.info("#{position + 1}/#{tickers.size} #{ticker}: #{bars.size} bars") if ((position + 1) % 10).zero?
  end

  File.write(CANDLE_CACHE_PATH, JSON.generate(
                                  'days' => DAYS, 'fetched_on' => Time.now.utc.strftime('%Y-%m-%d'), 'series' => series
                                ))
  series
end

def fetch_bars(client, figi)
  response = client.grpc_market_data.candles(
    figi: figi, from: Time.now.utc - (DAYS * 86_400), to: Time.now.utc, interval: DAY_INTERVAL
  )
  TradingLogic::Utils.completed_daily_candles(response&.candles || [], now: Time.now.utc).filter_map do |candle|
    date = TradingLogic::Utils.timestamp_to_utc(candle.time)&.strftime('%Y-%m-%d')
    close = TradingLogic::Utils.q_to_decimal(candle.close)
    next unless date && close

    { 'date' => date, 'close' => close,
      'high' => TradingLogic::Utils.q_to_decimal(candle.high),
      'low' => TradingLogic::Utils.q_to_decimal(candle.low) }
  end
rescue StandardError => e
  LOGGER.debug("candles failed for #{figi}: #{e.class}: #{e.message}")
  []
end

def to_bars(series)
  series.transform_values do |entry|
    {
      lot: entry['lot'] || 1,
      bars: entry['bars'].map do |bar|
        TradingLogic::MomentumBacktest::Bar.new(
          date: bar['date'], close: bar['close'], high: bar['high'], low: bar['low']
        )
      end
    }
  end
end

# Снос самого рынка: медиана close->close по всем бумагам и всем дням, без единого
# фильтра. Отделяет «наш вход плохой» от «рынок за период падал».
def drift_reference(series, horizons)
  horizons.to_h do |horizon|
    values = series.values.flat_map do |entry|
      bars = entry[:bars]
      (0...[bars.size - horizon, 0].max).filter_map do |i|
        (bars[i + horizon].close / bars[i].close) - 1.0 if bars[i].close&.positive?
      end
    end
    [horizon, values.empty? ? nil : TradingLogic::MomentumBacktest.median(values)]
  end
end

def pct(value)
  value.nil? ? '   н/д' : format('%+6.2f%%', value * 100)
end

def share(value)
  value.nil? ? '  н/д' : format('%5.1f%%', value * 100)
end

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

tickers = intersection_tickers
LOGGER.info("universe IMOEX∩market: #{tickers.size} tickers, #{DAYS} days back")
series = to_bars(fetch_series(client, tickers))
abort('no usable series — check caches and token') if series.empty?

covered = series.values.flat_map { |entry| entry[:bars].map(&:date) }.uniq.sort
horizons = TradingLogic::MomentumBacktest::DEFAULT_HORIZONS
results = TradingLogic::MomentumBacktest.run(
  series_by_ticker: series, dip_pct: DIP_PCT, max_lot_rub: MAX_LOT_RUB,
  lots_per_order: LOTS_PER_ORDER, horizons: horizons, sell_threshold: SELL_THRESHOLD,
  entry_at: ENTRY_AT
)

puts
puts "Универсум: #{series.size} бумаг, #{covered.size} торговых дней (#{covered.first}..#{covered.last})"
puts "dip_pct=#{DIP_PCT} max_lot_rub=#{MAX_LOT_RUB} lots=#{LOTS_PER_ORDER} sell_threshold=#{SELL_THRESHOLD}"
puts "dip считается по дневной OHLC (верхняя оценка), цена входа: #{ENTRY_AT}."
puts

puts 'правило         сигналов после dip   по цене   дней 1+'
results.each do |rule, stats|
  puts format('%-14s %9d %9d %9d %9d', rule, stats[:signals], stats[:after_dip], stats[:tradable],
              stats[:trading_days])
end

puts
puts "Доходность всех проходящих сигналов (удержание N дней), N = #{horizons.join('/')}:"
puts format('%-14s %-38s %-38s %8s', 'правило', 'медиана по горизонтам', 'доля прибыльных', "до +#{((SELL_THRESHOLD - 1) * 100).round}%")
results.each do |rule, stats|
  medians = horizons.map { |h| pct(stats[:returns][h][:median]) }.join(' ')
  wins = horizons.map { |h| share(stats[:returns][h][:win_rate]) }.join(' ')
  puts format('%-14s %-38s %-38s %8s', rule, medians, wins, share(stats[:target_hit_rate]))
end
drift = drift_reference(series, horizons)
puts format('%-14s %-38s', 'рынок c→c', horizons.map { |h| pct(drift[h]) }.join(' '))

puts
puts 'Одна покупка в день (как в проде), медиана по горизонтам:'
results.each do |rule, stats|
  medians = horizons.map { |h| pct(stats[:one_per_day_returns][h][:median]) }.join(' ')
  counts = horizons.map { |h| stats[:one_per_day_returns][h][:count] }.max
  puts format('%-14s %-38s  сделок=%d', rule, medians, counts)
end
puts
