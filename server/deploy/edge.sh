#!/usr/bin/env bash
# Puts the gateway behind Cloudflare's edge with a *quick tunnel* — no domain, no Cloudflare account, no token.
#   * downloads cloudflared into /opt/lunox/bin (nothing system-wide)
#   * own systemd unit (lunox-edge), CPU/RAM capped, runs as the unprivileged 'lunox' user
#   * outbound only: opens NO inbound port; traffic reaches a loopback-only HTTP listener (127.0.0.1)
# The app learns the *.trycloudflare.com address from the gateway automatically (GET /v1/config).
# Usage: sudo bash edge.sh        (safe to re-run)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -f /etc/lunox/env ] || { echo "run install.sh first"; exit 1; }
LOCAL_PORT="${LOCAL_PORT:-8480}"; METRICS_PORT="${METRICS_PORT:-8481}"

echo "==> 1/4 checking loopback ports $LOCAL_PORT,$METRICS_PORT (read-only)"
for p in "$LOCAL_PORT" "$METRICS_PORT"; do
  if ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && ! systemctl is-active --quiet lunox-edge.service && [ "$p" != "$LOCAL_PORT" -o -z "$(systemctl is-active lunox-gateway.service | grep -x active)" ]; then
    echo "!! port $p is in use by something else. Re-run with e.g.  LOCAL_PORT=18480 METRICS_PORT=18481 sudo -E bash edge.sh"; ss -ltnp "sport = :$p"; exit 1
  fi
done

echo "==> 2/4 cloudflared binary"
mkdir -p /opt/lunox/bin
if [ ! -x /opt/lunox/bin/cloudflared ]; then
  case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "unsupported arch"; exit 1;; esac
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$A" -o /opt/lunox/bin/cloudflared.tmp
  chmod 755 /opt/lunox/bin/cloudflared.tmp && mv /opt/lunox/bin/cloudflared.tmp /opt/lunox/bin/cloudflared
fi
/opt/lunox/bin/cloudflared --version

echo "==> 3/4 gateway config + unit"
setkv() { grep -q "^$1=" /etc/lunox/env && sed -i "s|^$1=.*|$1=$2|" /etc/lunox/env || echo "$1=$2" >> /etc/lunox/env; }
setkv LUNOX_LOCAL_HTTP_PORT "$LOCAL_PORT"
setkv LUNOX_EDGE_METRICS "127.0.0.1:$METRICS_PORT"
cat > /etc/systemd/system/lunox-edge.service <<UNIT
[Unit]
Description=LunoX Cloudflare quick tunnel (outbound only)
After=network-online.target lunox-gateway.service
Wants=network-online.target

[Service]
User=lunox
Group=lunox
Environment=HOME=/tmp
ExecStart=/opt/lunox/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$LOCAL_PORT --metrics 127.0.0.1:$METRICS_PORT
Restart=always
RestartSec=5
CPUQuota=30%
MemoryMax=256M
TasksMax=256
Nice=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl restart lunox-gateway.service
systemctl enable lunox-edge.service >/dev/null 2>&1
systemctl restart lunox-edge.service

echo "==> 4/4 waiting for the tunnel address (up to 45s)"
HOST=""
for _ in $(seq 1 45); do
  HOST=$(curl -s -m 2 "http://127.0.0.1:$METRICS_PORT/quicktunnel" 2>/dev/null | sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p' || true)
  [ -n "$HOST" ] && break; sleep 1
done
if [ -z "$HOST" ]; then echo "!! no tunnel address yet. Look at:  journalctl -u lunox-edge -n 30 --no-pager"; exit 1; fi
sleep 2
CODE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "https://$HOST/v1/health" || true)
cat <<DONE

================ EDGE READY ================
Cloudflare address : https://$HOST
Health (expects 401 = reachable, key required) : HTTP $CODE
The app picks this up by itself — nothing to type. It measures direct vs. Cloudflare and uses the faster one.
Note: a quick-tunnel address changes if lunox-edge restarts; the app re-learns it automatically.
DONE
