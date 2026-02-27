#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require_relative '../lib/price_monitor'

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

monitor = TradingLogic::PriceMonitor.new(client)
results = monitor.fetch_all

if results.empty?
  puts 'No results (instruments not found or market data unavailable)'
  exit
end

results.each do |r|
  delta_str = r[:delta] ? " (#{r[:delta] > 0 ? '+' : ''}#{r[:delta].round(2)})" : ''
  puts "#{r[:label]}: #{r[:price].round(2)}#{delta_str}"
end

bot_token = ENV['WISHLIST_TELEGRAM_BOT_TOKEN'] || ENV['TELEGRAM_BOT_TOKEN']
chat_id = ENV['WISHLIST_TELEGRAM_CHAT_ID'] || ENV['TELEGRAM_CHAT_ID']

if bot_token && chat_id && !bot_token.empty? && !chat_id.empty?
  monitor.notify_telegram(results, bot_token: bot_token, chat_id: chat_id)
  puts 'Telegram notification sent'
else
  puts 'Telegram not configured'
end
