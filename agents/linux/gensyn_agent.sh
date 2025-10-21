#!/usr/bin/env bash
# Gensyn heartbeat agent (Linux)
# Sends node health to central server every run (use with systemd timer)
set -euo pipefail

# --- Config --------------------------------------------------------------------
# You can override via env or /etc/gensyn-agent.env
SERVER_URL="${SERVER_URL:-http://YOUR_MONITOR_HOST:8080}"
SHARED_SECRET="${SHARED_SECRET:-super-long-random-secret}"
NODE_ID="${NODE_ID:-$(hostname)-gensyn}"
META="${META:-}"                 # e.g. "hetzner-fsn1,ram=16g"
SCREEN_NAME="${SCREEN_NAME:-gensyn}"
CHECK_PORT="${CHECK_PORT:-true}" # check local UI port 3000
PORT="${PORT:-3000}"
IP_CMD="${IP_CMD:-https://ifconfig.me}"

# Optional: global env file
if [[ -f /etc/gensyn-agent.env ]]; then
  # shellcheck disable=SC1091
  . /etc/gensyn-agent.env
fi

# --- Helpers -------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

log() { printf '[%s] %s\n' "$(date -u +%F'T'%T'Z')" "$*" >&2; }

screen_ok() {
  have screen && screen -list 2>/dev/null | grep -qE "\.${SCREEN_NAME}[[:space:]]"
}

proc_ok() {
  have pgrep && pgrep -af "run_rl_swarm.sh|rl-swarm|python.*rl-swarm" >/dev/null 2>&1
}

port_ok() {
  if [[ "${CHECK_PORT}" != "true" ]]; then return 0; fi
  # Try bash /dev/tcp; fallback to nc if available
  if timeout 1 bash -c ">/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then
    return 0
  elif have nc && nc -z -w1 127.0.0.1 "${PORT}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

public_ip() {
  (curl -fsS --max-time 2 "${IP_CMD}" || true) | tr -d '\r\n'
}

# --- Health check --------------------------------------------------------------
status="DOWN"
if screen_ok && proc_ok && port_ok; then
  status="UP"
fi

IP="$(public_ip)"

payload=$(printf '{"node_id":"%s","ip":"%s","meta":"%s","status":"%s"}' \
  "$NODE_ID" "${IP}" "${META}" "${status}")

# --- Send heartbeat ------------------------------------------------------------
if ! have curl; then
  log "ERROR: curl not found"; exit 1
fi

curl -fsS -X POST "${SERVER_URL%/}/api/heartbeat" \
  -H "Authorization: Bearer ${SHARED_SECRET}" \
  -H "Content-Type: application/json" \
  --data "${payload}" >/dev/null 2>&1 || {
    log "WARN: heartbeat send failed"
    exit 0
  }

# optional local log
log "beat node_id=${NODE_ID} status=${status} ip=${IP}"
