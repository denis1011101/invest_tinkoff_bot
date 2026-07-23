# Invest Tinkoff Bot

A small automated trading helper for MOEX using Tinkoff gRPC API. It implements simple momentum and intraday dip strategies and helpers for caching instruments and Telegram-based confirmations.

## Strategies (brief)

### Entry signals
- **Intraday dip buy (UP trend)** — when the market index trend is up and a ticker's current price <= today's high * (1 - dip_pct), the bot may place a BUY. If support/resistance levels are enabled, UP-trend BUY also requires the live price to be near a support level; if levels cannot be computed, the strategy falls back to the original dip logic. See [`TradingLogic::Runner`](lib/trading_logic.rb).
- **Momentum buy with dip filter (SIDE/DOWN trend)** — from intersection of market universe and IMOEX index constituents, buy one instrument showing 3 consecutive daily closes up **and** an intraday dip on the current day. If support/resistance levels are enabled, candidates closer to support are prioritized, but this does not block buying. See [`TradingLogic::StrategyHelpers`](lib/strategy_helpers.rb).

Exits are intentionally asymmetric by trend. In an **UP** trend the bot holds positions (letting winners run) and the only sell is the full-position force exit at +10%; the per-lot profit exit and resistance exit are applied only once the trend is no longer UP. In **SIDE/DOWN** the bot trims one lot at a time on the trend threshold, and still exits the whole position at +10%.

- **Force exit** — sell the entire position when profit reaches +10% (`>= 1.10`), in any trend, including UP. Runs before the per-trend logic below.
- **Trend-dependent profit exit (SIDE/DOWN only)** — sell **one lot** per ticker per day when the position reaches the trend threshold:
  - SIDE: +4% (`SELL_THRESHOLD_SIDE`, default `1.04`)
  - DOWN: +2% (`SELL_THRESHOLD_DOWN`, default `1.02`)
  - `SELL_THRESHOLD_UP` (default `1.10`) exists for completeness but is not exercised in UP, since the UP branch runs no per-trend sells and its value coincides with the +10% force exit.
- **Resistance-based exit (SIDE/DOWN only)** — if support/resistance levels are enabled, the bot may also sell one lot near the nearest resistance level when the position already has at least minimal profit (`LEVEL_SELL_MIN_PROFIT`). Like the profit exit above, this is not evaluated in an UP trend.

### Risk management
- **Position size limit** — the bot will not buy a ticker if the existing position already exceeds a fraction of the total share portfolio value. Controlled by `MAX_POSITION_SHARE` (default `0.33` = 1/3 of portfolio).
- **Pending order cooldown** — avoids duplicate BUY orders for a ticker that already has an unfilled order. Cooldown controlled by `BUY_PENDING_COOLDOWN_MIN`.

### Filters
- **Non-share position filter** — the sell flow skips non-share positions (bonds, currencies, ETFs) using `instrument_type`.
- **FIGI cache** — `market_instruments_cache.json` is used for fast figi-to-ticker resolution, reducing gRPC API calls.
- **Pending order cleanup** — on startup, pending orders are reconciled with active broker orders; filled/cancelled orders are removed from state.
- **Volume-aware filters and ranking** — optional relative volume filter for entries (`MIN_RELATIVE_VOLUME`) and cross-sectional ranking (`VOLUME_COMPARE_MODE=relative|turnover`).
- **Support/resistance levels** — optional pivot-based levels are built from closed daily candles, cached once per `figi` for the whole run, and used as a hard BUY filter in UP trend plus a soft priority signal in SIDE/DOWN momentum buys.

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

# validate and push MOEX cache from local machine to server
INDEX=IMOEX bundle exec rake moex_cache:sync

# dry-run local generation/validation without ssh upload
INDEX=IMOEX DRY_RUN=1 bundle exec rake moex_cache:sync

# install an uploaded MOEX artifact on the server
INDEX=IMOEX SHA256=<sha256> FILE=tmp/incoming/moex_index_cache.json bundle exec rake moex_cache:install

# cache freshness watchdog with Telegram alerts/recovery
bundle exec rake cache:health

# restore strategy state from broker (today UTC)
bundle exec rake state:restore

# restore strategy state for a specific day
DAY=2026-02-14 bundle exec rake state:restore
```

## Important files
- `lib/moex_cache_artifact.rb` — MOEX cache artifact validation and atomic install helpers
- `lib/moex_cache_syncer.rb` — local push-based MOEX cache sync via ssh/scp
- `lib/cache_health_monitor.rb` — cache freshness watchdog and Telegram alert suppression/recovery state
- `lib/trading_logic.rb` — main Runner and strategy methods (should_buy?, should_sell?, trend, etc.)
- `lib/strategy_helpers.rb` — helpers, momentum routine, position limit check, and state helpers
- `lib/market_cache.rb` — instruments + price caching
- `lib/telegram_confirm.rb` — Telegram confirm/send helpers
- `bin/current_strategy.rb` — main strategy runner
- `bin/example.rb` — basic gRPC examples and helpers
- `bin/sync_moex_cache` — command-line wrapper around the MOEX push sync flow
- `systemd/` — sample systemd services, timers, and environment file templates for local/server automation

## Environment variables
- `TINKOFF_TOKEN` — required API token for Tinkoff Invest.
- `TELEGRAM_BOT_TOKEN` — Telegram bot token for confirmations/notifications.
- `TELEGRAM_CHAT_ID` — target Telegram chat id for confirmations.
- `AUTO_CONFIRM` — if `1`/`true`, skips Telegram/manual confirmation and sends orders immediately.
- `TICKERS` — comma-separated ticker list for main universe (example: `SBER,ROSN,VTBR`).
- `MAX_LOT_RUB` — strategy/runtime per-order price limit (`price_per_lot * lots_per_order`) used in `Runner` and momentum buy helper.
- `MAX_LOT_COUNT` — max instrument lot size allowed when building universe (`lot <= MAX_LOT_COUNT`).
- `LOTS_PER_ORDER` — order quantity in lots (`quantity = LOTS_PER_ORDER`, shares = `lot_size * LOTS_PER_ORDER`).
- `DIP_PCT` — intraday dip threshold for BUY (`cur <= today_high * (1 - DIP_PCT)`). Used in UP trend and as momentum dip filter in SIDE/DOWN.
- `USE_LEVELS` — enables support/resistance levels logic (`1` by default, `0` disables all level lookups and related filters).
- `LEVELS_LOOKBACK_DAYS` — number of closed daily candles to inspect when building support/resistance levels (default `120`).
- `LEVEL_PROXIMITY_PCT` — max relative distance from support/resistance to consider price "near level" (default `0.02` = 2%).
- `LEVEL_SELL_MIN_PROFIT` — minimal profit multiple required before resistance-based sell is allowed (default `1.005` = +0.5%).
- `LEVEL_PIVOT_WINDOW` — pivot window size for local extrema detection on daily candles (default `5`).
- `LEVEL_CLUSTER_PCT` — max relative distance for clustering nearby support/resistance pivots into one level (default `0.015` = 1.5%).
- `SELL_THRESHOLD_UP` — nominal profit multiplier for the UP trend (default `1.10` = +10%). Not exercised in practice: the UP branch runs no per-trend sells, and this value coincides with the +10% force exit. See Exit signals above.
- `SELL_THRESHOLD_SIDE` — profit multiplier to trigger SELL in SIDE trend (default `1.04` = +4%).
- `SELL_THRESHOLD_DOWN` — profit multiplier to trigger SELL in DOWN trend (default `1.02` = +2%).
- `MAX_POSITION_SHARE` — max fraction of the share portfolio that one ticker can occupy before BUY is blocked (default `0.33`).
- `MIN_RELATIVE_VOLUME` — minimum `today_volume / avg_volume_N_days` ratio for BUY (disabled if unset).
- `VOLUME_LOOKBACK_DAYS` — lookback `N` for average daily volume (default `20`).
- `VOLUME_COMPARE_MODE` — volume ranking mode for universe: `none`, `relative`, `turnover`.
- `SCAN_MAX_LOT_RUB` — cache-time filter in `MarketCache`; excludes instruments with `price_per_lot` above this threshold.
- `INSTRUMENT_CACHE_HOURS` — market instruments cache TTL in hours.
- `MARKET_CACHE_SLEEP` — optional sleep between `last_prices` batches during cache refresh (seconds).
- `BUY_PENDING_COOLDOWN_MIN` — cooldown (minutes) to avoid repeated BUY attempts for tickers with pending statuses (`sent_not_filled`, `partially_filled`).
- `RESTORE_STATE_FROM_BROKER` — if not `0`, auto-restores empty `tmp/strategy_state.json` from current-day broker operations and active buy orders.
- `FORCE` — rake task flag for forced market cache refresh (`FORCE=true bundle exec rake market_cache:refresh`).
- `INDEX` — MOEX index code for cache refresh task (`INDEX=IMOEX bundle exec rake moex:refresh`).
- `MOEX_SYNC_HOST` — remote host used by `moex_cache:sync`.
- `MOEX_SYNC_USER` — optional ssh user used by `moex_cache:sync`.
- `MOEX_SYNC_REMOTE_DIR` — repository path on the remote server where the artifact is uploaded and installed.
- `MOEX_SYNC_SSH_KEY` — optional path to a dedicated ssh private key for MOEX sync.
- `MOEX_CACHE_MIN_INSTRUMENTS` — minimum acceptable number of MOEX index constituents in an artifact (default `20`).
- `MOEX_CACHE_MAX_AGE_HOURS` — maximum artifact age accepted by validator/install before rejecting it (default `6`).
- `MOEX_CACHE_MIN_COUNT_RATIO` — minimum acceptable current-to-previous constituent count ratio before rejecting a sudden drop (default `0.5`).
- `CACHE_WARN_AGE_HOURS` — watchdog warning threshold for cache age (default `36`).
- `CACHE_CRITICAL_AGE_HOURS` — watchdog critical threshold for cache age (default `60`).
- `CACHE_ALERT_REPEAT_HOURS` — minimum delay before repeating the same cache alert level (default `12`).

Note: `SCAN_MAX_LOT_RUB` and `MAX_LOT_RUB` are related but different. `SCAN_MAX_LOT_RUB` works at cache stage, `MAX_LOT_RUB` works at strategy stage. Keep `SCAN_MAX_LOT_RUB >= MAX_LOT_RUB` to avoid dropping valid candidates before strategy logic.

## Push-based MOEX sync
- Run `bundle exec rake market_cache:refresh FORCE=true` on the server; this cache only needs Tinkoff API.
- Run `bundle exec rake moex_cache:sync INDEX=IMOEX` on the local machine; this generates a fresh MOEX artifact, validates it locally, uploads it to `tmp/incoming`, and installs it atomically on the server.
- Avoid `bundle exec rake` / `generate:all` on a server that cannot reach MOEX ISS.
- Schedule `bundle exec rake cache:health` hourly on the server and `bundle exec rake moex_cache:sync INDEX=IMOEX` daily on the local machine, including weekends.

## systemd templates
- All units read secrets from `/etc/invest_tinkoff_bot.env` (never from a file inside the repository), run with `UMask=0077`, and start ruby through `bin/systemd_exec`, which builds the RVM environment for the ruby pinned in `.ruby-version` (systemd's default `PATH` has no RVM/Bundler, and neither does non-interactive SSH).
- Host roles and identities:
  - `cache-health.timer` + `market-cache-refresh.timer` — server; run as root from `/root/apps/invest_tinkoff_bot`, matching the existing root cron deployment (non-root migration deferred). Installed and enabled on 2026-07-23.
  - `moex-cache-sync.timer` — template for a local machine with systemd that can reach MOEX ISS (runs as `User=denis`). The current local machine is WSL without systemd, so the MOEX sync is run **manually** instead: `bundle exec rake moex_cache:sync INDEX=IMOEX` (MOEX_SYNC_* values live in the local `.env`); the cache-health watchdog reminds about it in Telegram when the cache ages out.
- Services intentionally have no `[Install]` section: they are pulled in by their timers. Enable **only** the `.timer` units, never the oneshot `.service` units.
- The sample units use `flock` to block parallel runs and `Persistent=true` on timers to catch up after missed starts.
- The timers only manage caches; the strategy (`bin/current_strategy.rb`), wishlist scan, and price monitor stay in the server cron untouched.

Installation steps (per host):

```bash
# 1. Secrets: create the env file outside the repo, root-owned, mode 0600.
#    Use the local example on the local machine (no TINKOFF_TOKEN needed there)
#    and the server example on the server (no MOEX_SYNC_* needed there).
sudo install -m 0600 -o root -g root systemd/invest_tinkoff_bot.local.env.example /etc/invest_tinkoff_bot.env   # local machine
sudo install -m 0600 -o root -g root systemd/invest_tinkoff_bot.server.env.example /etc/invest_tinkoff_bot.env  # server
sudoedit /etc/invest_tinkoff_bot.env  # fill in the values

# 2. Make sure working dirs exist and belong to the unit's user
#    (denis on the local machine, root on the server).
mkdir -p tmp/incoming tmp/cache_backups && chmod 700 tmp tmp/incoming tmp/cache_backups

# 3. Install the units for this host and reload systemd.
sudo cp systemd/moex-cache-sync.{service,timer} /etc/systemd/system/                            # local machine
sudo cp systemd/{cache-health,market-cache-refresh}.{service,timer} /etc/systemd/system/        # server
sudo systemctl daemon-reload

# 4. Enable and start ONLY the timers.
sudo systemctl enable --now moex-cache-sync.timer                          # local machine
sudo systemctl enable --now cache-health.timer market-cache-refresh.timer  # server

# 5. Verify.
systemctl list-timers --all | grep -E 'moex|cache'
systemctl status cache-health.timer market-cache-refresh.timer
journalctl -u cache-health.service -u market-cache-refresh.service --since today
```

Before enabling `moex-cache-sync.timer` on the local machine, as user `denis` accept the server host key and confirm key-based access (`ssh -i "$MOEX_SYNC_SSH_KEY" -o BatchMode=yes "$MOEX_SYNC_USER@$MOEX_SYNC_HOST" true`), then run one manual `INDEX=IMOEX DRY_RUN=1 bundle exec rake moex_cache:sync` and only after a clean dry-run do one manual real sync. The remote install step executes `<MOEX_SYNC_REMOTE_DIR>/bin/systemd_exec` on the server, so the server checkout must be pulled to a revision that contains this wrapper first.

## Daily trade report
A once-a-day plain-text Telegram report of **actually executed** trades, independent of the trading strategy. Files: [`bin/daily_trade_report.rb`](bin/daily_trade_report.rb), [`lib/daily_trade_report.rb`](lib/daily_trade_report.rb), [`lib/daily_report_delivery.rb`](lib/daily_report_delivery.rb).

- **Source of trades** — only `GetOperationsByCursor` (full pagination; it raises rather than silently truncating if the broker reports `has_next` without a usable cursor). Trades are never derived from strategy logs or `tmp/strategy_state.json`.
- **Window** — a rolling 24h ending at the cutoff (default `21:00` `+05:00` = 21:00 YEKT), so trades in the evening session are never dropped; they roll into the next day's report.
- **Index** — IMOEX change vs the previous close, using the current (possibly still-forming) daily candle as the current value. For a *live* run this is the value near the cutoff. A historical `REPORT_DAY` re-run shows the finalized daily close, not the original cutoff snapshot. The **sent Telegram message is the source of truth** for the cutoff snapshot; the machine archive is a best-effort copy and may be absent if archiving failed after a successful send.
- **Portfolio** — whole-portfolio `daily_yield` for the broker's *current* trading day, explicitly labeled and including old positions. Omitted for a historical `REPORT_DAY` (the broker only exposes today's yield). Note the message mixes three periods on purpose: trades (rolling 24h), index (vs previous close), portfolio (current trading day).
- **Realized P/L** — shown as `н/д` when sells exist (no reliable per-trade cost basis yet); to be wired to the operation `yield` field once a real SELL is available to validate it.

### Manual run
```bash
# print to stdout, do not send, do not touch state/archive
REPORT_DAY=2026-07-23 DRY_RUN=1 bundle exec ruby bin/daily_trade_report.rb

# resend a day that was already sent
REPORT_DAY=2026-07-23 FORCE_SEND=1 bundle exec ruby bin/daily_trade_report.rb
```
- `REPORT_DAY` — optional date (defaults to today in the configured offset).
- `DRY_RUN=1` — print only; never sends, never writes state or archive.
- `FORCE_SEND=1` — emergency override: bypasses **both** guards — resends a day already marked as sent, and permits a real send for a not-yet-closed current day or a future date (which are otherwise skipped).

### Persistence
- **Dedup state** — `tmp/daily_trade_report_state.json` (`last_sent_day`); a day is marked sent only after all Telegram parts succeed.
- **Machine archive** — `logs/daily_reports/YYYY-MM.txt` (human-readable) and `YYYY-MM.jsonl` (structured, for monthly analysis), appended after a successful send. The JSONL line carries `window_from`/`window_to`, daily aggregates, the index snapshot, portfolio (when shown) and a `trades` array (time, side, ticker, qty, price, amount) so history can be analyzed per instrument programmatically. Archive failures are logged but never break delivery or roll back state.

### Schedule (cron, server on UTC)
```cron
5 16 * * * /usr/bin/flock -n /tmp/daily_trade_report.lock /bin/bash -lc 'cd /root/apps/invest_tinkoff_bot && bundle exec ruby bin/daily_trade_report.rb >> /root/apps/invest_tinkoff_bot/logs/daily_trade_report.log 2>&1'
```
`16:05 UTC = 21:05 YEKT`, five minutes after the cutoff so the last operations settle at the broker.

### Config (`DAILY_REPORT_*`)
- `DAILY_REPORT_UTC_OFFSET` — local offset for the window/labels (default `+05:00`).
- `DAILY_REPORT_TIME_LABEL` — label shown in the message (default `YEKT`).
- `DAILY_REPORT_CUTOFF` — window end time in the offset (default `21:00`).
- `DAILY_REPORT_INDEX` — index ticker for the snapshot (default `IMOEX`).
- Telegram uses `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`, overridable via `DAILY_REPORT_TELEGRAM_BOT_TOKEN`/`DAILY_REPORT_TELEGRAM_CHAT_ID`.
