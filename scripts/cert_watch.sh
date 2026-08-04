#!/usr/bin/env bash
# Watches the TLS chain of the T-Invest gRPC endpoint and alerts on any change.
#
# The bot trusts Russian Trusted Root CA for this one channel (see
# scripts/setup_ru_ca.sh), and a state CA can in principle issue a valid
# certificate for any host. Ruby's grpc bindings expose no verification callback
# — GRPC::Core::ChannelCredentials only has :compose — so real pinning is not
# reachable in-process. This is the fallback: it notices a swap after the fact
# and tells a human. It never blocks a connection.
#
# Baseline is not auto-updated on change: confirm the new chain is legitimate,
# then delete the state file (or write the new digest) to re-arm. Otherwise the
# watchdog would quietly accept whatever it was shown.
#
# Cron: 17 * * * * /root/apps/invest_tinkoff_bot/scripts/cert_watch.sh >> /var/log/invest_bot_cert_watch.log 2>&1
set -uo pipefail

HOST="${CERT_WATCH_HOST:-invest-public-api.tinkoff.ru}"
PORT="${CERT_WATCH_PORT:-443}"
STATE="${CERT_WATCH_STATE:-/etc/ssl/invest_bot/expected_chain.sha256}"
ENV_FILE="${CERT_WATCH_ENV_FILE:-/etc/invest_tinkoff_bot.env}"

log() { echo "$(date -Is) $*"; }

chain=$(echo | timeout 20 openssl s_client -connect "$HOST:$PORT" -servername "$HOST" -showcerts 2>/dev/null)
if [ -z "$chain" ]; then
  # A network blip must not look like an attack, and must not overwrite state.
  log "WARN: could not fetch chain from $HOST, skipping"
  exit 0
fi

current=$(printf '%s' "$chain" | awk '/BEGIN CERT/,/END CERT/' | sha256sum | cut -d' ' -f1)
if [ -z "$current" ]; then
  log "WARN: empty digest, skipping"
  exit 0
fi

if [ ! -f "$STATE" ]; then
  mkdir -p "$(dirname "$STATE")"
  printf '%s\n' "$current" > "$STATE"
  log "INFO: baseline recorded $current"
  exit 0
fi

expected=$(cat "$STATE")
if [ "$current" = "$expected" ]; then
  log "OK: chain unchanged"
  exit 0
fi

subject=$(printf '%s' "$chain" | openssl x509 -noout -subject 2>/dev/null)
issuer=$(printf '%s' "$chain" | openssl x509 -noout -issuer 2>/dev/null)
log "ALERT: chain changed $expected -> $current"
log "ALERT: $subject"
log "ALERT: $issuer"

token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
chat=$(grep -m1 '^TELEGRAM_CHAT_ID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
if [ -n "$token" ] && [ -n "$chat" ]; then
  read -r -d '' text <<EOF || true
TLS-цепочка $HOST изменилась.

было:  $expected
стало: $current
$subject
$issuer

Проверь легитимность смены до следующей торговой сессии. Базовая линия НЕ обновлена автоматически.
EOF
  if curl -sS --max-time 20 -o /dev/null \
       --data-urlencode "chat_id=$chat" \
       --data-urlencode "text=$text" \
       "https://api.telegram.org/bot$token/sendMessage"; then
    log "INFO: alert sent"
  else
    log "WARN: alert delivery failed"
  fi
else
  log "WARN: no telegram credentials in $ENV_FILE, alert not sent"
fi

exit 0
