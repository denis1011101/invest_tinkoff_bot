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
  if monitor.notify_telegram(results, bot_token: bot_token, chat_id: chat_id)
    puts 'Telegram notification sent'
  else
    abort 'Telegram notification failed'
  end
else
  puts 'Telegram not configured'
end
