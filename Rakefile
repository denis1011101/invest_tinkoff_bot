# frozen_string_literal: true

require 'rake'
require 'bundler/setup'
require 'dotenv/load'
require 'json'
require 'invest_tinkoff'
require_relative 'lib/market_cache'
require_relative 'lib/moex_iss'
require_relative 'lib/moex_cache_artifact'
require_relative 'lib/moex_cache_syncer'
require_relative 'lib/cache_health_monitor'
require_relative 'lib/strategy_helpers'
require_relative 'lib/wishlist_scanner'
require_relative 'lib/price_monitor'

def tinkoff_client
  @tinkoff_client ||= begin
    token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
    InvestTinkoff::V2::Client.new(token: token, sandbox: false)
  end
end

def first_account_id(client = tinkoff_client)
  accounts = client.grpc_users.accounts
  accounts.accounts.first&.id or abort('no accounts')
end

def truthy_env?(name)
  %w[1 true yes on].include?(ENV[name].to_s.strip.downcase)
end

task default: 'generate:all'

namespace :market_cache do
  desc 'Refresh market instruments cache. Usage: rake market_cache:refresh FORCE=true'
  task :refresh do
    force = ENV['FORCE'] == 'true'
    mc = TradingLogic::MarketCache.new(tinkoff_client)
    ok = mc.refresh_market_cache(force: force)
    abort('market cache refresh failed') unless ok

    puts "market cache refreshed -> #{TradingLogic::MarketCache::CACHE_PATH}"
  end
end

namespace :moex do
  desc 'Refresh MOEX index cache. Usage: rake moex:refresh INDEX=IMOEX'
  task :refresh do
    index = ENV['INDEX'] || 'IMOEX'
    iss = TradingLogic::MoexISS.new
    res = iss.index_constituents(index)
    abort('moex index refresh found no instruments') unless res && !res.empty?

    puts "moex index cache written -> #{TradingLogic::MoexISS::CACHE_PATH} (#{res.size} instruments)"
  end
end

namespace :moex_cache do
  desc 'Sync MOEX cache from local machine to remote server. Usage: rake moex_cache:sync INDEX=IMOEX DRY_RUN=1'
  task :sync do
    index = ENV['INDEX'] || 'IMOEX'
    syncer = TradingLogic::MoexCacheSyncer.new
    result = syncer.perform(index: index, dry_run: truthy_env?('DRY_RUN'))
    puts "moex cache #{result[:dry_run] ? 'validated' : 'synced'} -> #{result[:path]} sha256=#{result[:sha256]}"
  end

  desc 'Install uploaded MOEX cache artifact on server. Usage: rake moex_cache:install FILE=tmp/incoming/moex_index_cache.json SHA256=...'
  task :install do
    file = ENV['FILE'] || abort('Set FILE=path/to/incoming/moex_index_cache.json')
    sha256 = ENV.fetch('SHA256', nil)
    index = ENV['INDEX'] || 'IMOEX'
    result = TradingLogic::MoexCacheArtifact.install(
      file,
      destination: TradingLogic::MoexISS::CACHE_PATH,
      expected_index: index,
      sha256: sha256
    )

    TradingLogic::CacheHealthMonitor.new.check(targets: ['moex'])
    puts "moex cache installed -> #{result[:destination]} (#{result[:instruments_count]} instruments)"
  end
end

namespace :generate do
  desc 'Generate both market and moex caches (default)'
  task all: ['market_cache:refresh', 'moex:refresh']
end

namespace :index do
  # Smoke-тест резолва индекса перед включением автоматики: подтверждает, что приходят
  # минимум 4 дневные свечи (иначе trend навсегда останется UNKNOWN и покупок не будет).
  desc 'Check index resolution & daily candles. Usage: rake index:check INDEX_TICKER=IMOEX'
  task :check do
    require_relative 'lib/trading_logic'
    ticker = ENV.fetch('INDEX_TICKER', 'IMOEX')
    logic = TradingLogic::Runner.new(tinkoff_client, tickers: [])
    uid = logic.resolve_index_uid(ticker: ticker)
    closes = logic.index_daily_closes(instrument_id: uid)
    trend = logic.trend_from_closes(closes)
    puts "index=#{ticker} uid=#{uid.inspect}"
    puts "daily_closes=#{closes.size} last=#{closes.last(5).map { |c| c&.round(2) }.inspect}"
    puts "trend=#{trend.inspect}"
    if uid && closes.size >= 4 && trend != :unknown
      puts 'OK: индекс резолвится и отдаёт >=4 свечей — trend будет вычисляться.'
    else
      puts 'FAIL: индекс не резолвится или свечей < 4 — trend будет UNKNOWN, покупок не будет.'
      exit 1
    end
  end
end

namespace :wishlist do
  desc 'Run all wishlist scans and send to Telegram. Usage: rake wishlist:scan_all'
  task :scan_all do
    candle_sleep = (ENV['WISHLIST_CANDLE_SLEEP'] || '0.25').to_f
    scanner = TradingLogic::WishlistScanner.new(tinkoff_client, candle_sleep: candle_sleep)
    results = scanner.scan_all

    bot_token = ENV['WISHLIST_TELEGRAM_BOT_TOKEN'] || ENV.fetch('TELEGRAM_BOT_TOKEN', nil)
    chat_id = ENV['WISHLIST_TELEGRAM_CHAT_ID'] || ENV.fetch('TELEGRAM_CHAT_ID', nil)

    if bot_token && chat_id && !bot_token.empty? && !chat_id.empty?
      scanner.notify_telegram(results, bot_token: bot_token, chat_id: chat_id)
      puts 'Telegram notifications sent'
    end

    results.each { |name, data| puts "#{name}: #{data['matches'].size} matches" }
  end

  desc 'Run a single wishlist scan. Usage: rake wishlist:scan FILE=tmp/wishlists/52day_low.json'
  task :scan do
    file = ENV['FILE'] || abort('Set FILE=path/to/wishlist.json')
    config = JSON.parse(File.read(file))
    candle_sleep = (ENV['WISHLIST_CANDLE_SLEEP'] || '0.25').to_f
    scanner = TradingLogic::WishlistScanner.new(tinkoff_client, candle_sleep: candle_sleep)
    result = scanner.scan_one(config)
    puts "#{config['name']}: #{result['matches'].size} matches"
    result['matches'].each_with_index do |m, i|
      puts "  #{i + 1}. #{m['ticker']} — #{m['detail']}"
    end
  end
end

namespace :price_monitor do
  desc 'Fetch prices and send to Telegram. Usage: rake price_monitor:run'
  task :run do
    monitor = TradingLogic::PriceMonitor.new(tinkoff_client)
    results = monitor.fetch_all

    if results.empty?
      puts 'No results'
      next
    end

    results.each do |r|
      delta_str = if r[:delta]
                    " (#{'+' if r[:delta].positive?}#{r[:delta].round(2)})"
                  else
                    ''
                  end
      puts "#{r[:label]}: #{r[:price].round(2)}#{delta_str}"
    end

    bot_token = ENV['WISHLIST_TELEGRAM_BOT_TOKEN'] || ENV.fetch('TELEGRAM_BOT_TOKEN', nil)
    chat_id = ENV['WISHLIST_TELEGRAM_CHAT_ID'] || ENV.fetch('TELEGRAM_CHAT_ID', nil)

    if bot_token && chat_id && !bot_token.empty? && !chat_id.empty?
      monitor.notify_telegram(results, bot_token: bot_token, chat_id: chat_id)
      puts 'Telegram notification sent'
    end
  end
end

namespace :cache do
  desc 'Check market/MOEX cache freshness and notify Telegram on warning, critical, stale, or recovery transitions'
  task :health do
    results = TradingLogic::CacheHealthMonitor.new.check
    results.each do |name, info|
      age = info[:age_hours] ? format('%.1f', info[:age_hours]) : 'n/a'
      puts "#{name}: level=#{info[:level]} age_hours=#{age} updated_at=#{info[:updated_at]&.iso8601 || 'nil'}"
    end
  end
end

namespace :state do
  desc 'Restore strategy state from broker operations/orders. Usage: rake state:restore DAY=YYYY-MM-DD'
  task :restore do
    day = ENV['DAY'] || Time.now.utc.strftime('%Y-%m-%d')
    path = File.expand_path('tmp/strategy_state.json', __dir__)
    client = tinkoff_client
    account_id = first_account_id(client)

    state = TradingLogic::StrategyHelpers.load_state(path)
    TradingLogic::StrategyHelpers.restore_state_from_broker_if_empty!(client, account_id, state, day: day)
    TradingLogic::StrategyHelpers.save_state(path, state)
    puts "strategy state restored -> #{path}"
  end
end
