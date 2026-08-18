# Invest Tinkoff Bot

A small automated trading helper for MOEX using Tinkoff gRPC API. It implements simple momentum and intraday dip strategies and helpers for caching instruments and Telegram-based confirmations.

## Strategies (brief)

### Entry signals
- **Intraday dip buy (UP trend)** — when the market index trend is up and a ticker's current price <= today's high * (1 - dip_pct), the bot may place a BUY. The UP universe is a separate, wider whitelist (`UP_TICKERS`, falls back to `TICKERS`): the narrow list starved the bot in exactly the trend where it should be investing. If support/resistance levels are enabled, UP-trend BUY additionally requires the price to be **above its short moving average** (`UP_ENTRY_MA_DAYS`) and **not near resistance**; if levels cannot be computed, the strategy falls back to the original dip logic. Set `UP_REQUIRE_SUPPORT=1` to restore the previous "near support" gate. See [`TradingLogic::Runner`](lib/trading_logic.rb).
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
- **Daily buy budget** — total rubles filled plus amounts still reserved by active BUY orders, capped by `MAX_DAILY_BUY_RUB` (disabled when unset/`0`). Executed amounts live in `tmp/strategy_state.json` under `daily_buys`; each pending order stores its own `filled_value` and `reserved_value`. Both components are enforced on both buy paths.
- **Equity exposure guard** — caps the share of the account held in shares (`MAX_SHARES_SHARE`, disabled when unset/`0`). It complements `MAX_POSITION_SHARE`, which limits only one ticker, but it is not a cash-reserve guarantee: the denominator is `total_amount_portfolio` and can include bonds and other assets. The guard is **fail-closed** if the portfolio cannot be read. Callers reusing one portfolio snapshot must include BUYs already committed during that run; the UP branch does this via `run_committed`.
- **Cash preflight** — every BUY must be covered by available RUB from `GetPositions.money`, less `GetPositions.blocked`, plus a configurable commission cushion (`BUY_CASH_BUFFER_RATE`, default `0.01`). Foreign currencies are not counted. The UP path also subtracts BUYs committed during the current run. This blocks requests the broker would certainly reject; it does not enforce a target cash allocation.
- **Preflight availability** — if either `GetPortfolio` or `GetPositions` is unavailable, all BUYs are blocked for that run (fail-closed) and one `BUY HALTED` error is logged. Protective SELL logic remains active.
- **Pending order lifecycle** — an active BUY blocks duplicate orders for its ticker. If `BUY_ORDER_TTL_MIN` is positive, an older active order is sent for cancellation, retried with exponential backoff (`BUY_CANCEL_RETRY_MIN`, doubling up to 60 minutes). The reservation is released **only** on an explicit terminal status from `GetOrderState` — `CANCELLED`, `REJECTED` or a full `FILL`. Neither `PARTIALLYFILL` nor absence from a single `GetOrders` page counts as terminal, since the order may still be live. After `BUY_CANCEL_MAX_ATTEMPTS` unsuccessful cancel attempts or unresolved terminal-status checks, one `BUY CANCEL STUCK`/`BUY PENDING STUCK` error is logged and the reservation is kept for manual review. This alert also works with `BUY_ORDER_TTL_MIN=0`. A partial fill moves only the executed amount into `daily_buys` and releases only the confirmed cancelled remainder.
- **Fill accounting** — the executed share of an order is derived **only** from `lots_executed / lots_requested` applied to the planned value. `total_order_amount` is the total cost of the *order* including commissions (positive even when nothing is executed) and must never be read as an executed amount; `executed_order_price` is also unusable because it means the average price of a single instrument in `PostOrderResponse` but the price times lots in `OrderState`. `filled + reserved == planned` holds by construction.
- **BUY funnel diagnostics** — every strategy run gets a UUID `scan_id`. Each completed ticker evaluation emits one terminal `buy_funnel {json}` DEBUG record showing the path (`up` or `intersection`), the gate where evaluation stopped, and its outcome. Early scan exits without a ticker emit `buy_funnel_scan {json}` (`stale_cache` or `empty_intersection`). Tickers that reach the broker use `stage=order` with the broker result category; eligible intersection candidates skipped after an earlier committed order use `stage=selection`. `momentum_shadow` carries the same `scan_id`, while later cancellation/terminal events use `buy_order_lifecycle {json}` with the same ID and broker order IDs. The full path can therefore be joined without counting repeated human-readable log lines.
- **Shadow mode** — `SHADOW_BUYS=1` evaluates and logs UP-trend signals (`SHADOW BUY ...` with the full gate breakdown) without sending orders or requiring available RUB. Strategy, daily-budget, position-size and equity-exposure gates still apply, so it answers which risk-eligible signals the bot would take if cash were available.

### Filters
- **Non-share position filter** — the sell flow skips non-share positions (bonds, currencies, ETFs) using `instrument_type`.
- **FIGI cache** — `market_instruments_cache.json` is used for fast figi-to-ticker resolution, reducing gRPC API calls.
- **Pending order cleanup** — on startup, pending orders are reconciled with active broker orders; filled/cancelled orders are removed from state.
- **Volume-aware filters and ranking** — optional relative volume filter for entries (`MIN_RELATIVE_VOLUME`) and cross-sectional ranking (`VOLUME_COMPARE_MODE=relative|turnover`). The current day's candle is normalized by the elapsed share of the MOEX session. Because the time-linear approximation overstates early rvol on front-loaded volume, the BUY stays blocked until 15% of the expected daily session by default (`MIN_RVOL_SESSION_FRACTION`, configurable). This is only a reliability delay, not a complete correction: on the 28.07 sample the filter remained non-selective until roughly 41% of the session. A typical intraday volume curve requires several days of observations. Closed days are used as-is.
- **Support/resistance levels** — optional pivot-based levels are built from closed daily candles, cached once per `figi` for the whole run, and used as a BUY filter in UP trend (resistance side) plus a soft priority signal in SIDE/DOWN momentum buys.

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

# strategy liveness watchdog with Telegram alerts/recovery
bundle exec rake strategy:heartbeat

# restore strategy state from broker (today UTC)
bundle exec rake state:restore

# restore strategy state for a specific day
DAY=2026-02-14 bundle exec rake state:restore
```

## Important files
- `lib/moex_cache_artifact.rb` — MOEX cache artifact validation and atomic install helpers
- `lib/moex_cache_syncer.rb` — local push-based MOEX cache sync via ssh/scp
- `lib/cache_health_monitor.rb` — cache freshness watchdog and Telegram alert suppression/recovery state
- `lib/strategy_heartbeat_monitor.rb` — strategy liveness watchdog: log silence, hung run detection, alert suppression/recovery state
- `lib/trading_logic.rb` — main Runner and strategy methods (should_buy?, should_sell?, trend, etc.)
- `lib/strategy_helpers.rb` — helpers, momentum routine, position limit check, and state helpers
- `lib/market_cache.rb` — instruments + price caching
- `lib/telegram_confirm.rb` — Telegram confirm/send helpers
- `lib/broker_tls.rb` — attaches the extra broker CA bundle to the T-Invest REST client alone (see Broker TLS below)
- `bin/current_strategy.rb` — main strategy runner
- `bin/example.rb` — basic gRPC examples and helpers
- `bin/sync_moex_cache` — command-line wrapper around the MOEX push sync flow
- `systemd/` — sample systemd services, timers, and environment file templates for local/server automation

## Broker TLS

Since 2026-08-03 `invest-public-api.tinkoff.ru` serves a chain rooted in **Russian Trusted Root CA**, which is absent from the system trust store and from the `roots.pem` shipped in the `grpc` gem. `scripts/setup_ru_ca.sh` builds `/etc/ssl/invest_bot/roots_with_ru.pem` (upstream roots + that one root, pinned by SHA-256) and `scripts/cert_watch.sh` alerts on any change of the served chain.

The extra root is never installed system-wide: a national CA in the system store would be trusted for **every** TLS peer this host talks to. It reaches exactly two places, both scoped to the broker:

- **gRPC** — `GRPC_DEFAULT_SSL_ROOTS_FILE_PATH`, read by grpc-core only. OpenSSL ignores it.
- **REST** — `lib/broker_tls.rb` sets HTTParty's `ssl_ca_file` on `InvestTinkoff::V2::Client`. The bins load it right after `invest_tinkoff`, so requiring the file is enough.

Telegram, MOEX ISS and investing.com go through bare `Net::HTTP` and keep the system store. The scoping is verifiable: with the bundle applied, the broker host still fails TLS over plain `Net::HTTP`.

Do **not** use `SSL_CERT_FILE` or `update-ca-certificates` for this — both widen the trust to the whole process.

Without a readable bundle the REST call to `TradingSchedules` fails, and since the session gate is fail-closed, **every BUY is blocked** (this is what happened on 2026-08-04/05: 400 blocked signals, zero orders). `broker_tls` prints a warning in that case rather than raising.

## Environment variables
- `TINKOFF_TOKEN` — required API token for Tinkoff Invest.
- `BROKER_CA_BUNDLE` — CA bundle for the broker REST client (see Broker TLS). Falls back to `GRPC_DEFAULT_SSL_ROOTS_FILE_PATH`, so a host already configured for gRPC needs no second variable. Unset means the system store.
- `TELEGRAM_BOT_TOKEN` — Telegram bot token for confirmations/notifications.
- `TELEGRAM_CHAT_ID` — target Telegram chat id for confirmations.
- `AUTO_CONFIRM` — if `1`/`true`, skips Telegram/manual confirmation and sends orders immediately.
- `TICKERS` — comma-separated ticker list for main universe (example: `SBER,ROSN,VTBR`).
- `UP_TICKERS` — comma-separated whitelist used **only when the index trend is UP** (falls back to `TICKERS` when empty). SIDE/DOWN already get a wide pool from the IMOEX∩market intersection.
- `UP_REQUIRE_SUPPORT` — `1` restores the legacy UP entry gate (price must be near support). Default `0` = trend gate (above MA, not near resistance).
- `UP_ENTRY_MA_DAYS` — moving-average window (closed daily closes) for the UP entry gate (default `5`).
- `SHADOW_BUYS` — `1` logs UP-trend buy decisions without placing orders.
- `MAX_LOT_RUB` — strategy/runtime per-order price limit (`price_per_lot * lots_per_order`) used in `Runner` and momentum buy helper.
- `MAX_LOT_COUNT` — max instrument lot size allowed when building universe (`lot <= MAX_LOT_COUNT`). `0`/unset disables the check — `MAX_LOT_RUB` already bounds the order size, and a value of `1` silently drops most liquid MOEX names (GAZP, SNGSP, IRAO, RUAL, NLMK, RTKM…).
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
- `MAX_DAILY_BUY_RUB` — max total rubles spent on BUYs per calendar day (disabled when unset/`0`).
- `MAX_SHARES_SHARE` — max fraction of `total_amount_portfolio` allowed to sit in shares after a BUY (disabled when unset/`0`); the denominator can include bonds, funds, currencies and other assets.
- `BUY_CASH_BUFFER_RATE` — fractional cushion added by the mandatory cash preflight (default `0.01`, i.e. 1%).
- `MIN_RELATIVE_VOLUME` — minimum relative volume for BUY (disabled if unset). Compared against the session-normalized ratio, so `1.0` means "on pace for an average day", not "an average full day's volume already traded".
- `MIN_RVOL_SESSION_FRACTION` — positive fraction of the expected daily session required before normalized rvol may pass a BUY (default `0.15`, valid range `(0, 1]`).
- `VOLUME_LOOKBACK_DAYS` — lookback `N` for average daily volume (default `20`).
- `VOLUME_COMPARE_MODE` — volume ranking mode for universe: `none`, `relative`, `turnover`.
- `SCAN_MAX_LOT_RUB` — cache-time filter in `MarketCache`; excludes instruments with `price_per_lot` above this threshold.
- `INSTRUMENT_CACHE_HOURS` — market instruments cache TTL in hours.
- `MARKET_CACHE_SLEEP` — optional sleep between `last_prices` batches during cache refresh (seconds).
- `BUY_ORDER_TTL_MIN` — age in minutes after which an active BUY is requested for cancellation; `0`/unset disables automatic cancellation. The reservation is released only after terminal reconciliation.
- `BUY_CANCEL_RETRY_MIN` — base backoff in minutes between cancel retries for the same order (default `5`, doubles per attempt, capped at 60).
- `BUY_CANCEL_MAX_ATTEMPTS` — unsuccessful cancel attempts or unresolved terminal-status checks before one stuck-order error alert (default `5`). The reservation is never released automatically.
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
- `STRATEGY_HEARTBEAT_LOG` — log file whose mtime is the strategy heartbeat (default `logs/current_strategy.log`).
- `STRATEGY_HEARTBEAT_WARN_MINUTES` — silence threshold for a warning (default `20`; cron writes the log every 5 minutes around the clock).
- `STRATEGY_HEARTBEAT_CRITICAL_MINUTES` — silence threshold for critical (default `60`). A missing log file is critical too, never `ok`.
- `STRATEGY_HEARTBEAT_REPEAT_HOURS` — minimum delay before repeating the same heartbeat alert level (default `6`).
- `STRATEGY_HUNG_RUN_MINUTES` — a strategy run alive longer than this is reported as hung, with its pid (default `15`; a healthy scan takes under a minute).
- `INVEST_TINKOFF_GRPC_TIMEOUT` — per-RPC deadline for the broker client, in seconds (gem default `30`; `0` disables it). Without a deadline a broken channel can hang a run forever — see Strategy liveness watchdog.

Note: `SCAN_MAX_LOT_RUB` and `MAX_LOT_RUB` are related but different. `SCAN_MAX_LOT_RUB` works at cache stage, `MAX_LOT_RUB` works at strategy stage. Keep `SCAN_MAX_LOT_RUB >= MAX_LOT_RUB` to avoid dropping valid candidates before strategy logic.

## Push-based MOEX sync
- Run `bundle exec rake market_cache:refresh FORCE=true` on the server; this cache only needs Tinkoff API.
- Run `bundle exec rake moex_cache:sync INDEX=IMOEX` on the local machine; this generates a fresh MOEX artifact, validates it locally, uploads it to `tmp/incoming`, and installs it atomically on the server.
- Avoid `bundle exec rake` / `generate:all` on a server that cannot reach MOEX ISS.
- Schedule `bundle exec rake cache:health` hourly on the server and `bundle exec rake moex_cache:sync INDEX=IMOEX` daily on the local machine, including weekends.

## Strategy liveness watchdog
The strategy runs from cron every 5 minutes under `flock -n` and writes at least a `scan_id` line on every run, around the clock. Any silence longer than a few runs is a fault, so `rake strategy:heartbeat` alerts on the mtime of `logs/current_strategy.log` and clears the alert on recovery, with the same suppression logic as `cache:health`.

Why it exists: on 2026-08-18 a run hung on a broker gRPC call (an ESTABLISHED socket that would never receive an answer), held `/tmp/current_strategy.lock` for 2h45m and cron silently skipped every later run. Nothing was written to any log — no error, no line — so from the outside it looked exactly like "the bot just isn't buying anything".

Two independent layers cover that failure:
- the gem now sends every RPC with a deadline (`INVEST_TINKOFF_GRPC_TIMEOUT`, default 30s), so a dead channel raises `InvestTinkoff::GRPC::DeadlineExceeded` instead of hanging;
- this watchdog catches the symptom — silence — whatever its cause, and additionally names the pid of a run that has been alive longer than `STRATEGY_HUNG_RUN_MINUTES`. Kill that ruby pid, not the `flock`/`bash` wrappers: the ruby process inherits the lock fd, so killing the wrappers alone leaves the lock held.

## systemd templates
- All units read secrets from `/etc/invest_tinkoff_bot.env` (never from a file inside the repository), run with `UMask=0077`, and start ruby through `bin/systemd_exec`, which builds the RVM environment for the ruby pinned in `.ruby-version` (systemd's default `PATH` has no RVM/Bundler, and neither does non-interactive SSH).
- Host roles and identities:
  - `cache-health.timer` + `market-cache-refresh.timer` — server; run as root from `/root/apps/invest_tinkoff_bot`, matching the existing root cron deployment (non-root migration deferred). Installed and enabled on 2026-07-23.
  - `strategy-heartbeat.timer` — server; same root deployment, runs every 10 minutes. Watches the strategy cron loop (see Strategy liveness watchdog).
  - `moex-cache-sync.timer` — template for a local machine with systemd that can reach MOEX ISS (runs as `User=denis`). The current local machine is WSL without systemd, so the MOEX sync is run **manually** instead: `bundle exec rake moex_cache:sync INDEX=IMOEX` (MOEX_SYNC_* values live in the local `.env`); the cache-health watchdog reminds about it in Telegram when the cache ages out.
- Services intentionally have no `[Install]` section: they are pulled in by their timers. Enable **only** the `.timer` units, never the oneshot `.service` units.
- The sample units use `flock` to block parallel runs and `Persistent=true` on timers to catch up after missed starts.
- The timers manage caches and watch the strategy loop; the jobs themselves — strategy (`bin/current_strategy.rb`), wishlist scan, price monitor — stay in the server cron untouched.

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
sudo cp systemd/{cache-health,market-cache-refresh,strategy-heartbeat}.{service,timer} /etc/systemd/system/  # server
sudo systemctl daemon-reload

# 4. Enable and start ONLY the timers.
sudo systemctl enable --now moex-cache-sync.timer                          # local machine
sudo systemctl enable --now cache-health.timer market-cache-refresh.timer strategy-heartbeat.timer  # server

# 5. Verify.
systemctl list-timers --all | grep -E 'moex|cache|heartbeat'
systemctl status cache-health.timer market-cache-refresh.timer strategy-heartbeat.timer
journalctl -u cache-health.service -u market-cache-refresh.service -u strategy-heartbeat.service --since today
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
- `DAILY_REPORT_OPERATION_LOOKBACK_DAYS` — overlap used to find orders submitted before their fills (default `7`).
- Telegram uses `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`, overridable via `DAILY_REPORT_TELEGRAM_BOT_TOKEN`/`DAILY_REPORT_TELEGRAM_CHAT_ID`.
