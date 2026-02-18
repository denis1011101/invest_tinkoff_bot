# Invest Tinkoff Bot

A small automated trading helper for MOEX using Tinkoff gRPC API. It implements simple momentum and intraday dip strategies and helpers for caching instruments and Telegram-based confirmations.

## Strategies (brief)

### Entry signals
- **Intraday dip buy (UP trend)** — when the market index trend is up and a ticker's current price <= today's high * (1 - dip_pct), the bot may place a BUY. See [`TradingLogic::Runner`](lib/trading_logic.rb).
- **Momentum buy with dip filter (SIDE/DOWN trend)** — from intersection of market universe and IMOEX index constituents, buy one instrument showing 3 consecutive daily closes up **and** an intraday dip on the current day. This avoids buying at the peak of a momentum run. See [`TradingLogic::StrategyHelpers`](lib/strategy_helpers.rb).

### Exit signals
- **Trend-dependent profit exit** — sell threshold depends on the current market trend:
  - UP: +10% (`SELL_THRESHOLD_UP`, default `1.10`)
  - SIDE: +4% (`SELL_THRESHOLD_SIDE`, default `1.04`)
  - DOWN: +2% (`SELL_THRESHOLD_DOWN`, default `1.02`)
- **Force exit** — sell the entire position when profit reaches +10% regardless of trend (runs before main strategy logic).

### Risk management
- **Position size limit** — the bot will not buy a ticker if the existing position already exceeds a fraction of the total share portfolio value. Controlled by `MAX_POSITION_SHARE` (default `0.33` = 1/3 of portfolio).
- **Pending order cooldown** — avoids duplicate BUY orders for a ticker that already has an unfilled order. Cooldown controlled by `BUY_PENDING_COOLDOWN_MIN`.

### Filters
- **Non-share position filter** — the sell flow skips non-share positions (bonds, currencies, ETFs) using `instrument_type`.
- **FIGI cache** — `market_instruments_cache.json` is used for fast figi-to-ticker resolution, reducing gRPC API calls.
- **Pending order cleanup** — on startup, pending orders are reconciled with active broker orders; filled/cancelled orders are removed from state.
- **Volume-aware filters and ranking** — optional relative volume filter for entries (`MIN_RELATIVE_VOLUME`) and cross-sectional ranking (`VOLUME_COMPARE_MODE=relative|turnover`).

## How it works (high level)
- Market data and instruments are fetched via Invest Tinkoff gRPC client.
- Instrument list and prices are cached by [`TradingLogic::MarketCache`](lib/market_cache.rb) to speed scans.
- Strategy logic and trading actions are implemented in [`bin/current_strategy.rb`](bin/current_strategy.rb) and [`lib/trading_logic.rb`](lib/trading_logic.rb).
- Orders require confirmation which can be automated or sent to Telegram via [`TradingLogic::TelegramConfirm`](lib/telegram_confirm.rb).
- State (daily last_buy/last_sell/pending_orders) is persisted to `tmp/strategy_state.json`.

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

# restore strategy state from broker (today UTC)
bundle exec rake state:restore

# restore strategy state for a specific day
DAY=2026-02-14 bundle exec rake state:restore
```

## Important files
- `lib/trading_logic.rb` — main Runner and strategy methods (should_buy?, should_sell?, trend, etc.)
- `lib/strategy_helpers.rb` — helpers, momentum routine, position limit check, and state helpers
- `lib/market_cache.rb` — instruments + price caching
- `lib/telegram_confirm.rb` — Telegram confirm/send helpers
- `bin/current_strategy.rb` — main strategy runner
- `bin/example.rb` — basic gRPC examples and helpers

## Environment variables
- `TINKOFF_TOKEN` — required API token for Tinkoff Invest.
- `TELEGRAM_BOT_TOKEN` — Telegram bot token for confirmations/notifications.
- `TELEGRAM_CHAT_ID` — target Telegram chat id for confirmations.
- `AUTO_CONFIRM` — if `1`/`true`, skips Telegram/manual confirmation and sends orders immediately.
- `TICKERS` — comma-separated ticker list for main universe (example: `SBER,ROSN,VTBR`).
- `MAX_LOT_RUB` — strategy/runtime per-order price limit (`price_per_lot * lots_per_order`) used in `Runner` and momentum buy helper.
- `MAX_LOT_COUNT` — max instrument lot size allowed when building universe (`lot <= MAX_LOT_COUNT`).
- `LOTS_PER_ORDER` — multiplier for order size (`quantity = lot * LOTS_PER_ORDER`).
- `DIP_PCT` — intraday dip threshold for BUY (`cur <= today_high * (1 - DIP_PCT)`). Used in UP trend and as momentum dip filter in SIDE/DOWN.
- `SELL_THRESHOLD_UP` — profit multiplier to trigger SELL in UP trend (default `1.10` = +10%).
- `SELL_THRESHOLD_SIDE` — profit multiplier to trigger SELL in SIDE trend (default `1.04` = +4%).
- `SELL_THRESHOLD_DOWN` — profit multiplier to trigger SELL in DOWN trend (default `1.02` = +2%).
- `MAX_POSITION_SHARE` — max fraction of the share portfolio that one ticker can occupy before BUY is blocked (default `0.33`).
- `MIN_RELATIVE_VOLUME` — minimum `today_volume / avg_volume_N_days` ratio for BUY (disabled if unset).
- `VOLUME_LOOKBACK_DAYS` — lookback `N` for average daily volume (default `20`).
- `VOLUME_COMPARE_MODE` — volume ranking mode for universe: `none`, `relative`, `turnover`.
- `SCAN_MAX_LOT_RUB` — cache-time filter in `MarketCache`; excludes instruments with `price_per_lot` above this threshold.
- `INSTRUMENT_CACHE_DAYS` — market instruments cache TTL in days.
- `MARKET_CACHE_SLEEP` — optional sleep between `last_prices` batches during cache refresh (seconds).
- `BUY_PENDING_COOLDOWN_MIN` — cooldown (minutes) to avoid repeated BUY attempts for tickers with pending statuses (`sent_not_filled`, `partially_filled`).
- `RESTORE_STATE_FROM_BROKER` — if not `0`, auto-restores empty `tmp/strategy_state.json` from current-day broker operations and active buy orders.
- `FORCE` — rake task flag for forced market cache refresh (`FORCE=true bundle exec rake market_cache:refresh`).
- `INDEX` — MOEX index code for cache refresh task (`INDEX=IMOEX bundle exec rake moex:refresh`).

Note: `SCAN_MAX_LOT_RUB` and `MAX_LOT_RUB` are related but different. `SCAN_MAX_LOT_RUB` works at cache stage, `MAX_LOT_RUB` works at strategy stage. Keep `SCAN_MAX_LOT_RUB >= MAX_LOT_RUB` to avoid dropping valid candidates before strategy logic.
