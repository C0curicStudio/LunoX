#!/usr/bin/env bash
# READ-ONLY. Run it and send a screenshot of the output. Prints no secrets.
echo "== service";  systemctl is-active lunox-gateway.service; systemctl --no-pager --lines=0 status lunox-gateway.service | head -6
echo "== edge (cloudflare quick tunnel)"; systemctl is-active lunox-edge.service 2>/dev/null; curl -s -m 2 http://127.0.0.1:8481/quicktunnel 2>/dev/null; echo
echo "== listening"; ss -ltnp 2>/dev/null | grep -E 'lunox|node' || echo "(nothing)"
echo "== port 8443 owner"; ss -ltnH 'sport = :8443'
echo "== last 15 log lines (no keys are ever logged)"; journalctl -u lunox-gateway -n 15 --no-pager -o cat 2>/dev/null
echo "== resources"; systemctl show lunox-gateway -p MemoryCurrent -p CPUUsageNSec 2>/dev/null
echo "== cert pin"; openssl x509 -in /etc/lunox/tls/server.crt -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1
