require 'rake'
require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require_relative 'lib/market_cache'
require_relative 'lib/moex_iss'
require_relative 'lib/strategy_helpers'

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

task default: 'generate:all'

namespace :market_cache do
  desc 'Refresh market instruments cache. Usage: rake market_cache:refresh FORCE=true'
  task :refresh do
    force = ENV['FORCE'] == 'true'
    mc = TradingLogic::MarketCache.new(client)
    ok = mc.refresh_market_cache(force: force)
    puts ok ? "market cache refreshed -> #{TradingLogic::MarketCache::CACHE_PATH}" : "market cache refresh failed"
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
      puts "moex index refresh found no instruments"
    end
  end
end

namespace :generate do
  desc 'Generate both market and moex caches (default)'
  task all: ['market_cache:refresh', 'moex:refresh']
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
