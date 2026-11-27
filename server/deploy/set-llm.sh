#!/usr/bin/env bash
# Optional helper: store your model API key on the server (reads it silently). The app can also do this from Settings.
# Usage: sudo bash set-llm.sh [anthropic|openai] [model] [base_url]
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
PROVIDER="${1:-anthropic}"; MODEL="${2:-claude-haiku-5-5}"; BASE="${3:-}"
[ -n "$BASE" ] || { [ "$PROVIDER" = anthropic ] && BASE=https://api.anthropic.com || BASE=https://api.openai.com; }
read -rsp "Model API key: " KEY; echo
mkdir -p /var/lib/lunox
umask 077
printf '{"provider":"%s","baseUrl":"%s","model":"%s","apiKey":"%s"}' "$PROVIDER" "$BASE" "$MODEL" "$KEY" > /var/lib/lunox/llm.json
chown lunox:lunox /var/lib/lunox/llm.json
systemctl restart lunox-gateway.service && echo "saved; provider=$PROVIDER model=$MODEL"
