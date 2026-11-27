#!/usr/bin/env bash
# Opens ONE tcp port (default 8443) in whichever firewall is already active. Adds a single rule; never flushes,
# reloads others, or changes policies. Usage: sudo bash open-firewall.sh [port]
set -euo pipefail
PORT="${1:-8443}"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
done=0
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" comment 'lunox-gateway' && done=1; echo "ufw: allowed $PORT/tcp"
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null && firewall-cmd --reload >/dev/null && done=1; echo "firewalld: allowed $PORT/tcp"
fi
if [ "$done" = 0 ] && command -v iptables >/dev/null; then
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  echo "iptables: inserted ACCEPT for $PORT/tcp (not persistent across reboot unless you use netfilter-persistent)"; done=1
fi
[ "$done" = 1 ] || echo "no active host firewall found."
echo "Also open TCP $PORT in your cloud provider's security group if it has one."
