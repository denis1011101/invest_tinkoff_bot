# frozen_string_literal: true

require_relative 'utils'

module TradingLogic
  # Converts broker order operations into immutable fill-level rows. The order
  # timestamp is deliberately ignored for attribution: only the exchange fill
  # timestamp decides which report window owns an execution.
  class TradeExecutionExtractor
    class ExtractionError < StandardError; end

    TradeExecution = Struct.new(
      :operation_id, :trade_num, :type, :figi, :name, :date, :quantity, :price, :amount, :commission,
      keyword_init: true
    )

    def extract(operations, from:, to:)
      seen = Set.new
      operations.filter_map do |op|
        next unless trade_operation?(op)

        raw_trades = operation_trades(op)
        if raw_trades.empty?
          # PROGRESS without fills is normal. EXECUTED without the execution list
          # is not: falling back to op.date/payment would recreate the silent-loss
          # bug this extractor is meant to prevent.
          if executed?(op) && operation_quantity_done(op).positive?
            raise ExtractionError, "executed trade operation #{operation_id(op).inspect} has no trades_info executions"
          end

          next
        end

        total_trade_amount = raw_trades.sum { |trade| raw_trade_amount(trade) }
        raw_trades.filter_map do |trade|
          execution = build_trade_execution(op, trade, total_trade_amount: total_trade_amount)
          execution_time = Utils.timestamp_to_utc(execution.date)
          next unless execution_time && execution_time >= from && execution_time < to

          key = trade_execution_key(execution)
          next if seen.include?(key)

          seen << key
          execution
        end
      end.flatten
    end

    def fees(operations, from:, to:)
      selected = operations.select do |op|
        next false unless executed?(op) && op.type.to_s == 'OPERATION_TYPE_BROKER_FEE'

        time = Utils.timestamp_to_utc(op.date) if op.respond_to?(:date)
        time && time >= from && time < to
      end
      selected.uniq { |op| fee_operation_key(op) }
    end

    private

    def trade_operation?(op)
      %w[OPERATION_TYPE_BUY OPERATION_TYPE_SELL].include?(op.type.to_s)
    end

    def executed?(op)
      op.respond_to?(:state) && op.state.to_s == 'OPERATION_STATE_EXECUTED'
    end

    def operation_trades(op)
      return [] unless op.respond_to?(:trades_info)

      info = op.trades_info
      return [] unless info.respond_to?(:trades)

      Array(info.trades)
    rescue StandardError
      []
    end

    def raw_trade_amount(trade)
      quantity = trade.respond_to?(:quantity) ? trade.quantity.to_i : 0
      price = trade.respond_to?(:price) ? Utils.q_to_decimal(trade.price) : nil
      quantity.positive? && price&.positive? ? price * quantity : 0.0
    end

    def build_trade_execution(op, trade, total_trade_amount:)
      date = trade.respond_to?(:date) ? trade.date : nil
      quantity = trade.respond_to?(:quantity) ? trade.quantity.to_i : 0
      price = trade.respond_to?(:price) ? Utils.q_to_decimal(trade.price) : nil
      unless Utils.timestamp_to_utc(date) && quantity.positive? && price&.positive?
        raise ExtractionError, "malformed trade execution for operation #{operation_id(op).inspect}"
      end

      amount = (price * quantity).abs
      operation_commission = op.respond_to?(:commission) ? Utils.q_to_decimal(op.commission)&.abs : nil
      commission_available = operation_commission && total_trade_amount.positive?
      allocated_commission = operation_commission * amount / total_trade_amount if commission_available

      TradeExecution.new(
        operation_id: operation_id(op),
        trade_num: trade.respond_to?(:num) ? trade.num.to_s : '',
        type: op.type,
        figi: op.respond_to?(:figi) ? op.figi : nil,
        name: op.respond_to?(:name) ? op.name : nil,
        date: date,
        quantity: quantity,
        price: price,
        amount: amount,
        commission: allocated_commission
      )
    end

    def trade_execution_key(execution)
      op_id = execution.operation_id.to_s
      trade_num = execution.trade_num.to_s
      return [op_id, trade_num] unless op_id.empty? || trade_num.empty?

      [op_id, trade_num, Utils.timestamp_to_utc(execution.date)&.iso8601,
       execution.figi.to_s, execution.quantity, execution.price]
    end

    def operation_id(op)
      op.respond_to?(:id) ? op.id.to_s : ''
    end

    def operation_quantity_done(op)
      op.respond_to?(:quantity_done) ? op.quantity_done.to_i : 0
    end

    def fee_operation_key(op)
      id = operation_id(op)
      return id unless id.empty?

      [op.type.to_s, op.respond_to?(:figi) ? op.figi.to_s : '',
       op.respond_to?(:date) ? Utils.timestamp_to_utc(op.date)&.iso8601 : nil, operation_payment_abs(op)]
    end

    def operation_payment_abs(op)
      (Utils.q_to_decimal(op.payment) || 0.0).abs
    end
  end
end
