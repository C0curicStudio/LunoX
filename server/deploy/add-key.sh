#!/usr/bin/env bash
# Add a per-device key (so a lost phone can be revoked alone) and restart only our service.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
NEW=$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40)
sed -i "s/^LUNOX_API_KEYS=\(.*\)/LUNOX_API_KEYS=\1,$NEW/" /etc/lunox/env
systemctl restart lunox-gateway.service
echo "new device key: $NEW"
