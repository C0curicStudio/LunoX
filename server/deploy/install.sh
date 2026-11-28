#!/usr/bin/env bash
# LunoX gateway installer — NON-INVASIVE.
#   * everything lives in /opt/lunox, /etc/lunox, /var/lib/lunox
#   * own system user + own systemd unit (CPU/RAM capped so other projects are not affected)
#   * does NOT touch firewall, nginx, hysteria2, or any existing service
#   * refuses to start if the port is already taken
# Usage: sudo bash install.sh <public-ip> [port=8443]
set -euo pipefail

IP="${1:-}"; PORT="${2:-8443}"
[ -n "$IP" ] || { echo "usage: sudo bash install.sh <public-ip> [port]"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 1/6 checking port $PORT (read-only)"
UPGRADE=0
if systemctl is-active --quiet lunox-gateway.service 2>/dev/null; then
  UPGRADE=1; echo "lunox-gateway is already running -> upgrading in place (config, key and certificate are kept)"
elif ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
  echo "!! TCP port $PORT is already in use by something else. Pick another: sudo bash install.sh $IP 9443"; ss -ltnp "sport = :$PORT"; exit 1
fi

echo "==> 2/6 node runtime"
NODE=""
if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ]; then
  NODE="$(command -v node)"; echo "using system node $(node -v) (not modified)"
else
  ARCH=$(uname -m); case "$ARCH" in x86_64) A=x64;; aarch64) A=arm64;; *) echo "unsupported arch $ARCH"; exit 1;; esac
  mkdir -p /opt/lunox/runtime && cd /opt/lunox/runtime
  V=v22.12.0
  curl -fsSL "https://nodejs.org/dist/$V/node-$V-linux-$A.tar.xz" | tar -xJ --strip-components=1
  NODE=/opt/lunox/runtime/bin/node; echo "installed private node $($NODE -v) in /opt/lunox/runtime"
fi

echo "==> 3/6 user & files"
id lunox >/dev/null 2>&1 || useradd --system --home /var/lib/lunox --shell /usr/sbin/nologin lunox
mkdir -p /opt/lunox/app /etc/lunox/tls /var/lib/lunox/sync
cp -r "$SRC/src" "$SRC/package.json" /opt/lunox/app/
chown -R root:root /opt/lunox/app
chown -R lunox:lunox /var/lib/lunox

echo "==> 4/6 TLS certificate (self-signed, pinned by the app)"
if [ ! -f /etc/lunox/tls/server.crt ]; then
  # iOS only accepts server certificates with serverAuth usage and a validity of at most ~13 months
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 397 \
    -keyout /etc/lunox/tls/server.key -out /etc/lunox/tls/server.crt \
    -subj "/CN=lunox-gateway" -addext "subjectAltName=IP:$IP" -addext "extendedKeyUsage=serverAuth" \
    -addext "keyUsage=critical,digitalSignature" -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
fi
chown root:lunox /etc/lunox/tls/server.key /etc/lunox/tls/server.crt
chmod 640 /etc/lunox/tls/server.key; chmod 644 /etc/lunox/tls/server.crt
PIN=$(openssl x509 -in /etc/lunox/tls/server.crt -outform DER | sha256sum | cut -d' ' -f1)

echo "==> 5/6 config"
if [ ! -f /etc/lunox/env ]; then
  KEY=$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40)
  cat > /etc/lunox/env <<ENV
LUNOX_PORT=$PORT
LUNOX_API_KEYS=$KEY
# ---- optional: smart features ----
# LLM_PROVIDER=anthropic            # or openai (any OpenAI-compatible endpoint)
# LLM_BASE_URL=https://api.anthropic.com
# LLM_API_KEY=
# LLM_MODEL=claude-haiku-5-5
# SEARCH_PROVIDER=brave             # or searxng
# SEARCH_API_KEY=
# SEARXNG_URL=
ENV
  chown root:lunox /etc/lunox/env; chmod 640 /etc/lunox/env
else
  KEY=$(grep '^LUNOX_API_KEYS=' /etc/lunox/env | cut -d= -f2 | cut -d, -f1)
  echo "(existing /etc/lunox/env kept)"
fi

echo "==> 6/6 systemd unit"
cat > /etc/systemd/system/lunox-gateway.service <<UNIT
[Unit]
Description=LunoX gateway (API + HTTPS CONNECT proxy)
After=network-online.target
Wants=network-online.target

[Service]
User=lunox
Group=lunox
EnvironmentFile=/etc/lunox/env
ExecStart=$NODE /opt/lunox/app/src/index.js
Restart=always
RestartSec=3
# --- be a good neighbour on a shared server ---
CPUQuota=60%
MemoryMax=512M
TasksMax=1024
LimitNOFILE=16384
Nice=5
# --- hardening ---
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=/var/lib/lunox
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable lunox-gateway.service >/dev/null 2>&1
systemctl restart lunox-gateway.service
sleep 1
systemctl --no-pager --lines=5 status lunox-gateway.service || true

cat <<DONE

================ DONE ================
Gateway : https://$IP:$PORT
API key : $KEY
Cert pin: $PIN

Paste this link into Safari/Notes on the iPhone (or enter the 4 values in the app's Settings > Network):
lunox://setup?host=$IP&port=$PORT&key=$KEY&pin=$PIN

NOT DONE ON PURPOSE: firewall. Open TCP $PORT yourself if needed, e.g.
  ufw allow $PORT/tcp        (or the cloud provider's security-group page)
Existing services (hysteria2 etc.) were not touched.
Remove everything later:  sudo bash $(dirname "$0")/uninstall.sh
DONE
