#!/usr/bin/env bash
# One-time: tell the gateway how to reach YOUR Hysteria2 server, so the LunoX app can use it with nothing typed on the phone.
# Secrets are read silently (or, with your consent, read-only from the Hysteria2 server config) and stored 0600 for the gateway only.
# Usage: sudo bash set-hy2.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
NODE=/opt/lunox/runtime/bin/node; [ -x "$NODE" ] || NODE=$(command -v node || true)
[ -n "$NODE" ] || { echo "node not found (run install.sh first)"; exit 1; }

HOST="" PORT=443 AUTH="" OBFS="" SNI="" PIN="" INSECURE=false DOWN=50
CFG=""
for f in /etc/hysteria/config.yaml /etc/hysteria/config.yml /etc/hysteria2/config.yaml /usr/local/etc/hysteria/config.yaml; do [ -r "$f" ] && { CFG="$f"; break; }; done
if [ -n "$CFG" ]; then
  read -rp "Found your Hysteria2 server config at $CFG. Read password / obfs / certificate from it (read-only, nothing is changed)? [Y/n] " a
  if [ "${a:-Y}" != n ] && [ "${a:-Y}" != N ]; then
    # tolerant, dependency-free YAML scraping
    AUTH=$(awk '/^auth:/{s=1;next} s&&/^[^ \t#]/{s=0} s&&/^[ \t]+password:/{sub(/^[ \t]+password:[ \t]*/,"");gsub(/["\047]/,"");print;exit}' "$CFG")
    OBFS=$(awk '/^obfs:/{s=1;next} s&&/^[^ \t#]/{s=0} s&&/^[ \t]+password:/{sub(/^[ \t]+password:[ \t]*/,"");gsub(/["\047]/,"");print;exit}' "$CFG")
    LISTEN=$(awk '/^listen:/{sub(/^listen:[ \t]*/,"");gsub(/["\047]/,"");print;exit}' "$CFG"); LP="${LISTEN##*:}"; [[ "$LP" =~ ^[0-9]+$ ]] && PORT="$LP"
    CERT=$(awk '/^tls:/{s=1;next} s&&/^[^ \t#]/{s=0} s&&/^[ \t]+cert:/{sub(/^[ \t]+cert:[ \t]*/,"");gsub(/["\047]/,"");print;exit}' "$CFG")
    if [ -n "$CERT" ] && [ -r "$CERT" ]; then
      PIN=$(openssl x509 -in "$CERT" -outform DER | sha256sum | cut -d' ' -f1)
      SNI=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | head -1 | cut -d: -f2 || true)
    fi
    echo "read from config: password=$([ -n "$AUTH" ] && echo yes || echo no) obfs=$([ -n "$OBFS" ] && echo yes || echo no) port=$PORT cert-pin=$([ -n "$PIN" ] && echo yes || echo no) sni=${SNI:-<none>}"
  fi
fi

HOST_DEFAULT=$(curl -s -m 4 https://api.ipify.org || echo 186.244.245.83)
read -rp "Server address [$HOST_DEFAULT]: " HOST; HOST="${HOST:-$HOST_DEFAULT}"
read -rp "UDP port [$PORT]: " p; PORT="${p:-$PORT}"
[ -n "$AUTH" ] || { read -rsp "Hysteria2 password: " AUTH; echo; }
if [ -z "$OBFS" ]; then read -rsp "Obfuscation (salamander) password, empty = none: " OBFS; echo; fi
if [ -z "$PIN" ]; then
  read -rp "Certificate SHA-256 fingerprint (empty = none): " PIN
  if [ -z "$PIN" ]; then read -rp "Accept an untrusted/self-signed certificate (the 'allow insecure' switch)? [y/N] " i; [ "${i:-N}" = y ] || [ "${i:-N}" = Y ] && INSECURE=true || true; fi
fi
[ -n "$SNI" ] || read -rp "TLS server name (SNI), empty = server address: " SNI
read -rp "Downstream speed in Mbps [$DOWN]: " d; DOWN="${d:-$DOWN}"

mkdir -p /var/lib/lunox; umask 077
H2_HOST="$HOST" H2_PORT="$PORT" H2_AUTH="$AUTH" H2_OBFS="$OBFS" H2_SNI="$SNI" H2_PIN="$PIN" H2_INSECURE="$INSECURE" H2_DOWN="$DOWN" \
"$NODE" -e '
const e = process.env;
require("fs").writeFileSync("/var/lib/lunox/hy2.json", JSON.stringify({ host: e.H2_HOST, port: +e.H2_PORT, auth: e.H2_AUTH, obfs: e.H2_OBFS, sni: e.H2_SNI, pin: e.H2_PIN, insecure: e.H2_INSECURE === "true", downMbps: +e.H2_DOWN }), { mode: 0o600 });'
chown lunox:lunox /var/lib/lunox/hy2.json
echo "saved. Paired apps pick it up automatically (open the app > Settings > Network > Connection diagnostics to verify)."
