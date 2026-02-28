# frozen_string_literal: true

require 'rake'
require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require_relative 'lib/market_cache'
require_relative 'lib/moex_iss'
require_relative 'lib/strategy_helpers'
require_relative 'lib/wishlist_scanner'
require_relative 'lib/price_monitor'

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

task default: 'generate:all'

namespace :market_cache do
  desc 'Refresh market instruments cache. Usage: rake market_cache:refresh FORCE=true'
  task :refresh do
    force = ENV['FORCE'] == 'true'
    mc = TradingLogic::MarketCache.new(client)
    ok = mc.refresh_market_cache(force: force)
    puts ok ? "market cache refreshed -> #{TradingLogic::MarketCache::CACHE_PATH}" : 'market cache refresh failed'
  end
end

namespace :moex do
  desc 'Refresh MOEX index cache. Usage: rake moex:refresh INDEX=IMOEX'
  task :refresh do
    index = ENV['INDEX'] || 'IMOEX'
    iss = TradingLogic::MoexISS.new
    res = iss.index_constituents(index)
    if res && !res.empty?
      puts "moex index cache written -> #{TradingLogic::MoexISS::CACHE_PATH} (#{res.size} instruments)"
    else
      puts 'moex index refresh found no instruments'
    end
  end
end

namespace :generate do
  desc 'Generate both market and moex caches (default)'
  task all: ['market_cache:refresh', 'moex:refresh']
end

namespace :wishlist do
  desc 'Run all wishlist scans and send to Telegram. Usage: rake wishlist:scan_all'
  task :scan_all do
    candle_sleep = (ENV['WISHLIST_CANDLE_SLEEP'] || '0.25').to_f
    scanner = TradingLogic::WishlistScanner.new(client, candle_sleep: candle_sleep)
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
    scanner = TradingLogic::WishlistScanner.new(client, candle_sleep: candle_sleep)
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
    monitor = TradingLogic::PriceMonitor.new(client)
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

namespace :state do
  desc 'Restore strategy state from broker operations/orders. Usage: rake state:restore DAY=YYYY-MM-DD'
  task :restore do
    day = ENV['DAY'] || Time.now.utc.strftime('%Y-%m-%d')
    path = File.expand_path('tmp/strategy_state.json', __dir__)
    accounts = client.grpc_users.accounts
    account_id = accounts.accounts.first&.id or abort('no accounts')

    state = TradingLogic::StrategyHelpers.load_state(path)
    TradingLogic::StrategyHelpers.restore_state_from_broker_if_empty!(client, account_id, state, day: day)
    TradingLogic::StrategyHelpers.save_state(path, state)
    puts "strategy state restored -> #{path}"
  end
end
