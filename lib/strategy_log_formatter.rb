# frozen_string_literal: true

require 'time'

module TradingLogic
  class StrategyLogFormatter
    def call(severity, datetime, _progname, message)
      "#{datetime.utc.iso8601} #{severity}: #{message}\n"
    end
  end
end
