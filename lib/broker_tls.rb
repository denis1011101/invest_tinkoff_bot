# frozen_string_literal: true

# Дополнительный корень для брокера — только брокерскому клиенту.
#
# С 2026-08-03 invest-public-api.tinkoff.ru отдаёт цепочку от "Russian Trusted
# Root CA", которого нет ни в системном сторе, ни в roots.pem гема grpc
# (см. scripts/setup_ru_ca.sh). gRPC получает бандл через
# GRPC_DEFAULT_SSL_ROOTS_FILE_PATH, но REST-половина клиента — это HTTParty
# поверх обычного OpenSSL, и эту переменную она игнорирует. Поэтому
# TradingSchedules продолжал падать, а гейт торговой сессии fail-closed: с
# 2026-08-04 11:45Z по 2026-08-05 бот заблокировал 400 сигналов BUY и не
# выставил ни одной заявки.
#
# Очевидная починка — SSL_CERT_FILE или установка корня в системный стор —
# сделала бы государственный CA доверенным для ВСЕХ TLS-пиров процесса:
# Telegram, MOEX ISS, investing.com. Вместо этого бандл вешается на
# HTTParty-класс брокерского клиента; остальные вызовы идут голым Net::HTTP и
# продолжают проверяться по системному стору.
#
# ssl_ca_file ставится именно на V2::Client, а не на ClientBase: HTTParty
# копирует default_options в подкласс в момент его объявления, поэтому
# значение, записанное в родителя позже, до уже определённого потомка не
# доедет.
module TradingLogic
  module BrokerTls
    # GRPC_DEFAULT_SSL_ROOTS_FILE_PATH принимается запасным ключом, чтобы хосту,
    # где бандл уже подключён к gRPC, не нужна была вторая переменная: обе
    # указывают на один и тот же артефакт scripts/setup_ru_ca.sh.
    ENV_KEYS = %w[BROKER_CA_BUNDLE GRPC_DEFAULT_SSL_ROOTS_FILE_PATH].freeze

    module_function

    def bundle_path(env = ENV)
      ENV_KEYS.filter_map { |key| env[key]&.strip }.reject(&:empty?).first
    end

    def default_client_class
      return nil unless defined?(InvestTinkoff::V2::Client)

      InvestTinkoff::V2::Client
    end

    # Идемпотентно. Возвращает применённый путь либо nil, если ничего не меняли.
    # Нечитаемый бандл — не повод падать: гейт сессии и так fail-closed, так что
    # худший исход это отказ от покупок, а не покупка вслепую.
    def apply!(client_class = default_client_class, path: bundle_path, warn_io: $stderr)
      return nil if client_class.nil? || !client_class.respond_to?(:ssl_ca_file)
      return nil if path.nil?

      unless File.readable?(path)
        warn_io&.puts("broker_tls: bundle #{path} unreadable, broker TLS left on the system store")
        return nil
      end

      client_class.ssl_ca_file(path)
      path
    end
  end
end

TradingLogic::BrokerTls.apply!
