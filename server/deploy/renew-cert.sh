#!/usr/bin/env bash
# Re-issues the gateway's self-signed TLS certificate so that iOS accepts it:
#   * validity 397 days (Apple rejects longer-lived TLS server certificates),
#   * extendedKeyUsage = serverAuth, keyUsage = digitalSignature, basicConstraints CA:FALSE, SAN = the server IP.
# Only touches /etc/lunox/tls and restarts lunox-gateway. Prints the new pairing link (the certificate fingerprint changes -> pair again).
# Re-run about once a year.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
[ -d /etc/lunox/tls ] || { echo "run install.sh first"; exit 1; }
IP="${1:-$(openssl x509 -in /etc/lunox/tls/server.crt -noout -ext subjectAltName 2>/dev/null | grep -oE 'IP Address:[0-9.]+' | head -1 | cut -d: -f2 || true)}"
[ -n "$IP" ] || IP=$(curl -s -m 4 https://api.ipify.org || true)
[ -n "$IP" ] || { echo "cannot work out the server IP; pass it: sudo bash renew-cert.sh 1.2.3.4"; exit 1; }
STAMP=$(date +%Y%m%d%H%M%S)
cp -a /etc/lunox/tls/server.crt "/etc/lunox/tls/server.crt.$STAMP.bak" 2>/dev/null || true
cp -a /etc/lunox/tls/server.key "/etc/lunox/tls/server.key.$STAMP.bak" 2>/dev/null || true
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 397 \
  -keyout /etc/lunox/tls/server.key -out /etc/lunox/tls/server.crt \
  -subj "/CN=lunox-gateway" \
  -addext "subjectAltName=IP:$IP" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
chown root:lunox /etc/lunox/tls/server.key /etc/lunox/tls/server.crt
chmod 640 /etc/lunox/tls/server.key; chmod 644 /etc/lunox/tls/server.crt
systemctl restart lunox-gateway.service
sleep 2
echo "new certificate:"; openssl x509 -in /etc/lunox/tls/server.crt -noout -subject -dates -ext subjectAltName,extendedKeyUsage 2>/dev/null | cut -c1-120
echo "gateway: $(systemctl is-active lunox-gateway.service)"
echo
echo "Copy the line below, then in LunoX tap the orange banner (or Settings > Network > Pair from clipboard):"
bash "$(dirname "$0")/pair-link.sh" | grep '^lunox://' || true
