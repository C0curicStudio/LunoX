#!/usr/bin/env bash
# Prints the one-line pairing link for the iPhone app (host + key + certificate fingerprint). Read-only.
set -euo pipefail
[ -r /etc/lunox/env ] || { echo "run as root (sudo) after install.sh"; exit 1; }
IP="${1:-$(grep -m1 -oE 'host=[^&]+' /dev/null 2>/dev/null || true)}"
PORT=$(grep -m1 '^LUNOX_PORT=' /etc/lunox/env | cut -d= -f2); PORT="${PORT:-8443}"
KEY=$(grep -m1 '^LUNOX_API_KEYS=' /etc/lunox/env | cut -d= -f2 | cut -d, -f1)
PIN=$(openssl x509 -in /etc/lunox/tls/server.crt -outform DER | sha256sum | cut -d' ' -f1)
[ -n "$IP" ] || IP=$(curl -s -m 4 https://api.ipify.org || echo 186.244.245.83)
echo
echo "Copy this ONE line (long-press, Select All/Copy), then in the app: Settings > Network > paste > Import"
echo
echo "lunox://setup?host=$IP&port=$PORT&key=$KEY&pin=$PIN"
echo
