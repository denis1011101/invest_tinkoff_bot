# frozen_string_literal: true

require 'json'
require_relative 'strategy_helpers'

module TradingLogic
  # Ручной разбор pending SELL (после SELL PENDING STUCK): тот же путь, что и в
  # прогоне стратегии — GetOrders, затем терминальный статус GetOrderState и общая
  # финализация, включая pending_sells, last_sell, sell_orders и снимки истории
  # других заявок. Без apply только показывает изменения. С apply берёт flock
  # крона и перечитывает state под ним: иначе прогон стратегии, писавший state
  # параллельно, затёр бы результат или наоборот.
  class SellOrderRecovery
    SECTIONS = %w[last_sell pending_sells sell_orders].freeze
    DEFAULT_LOCK_PATH = '/tmp/current_strategy.lock'

    def initialize(client:, account_id:, state_path:, lock_path: DEFAULT_LOCK_PATH, now: -> { Time.now.utc })
      @client = client
      @account_id = account_id
      @state_path = state_path
      @lock_path = lock_path
      @now = now
    end

    def run(order_id: nil, apply: false)
      return resolve(order_id: order_id, apply: false) unless apply

      File.open(@lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        next { ok: false, reason: :strategy_running } unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        resolve(order_id: order_id, apply: true)
      end
    end

    def self.format(report)
      return "refused: #{REFUSALS.fetch(report[:reason], report[:reason])}" unless report[:ok]

      lines = report[:orders].map { |order| format_order(order) }
      lines << 'no pending SELL orders matched' if lines.empty?
      lines << (report[:changes].empty? ? 'changes: none' : 'changes:')
      report[:changes].each { |change| lines << "  #{format_change(change)}" }
      lines << if report[:applied] then 'applied -> state saved'
               elsif report[:changes].empty? then 'nothing to write'
               else 'dry run — nothing written; rerun with APPLY=1'
               end
      lines.join("\n")
    end

    REFUSALS = {
      strategy_running: 'strategy run holds the lock, retry in a minute',
      active_orders_unavailable: 'GetOrders unavailable — cannot tell an active order from a finished one'
    }.freeze

    def self.format_order(order)
      head = "pending SELL #{order[:key]} #{order[:ticker]}:"
      case order[:outcome]
      when :active then "#{head} still active at the broker — nothing to change"
      when :unknown then "#{head} outcome not confirmed by the broker — nothing to change"
      else "#{head} outcome=#{order[:outcome]}"
      end
    end

    def self.format_change(change)
      before = change[:before].nil? ? '(none)' : JSON.generate(change[:before])
      after = change[:after].nil? ? '(removed)' : JSON.generate(change[:after])
      "#{change[:section]}[#{change[:key]}]: #{before} -> #{after}"
    end

    private

    def helpers
      StrategyHelpers
    end

    def resolve(order_id:, apply:)
      original = helpers.load_state(@state_path)
      snapshot = helpers.fetch_active_orders(@client, @account_id)
      return { ok: false, reason: :active_orders_unavailable } unless snapshot[:ok]

      working = deep_copy(original)
      orders = selected(working, order_id).map do |key, info|
        { key: key, ticker: info['ticker'], outcome: resolve_one(working, original, key, info, snapshot) }
      end
      changes = diff(original, working)
      helpers.save_state(@state_path, working) if apply && !changes.empty?
      { ok: true, orders: orders, changes: changes, applied: apply && !changes.empty? }
    end

    def selected(state, order_id)
      state['pending_sells'].to_a.select do |key, info|
        order_id.to_s.empty? || [key, info['broker_order_id'], info['client_order_id']].include?(order_id.to_s)
      end
    end

    def resolve_one(working, original, key, info, snapshot)
      return :active if helpers.find_active_pending_order(info, snapshot)

      outcome = helpers.resolve_missing_sell!(@client, @account_id, working, key, info, now: @now.call)
      # Неподтверждённый исход ничего не меняет, даже счётчик попыток: ручная
      # проверка не должна приближать или откладывать алерт SELL PENDING STUCK.
      working['pending_sells'][key] = deep_copy(original['pending_sells'][key]) if outcome == :unknown
      outcome
    end

    def diff(before, after)
      SECTIONS.flat_map do |section|
        was = before[section] || {}
        now = after[section] || {}
        (was.keys | now.keys).filter_map do |key|
          next if was[key] == now[key]

          { section: section, key: key, before: was[key], after: now[key] }
        end
      end
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
