#!/usr/bin/env bash
# Removes ONLY what install.sh created.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
systemctl disable --now lunox-edge.service 2>/dev/null || true
systemctl disable --now lunox-gateway.service 2>/dev/null || true
rm -f /etc/systemd/system/lunox-gateway.service /etc/systemd/system/lunox-edge.service
systemctl daemon-reload
rm -rf /opt/lunox /etc/lunox
echo "kept /var/lib/lunox (sync data) and user 'lunox'. Remove with: rm -rf /var/lib/lunox; userdel lunox"
