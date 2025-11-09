require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'
require_relative '../lib/trading_logic'
require 'securerandom'
require 'time'
require 'json'
require 'fileutils'

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

# параметры стратегии
TICKERS = %w[SBER ROSN VTBR]
MAX_LOT_RUB = 1_000.0
DIP_PCT = 0.01
DAY = ::Tinkoff::Public::Invest::Api::Contract::V1::CandleInterval::CANDLE_INTERVAL_DAY

logic = TradingLogic::Runner.new(
  client,
  tickers: TICKERS,
  max_lot_rub: MAX_LOT_RUB,
  dip_pct: DIP_PCT,
  telegram_bot_token: ENV['TELEGRAM_BOT_TOKEN'],
  telegram_chat_id: ENV['TELEGRAM_CHAT_ID']
)

STATE_PATH = File.expand_path('../tmp/strategy_state.json', __dir__)
FileUtils.mkdir_p(File.dirname(STATE_PATH))

def load_state
  return { 'last_buy' => {}, 'last_sell' => {} } unless File.exist?(STATE_PATH)
  JSON.parse(File.read(STATE_PATH))
rescue
  { 'last_buy' => {}, 'last_sell' => {} }
end

def save_state(state)
  File.write(STATE_PATH, JSON.pretty_generate(state))
end

def today_key
  Time.now.utc.strftime('%Y-%m-%d')
end

def acted_today?(state, action, ticker)
  day = today_key
  ((state[action] || {})[day] || {})[ticker] == true
end

def mark_action!(state, action, ticker)
  day = today_key
  state[action] ||= {}
  state[action][day] ||= {}
  state[action][day][ticker] = true
end

begin
  accounts = client.grpc_users.accounts
  account_id = accounts.accounts.first.id or abort('no accounts')

  # Индекс IMOEX: пробуем найти напрямую, иначе TMOS/SBMX как прокси
  index_figi = begin
    resp = client.grpc_instruments.find_instrument(query: 'IMOEX')
    resp.instruments.first&.figi
  rescue InvestTinkoff::GRPC::Error
    nil
  end
  if index_figi.nil?
    index_figi = %w[TMOS SBMX].lazy.map { |ticker|
      begin
        r = client.grpc_instruments.find_instrument(query: ticker)
        r.instruments.first&.figi
      rescue InvestTinkoff::GRPC::Error
        nil
      end
    }.find(&:itself)
  end

  trend = logic.trend(index_figi)

  universe = logic.build_universe
  if universe.empty?
    puts 'no instruments under 1000 RUB per lot'
    exit 0
  end

  state = load_state

  # Принудительная продажа всех лотов при профите >= +30% (до основной логики)
  begin
    port_force = client.grpc_operations.portfolio(account_id: account_id)
    positions_force = port_force.positions
    positions_map = positions_force.each_with_object({}) { |p, h| h[p.figi] = p }

    universe.each do |it|
      p = positions_map[it[:figi]] or next
      qty = p.quantity.units.to_i
      next if qty <= 0
      next unless logic.should_force_exit?(p, it[:figi])

      cur_price = logic.last_price_for(it[:figi])
      resp = logic.confirm_and_place_order(
        account_id: account_id,
        figi: it[:figi],
        quantity: qty, # продаём весь объём
        price: cur_price,
        direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
        order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      if resp
        puts "FORCE SELL +30% #{it[:ticker]} qty=#{qty} @#{cur_price} (order_id=#{resp.order_id})"
        # mark_action! не обязателен: позиция обнулится, повтор не пройдёт
      else
        puts "FORCE SELL #{it[:ticker]} skipped / not confirmed"
      end
    end
  rescue InvestTinkoff::GRPC::Error => e
    puts "Force exit gRPC error: #{e.class} #{e.message}"
  end

  case trend
  when :up
    puts 'Trend: UP — intraday dip BUY (max once per ticker per day)'
    universe.each do |it|
      next if acted_today?(state, 'last_buy', it[:ticker])
      next unless logic.should_buy?(it)

      resp = logic.confirm_and_place_order(
        account_id: account_id,
        figi: it[:figi],
        quantity: it[:lot],
        price: it[:price],
        direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_BUY,
        order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      if resp
        puts "BUY #{it[:ticker]} lot=#{it[:lot]} @#{it[:price]} (order_id=#{resp.order_id})"
        mark_action!(state, 'last_buy', it[:ticker])
      else
        puts "BUY #{it[:ticker]} skipped / not confirmed"
      end
    end

  when :down
    puts 'Trend: DOWN — SELL one lot if >= avg * 1.10 (max once per ticker per day)'
    port = client.grpc_operations.portfolio(account_id: account_id)
    positions = port.positions

    universe.each do |it|
      next if acted_today?(state, 'last_sell', it[:ticker])
      p = positions.find { |pos| pos.figi == it[:figi] }
      next unless p
      qty_units = p.quantity.units.to_i
      next if qty_units <= 0
      next unless logic.should_sell?(p, it)

      sell_qty = [qty_units, it[:lot]].min
      resp = logic.confirm_and_place_order(
        account_id: account_id,
        figi: it[:figi],
        quantity: sell_qty,
        price: logic.last_price_for(it[:figi]),
        direction: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderDirection::ORDER_DIRECTION_SELL,
        order_type: ::Tinkoff::Public::Invest::Api::Contract::V1::OrderType::ORDER_TYPE_LIMIT
      )
      if resp
        puts "SELL #{it[:ticker]} qty=#{sell_qty} (order_id=#{resp.order_id})"
        mark_action!(state, 'last_sell', it[:ticker])
      else
        puts "SELL #{it[:ticker]} skipped / not confirmed"
      end
    end

  else
    puts 'Trend: SIDE — do nothing'
  end

  save_state(state)
rescue InvestTinkoff::GRPC::Error => e
  puts "gRPC error: #{e.class} #{e.message}"
end
