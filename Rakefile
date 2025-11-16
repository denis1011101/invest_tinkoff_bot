require 'rake'
require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require_relative 'lib/market_cache'
require_relative 'lib/moex_iss'

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
