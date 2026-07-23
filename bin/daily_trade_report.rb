#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'dotenv/load'
require 'logger'
require 'invest_tinkoff'
require_relative '../lib/utils'
require_relative '../lib/strategy_helpers'
require_relative '../lib/daily_trade_report'
require_relative '../lib/daily_report_delivery'

LOGGER = Logger.new($stdout)
LOGGER.level = Logger::INFO

ROOT = File.expand_path('..', __dir__)
MARKET_CACHE_PATH = File.join(ROOT, 'tmp', 'market_instruments_cache.json')
STATE_PATH = File.join(ROOT, 'tmp', 'daily_trade_report_state.json')
ARCHIVE_DIR = File.join(ROOT, 'logs', 'daily_reports')

def truthy?(name)
  %w[1 true yes on].include?(ENV[name].to_s.strip.downcase)
end

def telegram_creds
  bot = ENV['DAILY_REPORT_TELEGRAM_BOT_TOKEN'] || ENV.fetch('TELEGRAM_BOT_TOKEN', nil)
  chat = ENV['DAILY_REPORT_TELEGRAM_CHAT_ID'] || ENV.fetch('TELEGRAM_CHAT_ID', nil)
  [bot, chat]
end

def build_client
  token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
  InvestTinkoff::V2::Client.new(token: token, sandbox: false)
end

def notify_failure(delivery, bot, chat, dry_run)
  text = '⚠️ Не удалось сформировать торговый отчёт. Подробности в journald.'
  if dry_run
    puts text
  elsif bot && chat && !bot.empty? && !chat.empty?
    delivery.deliver({ day: 'error', text: text }, bot_token: bot, chat_id: chat, force: true)
  end
end

dry_run = truthy?('DRY_RUN')
force = truthy?('FORCE_SEND')
report_day = ENV.fetch('REPORT_DAY', nil)
bot, chat = telegram_creds

delivery = TradingLogic::DailyReportDelivery.new(state_path: STATE_PATH, archive_dir: ARCHIVE_DIR, logger: LOGGER)

begin
  client = build_client
  report = TradingLogic::DailyTradeReport.new(
    client: client, market_cache_path: MARKET_CACHE_PATH, logger: LOGGER
  )
  result = report.build(report_day)
rescue TradingLogic::DailyTradeReport::BrokerError => e
  LOGGER.error("daily report broker error: #{e.class}: #{e.message}")
  notify_failure(delivery, bot, chat, dry_run)
  exit 1
end

unless dry_run || (bot && chat && !bot.to_s.empty? && !chat.to_s.empty?)
  LOGGER.error('daily report: Telegram credentials missing')
  exit 1
end

# Реальная отправка неполного текущего дня (до cutoff) или будущей даты пометит
# день отправленным и заблокирует вечерний cron. Разрешаем только через FORCE_SEND.
if !dry_run && !force && report.premature?(report_day)
  LOGGER.info("daily report: window for #{result[:day]} not closed yet (or future date); " \
              'skipping real send. Use FORCE_SEND=1 to override or DRY_RUN=1 to preview.')
  exit 0
end

sent = delivery.deliver(result, bot_token: bot, chat_id: chat, dry_run: dry_run, force: force)
if sent
  LOGGER.info("daily report ok for #{result[:day]} (dry_run=#{dry_run})")
else
  LOGGER.error("daily report delivery failed for #{result[:day]}")
  exit 1
end
