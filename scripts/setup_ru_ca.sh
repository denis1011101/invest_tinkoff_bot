#!/usr/bin/env bash
# Builds the CA bundle the bot uses for the T-Invest gRPC endpoint.
#
# Since 2026-08-03 invest-public-api.tinkoff.ru serves a chain rooted in
# "Russian Trusted Root CA" (Mincifry). That root is in neither the system trust
# store nor the roots.pem shipped inside the grpc gem, so every RPC fails with
# CERTIFICATE_VERIFY_FAILED: self signed certificate in certificate chain.
#
# The fix deliberately does NOT touch the system store: a national CA installed
# there could sign a valid certificate for any host this machine talks to. The
# bundle below is fed to grpc-core alone via GRPC_DEFAULT_SSL_ROOTS_FILE_PATH,
# which OpenSSL (and therefore every Net::HTTP call to Telegram and MOEX ISS)
# ignores. The extra root stays confined to the broker channel.
#
# gRPC is only half of the client: TradingSchedules and the rest of the REST
# surface go through HTTParty over plain OpenSSL, which that variable does not
# reach. Do NOT paper over it with SSL_CERT_FILE — that trusts the root
# process-wide, exactly what the paragraph above avoids. lib/broker_tls.rb
# attaches this same bundle to the HTTParty class of the broker client instead.
#
# The bundle is a copy, not a link: re-run this after `bundle update grpc`,
# otherwise the bot keeps using the roots of the old gem version.
#
# Usage: sudo scripts/setup_ru_ca.sh
set -euo pipefail

DEST_DIR="${DEST_DIR:-/etc/ssl/invest_bot}"
BUNDLE="$DEST_DIR/roots_with_ru.pem"
RU_ROOT="$DEST_DIR/russian_trusted_root_ca.pem"
SOURCE_URL="${SOURCE_URL:-https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt}"

# Published by gosuslugi. Verified against the chain served by the broker on
# 2026-08-04; both paths produced byte-identical DER.
EXPECTED_SHA256="d26d2d0231b7c39f92cc738512ba54103519e4405d68b5bd703e9788ca8ecf31"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Ask bundler which grpc is actually resolved rather than globbing the gem dir:
# several versions are usually installed side by side.
grpc_roots=$(bin/systemd_exec ruby -e \
  'require "grpc"; print File.join(Gem.loaded_specs["grpc"].gem_dir, "etc", "roots.pem")')
[ -r "$grpc_roots" ] || { echo "setup_ru_ca: grpc roots.pem not readable at $grpc_roots" >&2; exit 1; }

mkdir -p "$DEST_DIR"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl -fsS --max-time 30 -o "$tmp" "$SOURCE_URL"

actual=$(openssl x509 -in "$tmp" -outform DER | sha256sum | cut -d' ' -f1)
if [ "$actual" != "$EXPECTED_SHA256" ]; then
  echo "setup_ru_ca: fingerprint mismatch, refusing to install" >&2
  echo "  expected $EXPECTED_SHA256" >&2
  echo "  got      $actual" >&2
  exit 1
fi

install -m 0644 "$tmp" "$RU_ROOT"
{
  cat "$grpc_roots"
  echo
  echo "# Russian Trusted Root CA (Mincifry) — for invest-public-api.tinkoff.ru only."
  cat "$RU_ROOT"
} > "$BUNDLE"
chmod 0644 "$BUNDLE"

echo "setup_ru_ca: upstream roots $(grep -c 'BEGIN CERTIFICATE' "$grpc_roots"), bundle $(grep -c 'BEGIN CERTIFICATE' "$BUNDLE")"
echo "setup_ru_ca: wrote $BUNDLE"

# Prove the bundle actually validates the endpoint before anyone relies on it.
if echo | openssl s_client -connect invest-public-api.tinkoff.ru:443 \
     -servername invest-public-api.tinkoff.ru -CAfile "$BUNDLE" 2>/dev/null \
     | grep -q "Verify return code: 0"; then
  echo "setup_ru_ca: chain verifies against the new bundle"
else
  echo "setup_ru_ca: WARNING bundle does not verify the endpoint chain" >&2
  exit 1
fi

echo
echo "Next: set GRPC_DEFAULT_SSL_ROOTS_FILE_PATH=$BUNDLE"
echo "  - systemd units: /etc/invest_tinkoff_bot.env"
echo "  - cron jobs:     inline before 'bundle exec' in each invest_tinkoff_bot line"
echo
echo "The REST half needs no extra variable: lib/broker_tls.rb reads the same"
echo "path (BROKER_CA_BUNDLE overrides it). Do not set SSL_CERT_FILE."
