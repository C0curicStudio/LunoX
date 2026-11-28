#!/usr/bin/env bash
# Tell the gateway how to reach YOUR Hysteria2 server so the LunoX app can use it with nothing typed on the phone.
# Nothing in your Hysteria2 server config is changed (it is only READ, with --auto).
#
#   sudo bash set-hy2.sh --auto                        # read everything from /etc/hysteria/config.yaml, no questions
#   sudo bash set-hy2.sh --host 1.2.3.4 --port 443 --password 'PW' --obfs 'OBFS' --insecure --down 50    # all in one line
#   sudo bash set-hy2.sh                               # interactive (asks only what is missing)
# Options: --host --port --password --obfs --sni --pin <sha256> --insecure --down <Mbps> --config <file> --yes
set -euo pipefail
[ "$(id -u)" = 0 ] || [ -n "${HY2_STATE_DIR:-}" ] || { echo "run as root (sudo)"; exit 1; }
STATE_DIR="${HY2_STATE_DIR:-/var/lib/lunox}"
NODE=/opt/lunox/runtime/bin/node; [ -x "$NODE" ] || NODE=$(command -v node || true)
[ -n "$NODE" ] || { echo "node not found (run install.sh first)"; exit 1; }

HOST="" PORT="" AUTH="" OBFS="" SNI="" PIN="" INSECURE=""; DOWN=""; CFG=""; AUTO=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) AUTO=1;; --yes|-y) YES=1;; --insecure) INSECURE=true;;
    --host) HOST="$2"; shift;; --port) PORT="$2"; shift;; --password) AUTH="$2"; shift;; --obfs) OBFS="$2"; shift;;
    --sni) SNI="$2"; shift;; --pin) PIN="$2"; shift;; --down) DOWN="$2"; shift;; --config) CFG="$2"; shift;;
    *) echo "unknown option $1"; exit 1;;
  esac; shift
done
[ $AUTO = 1 ] || [ -n "$AUTH" ] || [ -n "$HOST" ] || [ -n "$OBFS" ] || INTERACTIVE=1
INTERACTIVE="${INTERACTIVE:-0}"

yaml() { awk -v sec="$1" -v key="$2" -v sub2="${3:-}" '
  $0 ~ "^"sec":" {s=1; t=(sub2==""); next}
  s && /^[^ \t#]/ {s=0}
  s && sub2!="" && $0 ~ "^[ \t]+"sub2":" {t=1; next}
  s && t && $0 ~ "^[ \t]+"key":" {sub("^[ \t]+"key":[ \t]*",""); gsub(/["\047]/,""); print; exit}' "$CFG"; }

if [ -z "$CFG" ]; then for f in /etc/hysteria/config.yaml /etc/hysteria/config.yml /etc/hysteria2/config.yaml /usr/local/etc/hysteria/config.yaml; do [ -r "$f" ] && { CFG="$f"; break; }; done; fi
if [ -n "$CFG" ] && [ -r "$CFG" ] && { [ $AUTO = 1 ] || [ $YES = 1 ] || [ $INTERACTIVE = 1 ]; }; then
  if [ $AUTO = 1 ] || [ $YES = 1 ] || { read -rp "Found $CFG. Read password / obfs / certificate from it (read-only)? [Y/n] " a; [ "${a:-Y}" != n ] && [ "${a:-Y}" != N ]; }; then
    [ -n "$AUTH" ] || AUTH=$(yaml auth password)
    [ -n "$OBFS" ] || OBFS=$(yaml obfs password salamander)
    [ -n "$PORT" ] || { L=$(awk '/^listen:/{sub(/^listen:[ \t]*/,"");gsub(/["\047]/,"");print;exit}' "$CFG"); L="${L##*:}"; [[ "$L" =~ ^[0-9]+$ ]] && PORT="$L"; }
    CERT=$(yaml tls cert)
    if [ -z "$PIN" ] && [ -n "$CERT" ] && [ -r "$CERT" ]; then
      PIN=$(openssl x509 -in "$CERT" -outform DER | sha256sum | cut -d' ' -f1)
      [ -n "$SNI" ] || SNI=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | head -1 | cut -d: -f2 || true)
    fi
    echo "read from $CFG: password=$([ -n "$AUTH" ] && echo yes || echo NO) obfs=$([ -n "$OBFS" ] && echo yes || echo none) port=${PORT:-?} cert-pin=$([ -n "$PIN" ] && echo yes || echo none)"
  fi
elif [ $AUTO = 1 ]; then echo "--auto: no readable Hysteria2 config found; pass --password/--obfs explicitly"; exit 1; fi

[ -n "$HOST" ] || HOST=$(curl -s -m 4 https://api.ipify.org || echo 186.244.245.83)
[ -n "$PORT" ] || PORT=443
[ -n "$DOWN" ] || DOWN=50
if [ -z "$AUTH" ]; then
  [ $INTERACTIVE = 1 ] || { echo "Hysteria2 password missing: add --password 'PW' (or use --auto if /etc/hysteria/config.yaml is readable)"; exit 1; }
  read -rsp "Hysteria2 password: " AUTH; echo
fi
if [ $INTERACTIVE = 1 ]; then
  [ -n "$OBFS" ] || { read -rsp "Obfuscation (salamander) password, empty = none: " OBFS; echo; }
  if [ -z "$PIN" ] && [ -z "$INSECURE" ]; then read -rp "Accept an untrusted/self-signed certificate? [y/N] " i; [ "${i:-N}" = y ] || [ "${i:-N}" = Y ] && INSECURE=true || true; fi
fi
# no pin and no explicit choice: a self-signed IP-only server is by far the common case, so accept it rather than fail silently
[ -n "$PIN" ] || [ -n "$INSECURE" ] || { INSECURE=true; echo "note: no certificate pin found -> accepting the server certificate without verification (add --pin <sha256> to pin it)"; }
INSECURE="${INSECURE:-false}"

mkdir -p "$STATE_DIR"; umask 077
H2_FILE="$STATE_DIR/hy2.json" H2_HOST="$HOST" H2_PORT="$PORT" H2_AUTH="$AUTH" H2_OBFS="$OBFS" H2_SNI="$SNI" H2_PIN="$PIN" H2_INSECURE="$INSECURE" H2_DOWN="$DOWN" \
"$NODE" -e '
const e = process.env;
require("fs").writeFileSync(e.H2_FILE, JSON.stringify({ host: e.H2_HOST, port: +e.H2_PORT, auth: e.H2_AUTH, obfs: e.H2_OBFS, sni: e.H2_SNI, pin: e.H2_PIN, insecure: e.H2_INSECURE === "true", downMbps: +e.H2_DOWN }), { mode: 0o600 });'
id lunox >/dev/null 2>&1 && chown lunox:lunox "$STATE_DIR/hy2.json" || true
echo "saved -> $STATE_DIR/hy2.json   host=$HOST port=$PORT obfs=$([ -n "$OBFS" ] && echo on || echo off) pin=$([ -n "$PIN" ] && echo on || echo off) insecure=$INSECURE down=${DOWN}Mbps"
echo "Open LunoX > Settings > Network > Connection diagnostics: the 'built-in Hysteria2' line should turn green."
