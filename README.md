# Invest Tinkoff Bot

A small automated trading helper for MOEX using Tinkoff gRPC API. It implements simple momentum and intraday dip strategies and helpers for caching instruments and Telegram-based confirmations.

## Strategies (brief)
- Intraday dip buy on market uptrend
  - When the market index trend is up and a ticker's current price <= today's high * (1 - dip_pct), the bot may place a BUY. See [`TradingLogic::Runner`](lib/trading_logic.rb).
- Momentum buy (3-day momentum)
  - From intersection of market universe and index constituents, buy one instrument showing 3 consecutive daily closes up. See [`TradingLogic::StrategyHelpers`](lib/strategy_helpers.rb).
- Profit exit / force exit
  - Sell when current price >= average_buy * 1.10 (configurable checks in logic). See [`TradingLogic::Runner`](lib/trading_logic.rb).
- Volume-aware filters and ranking
  - Optional relative volume filter for entries: current day volume must be above average history (`MIN_RELATIVE_VOLUME`).
  - Optional cross-sectional ranking by volume (`VOLUME_COMPARE_MODE=relative|turnover`) to prioritize strongest names by volume burst or by turnover.

## How it works (high level)
- Market data and instruments are fetched via Invest Tinkoff gRPC client.
- Instrument list and prices are cached by [`TradingLogic::MarketCache`](lib/market_cache.rb) to speed scans.
- Strategy logic and trading actions are implemented in [`bin/current_strategy.rb`] and [`lib/trading_logic.rb`].
- Orders require confirmation which can be automated or sent to Telegram via [`TradingLogic::TelegramConfirm`](lib/telegram_confirm.rb).
- State (daily last_buy/last_sell) is persisted to tmp/strategy_state.json.

## Run / Tasks
```bash
bundle exec ruby bin/example.rb
```

## Rake tasks:
```bash
# generate both caches (default)
bundle exec rake

# refresh market instruments cache
bundle exec rake market_cache:refresh

# refresh market instruments cache with force
FORCE=true bundle exec rake market_cache:refresh

# refresh MOEX index cache (default IMOEX)
bundle exec rake moex:refresh

# refresh MOEX index cache for a specific index
INDEX=IMOEX bundle exec rake moex:refresh
```

## Important files
lib/trading_logic.rb — main Runner and strategy methods (should_buy?, should_sell?, trend, etc.)
lib/strategy_helpers.rb — helpers, momentum routine and state helpers
lib/market_cache.rb — instruments + price caching
lib/telegram_confirm.rb — Telegram confirm/send helpers
bin/current_strategy.rb — example main strategy runner
bin/example.rb — basic gRPC examples and helpers


## Volume parameters
- `MIN_RELATIVE_VOLUME` — minimum ratio `today_volume / avg_volume_N_days` for BUY signals (disabled if unset).
- `VOLUME_LOOKBACK_DAYS` — lookback length `N` for average volume (default `20`).
- `VOLUME_COMPARE_MODE` — how to compare papers by volume in universe: `none` (default), `relative`, `turnover`.
