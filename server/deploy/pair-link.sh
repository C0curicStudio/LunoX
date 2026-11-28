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
HY2=""
if [ -r /var/lib/lunox/hy2.json ]; then
  NODE=/opt/lunox/runtime/bin/node; [ -x "$NODE" ] || NODE=$(command -v node)
  HY2="&hy2=$("$NODE" -e 'process.stdout.write(Buffer.from(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")))).toString("base64url"))' /var/lib/lunox/hy2.json)"
fi
EDGE=""
EM=$(grep -m1 '^LUNOX_EDGE_METRICS=' /etc/lunox/env | cut -d= -f2 || true)
if [ -n "$EM" ]; then
  EH=$(curl -s -m 3 "http://$EM/quicktunnel" 2>/dev/null | sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p' || true)
  [ -n "$EH" ] && EDGE="&edge=$EH&edgePort=443"
fi
echo "lunox://setup?host=$IP&port=$PORT&key=$KEY&pin=$PIN$EDGE$HY2"
echo
