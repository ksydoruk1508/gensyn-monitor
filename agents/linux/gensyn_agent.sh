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
GSWARM_EOA="${GSWARM_EOA:-}"
GSWARM_PEER_IDS="${GSWARM_PEER_IDS:-}"  # comma-separated or JSON array

# Extra detection knobs
AUTO_KILL_EMPTY_SCREEN="${AUTO_KILL_EMPTY_SCREEN:-false}"

# Runtime “allow/deny”
# ⚠️ NOTE: default uses double quotes here; in /etc/gensyn-agent.env prefer SINGLE quotes for regex values.
ALLOW_REGEX="${ALLOW_REGEX:-rgym_exp\.runner\.swarm_launcher|hivemind_cli/p2pd|(^|[/[:space:]])rl-swarm([[:space:]]|$)|python[^ ]*.*rgym_exp}"
DENY_REGEX="${DENY_REGEX:-run_rl_swarm\.sh|while[[:space:]]+true|sleep[[:space:]]+60}"

# Consider UP if target process exists outside screen
PROC_FALLBACK_WITHOUT_SCREEN="${PROC_FALLBACK_WITHOUT_SCREEN:-true}"

# p2pd requirement: false | any | screen
REQUIRE_P2PD="${REQUIRE_P2PD:-false}"

# Variant B: require fresh log
LOG_FILE="${LOG_FILE:-}"            # e.g. /root/rl-swarm/logs/swarm.log
LOG_MAX_AGE="${LOG_MAX_AGE:-300}"   # seconds

# Optional: global env file
if [[ -f /etc/gensyn-agent.env ]]; then
  # shellcheck disable=SC1091
  . /etc/gensyn-agent.env
fi

# --- Helpers -------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '[%s] %s\n' "$(date -u +%F'T'%T'Z')" "$*" >&2; }
json_escape() {
  local str="${1:-}"
  str=${str//\\/\\\\}
  str=${str//\"/\\\"}
  str=${str//$'\n'/\\n}
  str=${str//$'\r'/\\r}
  printf '%s' "$str"
}

# screen name like "12345.gensyn"
screen_session_name() {
  have screen || return 1
  screen -list 2>/dev/null \
    | sed -nE "s/^[[:space:]]*([0-9]+\.${SCREEN_NAME})[[:space:]].*/\1/p" \
    | head -n1
}

# Is there an ALLOW process in THIS screen (and not matching DENY)?
has_target_in_screen() {
  local sname="$1" p args
  [[ -z "$sname" ]] && return 1
  have pgrep || return 1
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "STY=$sname"; then
      args=$(ps -p "$p" -o args= 2>/dev/null || true)
      if ! grep -Eiq "$DENY_REGEX" <<<"$args"; then
        return 0
      fi
    fi
  done < <(pgrep -f "$ALLOW_REGEX" 2>/dev/null || true)
  return 1
}

# Require p2pd: false (no requirement) | any (anywhere) | screen (inside this screen)
p2pd_ok() {
  local mode="${REQUIRE_P2PD}"
  case "$mode" in
    false) return 0 ;;
    any)
      pgrep -f 'hivemind_cli/p2pd' >/dev/null 2>&1
      return $?
      ;;
    screen)
      local sname="$1"
      [[ -n "$sname" ]] || return 1
      have pgrep || return 1
      while IFS= read -r p; do
        tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "STY=$sname" && return 0
      done < <(pgrep -f 'hivemind_cli/p2pd' 2>/dev/null || true)
      return 1
      ;;
    *) return 0 ;;
  esac
}

# If no screen allowed: any ALLOW process?
proc_ok() {
  [[ "$PROC_FALLBACK_WITHOUT_SCREEN" != "true" ]] && return 1
  have pgrep && pgrep -f "$ALLOW_REGEX" >/dev/null 2>&1
}

# Port check
port_ok() {
  if [[ "${CHECK_PORT}" != "true" ]]; then return 0; fi
  if timeout 1 bash -c ">/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then
    return 0
  elif have nc && nc -z -w1 127.0.0.1 "${PORT}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Log freshness (Variant B)
log_fresh() {
  [[ -z "${LOG_FILE}" ]] && return 0
  [[ ! -f "${LOG_FILE}" ]] && return 1
  local now ts age
  now=$(date +%s)
  ts=$(stat -c %Y "${LOG_FILE}" 2>/dev/null || echo 0)
  age=$(( now - ts ))
  [[ ${age} -le ${LOG_MAX_AGE} ]]
}

public_ip() {
  (curl -fsS --max-time 2 "${IP_CMD}" || true) | tr -d '\r\n'
}

# --- Health check --------------------------------------------------------------
status="DOWN"
reason=""

sname="$(screen_session_name || true)"

if [[ -n "$sname" ]]; then
  if ! has_target_in_screen "$sname"; then
    reason="empty_screen_no_runtime"
  elif ! p2pd_ok "$sname"; then
    reason="no_p2pd_in_screen"
  elif ! port_ok; then
    reason="port_closed_${PORT}"
  elif ! log_fresh; then
    reason="stale_log"
  else
    status="UP"
  fi

  if [[ "$status" == "DOWN" && "$reason" == "empty_screen_no_runtime" && "$AUTO_KILL_EMPTY_SCREEN" == "true" ]]; then
    screen -S "$SCREEN_NAME" -X quit || true
    log "INFO: auto-closed empty screen $SCREEN_NAME"
  fi
else
  # No screen found — allow fallback if enabled
  if proc_ok; then
    if ! p2pd_ok ""; then
      reason="no_p2pd"
    elif ! port_ok; then
      reason="port_closed_${PORT}"
    elif ! log_fresh; then
      reason="stale_log"
    else
      status="UP"
    fi
  else
    reason="no_screen_no_proc"
  fi
fi

IP="$(public_ip)"

# put reason into meta when DOWN (to see it in /api/nodes & UI)
META_OUT="${META}"
[[ -n "$reason" && "$status" != "UP" ]] && META_OUT="${META:+$META,}reason=${reason}"

payload=$(printf '{"node_id":"%s","ip":"%s","meta":"%s","status":"%s"' \
  "$(json_escape "$NODE_ID")" \
  "$(json_escape "$IP")" \
  "$(json_escape "$META_OUT")" \
  "$(json_escape "$status")")
if [[ -n "$GSWARM_EOA" ]]; then
  payload=$(printf '%s,"gswarm_eoa":"%s"' "$payload" "$(json_escape "$GSWARM_EOA")")
fi
if [[ -n "$GSWARM_PEER_IDS" ]]; then
  payload=$(printf '%s,"gswarm_peer_ids":"%s"' "$payload" "$(json_escape "$GSWARM_PEER_IDS")")
fi
payload="${payload}}"

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

log "beat node_id=${NODE_ID} status=${status} ip=${IP}${reason:+ reason=${reason}}"
