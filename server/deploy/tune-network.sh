#!/usr/bin/env bash
# OPTIONAL, asks before doing anything. Turns on BBR congestion control (+fq, TCP Fast Open): the single biggest
# throughput win for a long-distance proxy link. NOTE: this is a *system-wide* kernel setting, so it also affects
# your other services (normally for the better). Undo anytime: sudo rm /etc/sysctl.d/99-lunox-tune.conf && sudo sysctl --system
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
echo "current congestion control : $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "available                  : $(sysctl -n net.ipv4.tcp_available_congestion_control)"
echo "kernel                     : $(uname -r)"
if sysctl -n net.ipv4.tcp_congestion_control | grep -qx bbr; then echo "BBR is already on. Nothing to do."; exit 0; fi
modprobe tcp_bbr 2>/dev/null || true
grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || { echo "This kernel has no BBR (need Linux >= 4.9)."; exit 1; }
read -rp "Enable BBR + fq + TCP Fast Open system-wide? [y/N] " a
[ "$a" = y ] || [ "$a" = Y ] || { echo "cancelled, nothing changed"; exit 0; }
cat > /etc/sysctl.d/99-lunox-tune.conf <<'CONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
CONF
sysctl --system >/dev/null
echo "now: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
