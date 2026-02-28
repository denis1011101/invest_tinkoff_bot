#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require 'json'
require_relative '../lib/wishlist_scanner'

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

candle_sleep = (ENV['WISHLIST_CANDLE_SLEEP'] || '0.25').to_f
scanner = TradingLogic::WishlistScanner.new(client, candle_sleep: candle_sleep)

results = if ARGV[0]
            config = JSON.parse(File.read(ARGV[0]))
            { config['name'] => scanner.scan_one(config) }
          else
            scanner.scan_all
          end

bot_token = ENV['WISHLIST_TELEGRAM_BOT_TOKEN'] || ENV.fetch('TELEGRAM_BOT_TOKEN', nil)
chat_id = ENV['WISHLIST_TELEGRAM_CHAT_ID'] || ENV.fetch('TELEGRAM_CHAT_ID', nil)

if bot_token && chat_id && !bot_token.empty? && !chat_id.empty?
  scanner.notify_telegram(results, bot_token: bot_token, chat_id: chat_id)
  puts 'Telegram notifications sent'
else
  puts 'Telegram not configured, results saved to disk only'
end

results.each do |name, data|
  puts "#{name}: #{data['matches'].size} matches"
end
