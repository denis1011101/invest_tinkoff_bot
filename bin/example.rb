# For test
require 'bundler/setup'
require 'dotenv/load'
require 'invest_tinkoff'

token = ENV['TINKOFF_TOKEN'] || abort('Set TINKOFF_TOKEN')
client = InvestTinkoff::V2::Client.new(token: token, sandbox: false)

def q_to_decimal(q)
  return nil unless q

  q.units.to_i + q.nano.to_i / 1_000_000_000.0
end

begin
  resp = client.grpc_users.accounts

  resp.accounts.each do |acc|
    puts "ID: #{acc.id}, Type: #{acc.type}, Name: #{acc.name}"
  end

  # Доп. примеры: портфель по первому счёту (если есть)
  if (first = resp.accounts.first)
    begin
      port = client.grpc_operations.portfolio(account_id: first.id)
      puts "Portfolio for #{first.id}:"

      positions = if port.respond_to?(:positions)
                    port.positions
                  else
                    begin
                      port.to_h['positions']
                    rescue StandardError
                      nil
                    end
                  end

      if positions&.any?
        positions.each do |p|
          qty = q_to_decimal(p.quantity)
          avg = q_to_decimal(p.average_position_price)
          cur = q_to_decimal(p.current_price)
          yld = q_to_decimal(p.expected_yield)
          puts "#{p.ticker} (#{p.figi}) — qty=#{qty}, avg=#{avg}, cur=#{cur}, yield=#{yld}"
        end
      else
        puts "  no positions, full response: #{port.inspect}"
      end
    rescue InvestTinkoff::GRPC::Error => e
      puts "portfolio gRPC error: #{e.class} #{e.message}"
    end
  end
rescue InvestTinkoff::GRPC::Error => e
  puts "gRPC error: #{e.class} #{e.message}"
end
