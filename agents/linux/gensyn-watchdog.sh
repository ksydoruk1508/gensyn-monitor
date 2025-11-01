#!/usr/bin/env bash
set -euo pipefail

AGENT_UNIT="gensyn-agent.service"
TARGET_SERVICE="gensyn-screen-launcher.service"

log() {
  printf '[%s] %s\n' "$(date -u +%F'T'%T'Z')" "$*" >&2
}

get_last_status() {
  local last_line
  last_line=$(journalctl -u "$AGENT_UNIT" --no-pager -n 200 2>/dev/null \
    | grep "status=" \
    | tail -n 1 \
    || true)

  if [[ -z "$last_line" ]]; then
    echo "UNKNOWN"; return
  fi
  if echo "$last_line" | grep -q "status=DOWN"; then
    echo "DOWN"; return
  fi
  if echo "$last_line" | grep -q "status=UP"; then
    echo "UP"; return
  fi
  echo "UNKNOWN"
}

main() {
  local current_status
  current_status=$(get_last_status)

  log "current reported status=$current_status"

  if [[ "$current_status" == "DOWN" ]]; then
    log "status DOWN -> restarting $TARGET_SERVICE"
    systemctl restart "$TARGET_SERVICE"
    log "$TARGET_SERVICE restart requested"
  else
    log "status $current_status -> no action"
  fi
}

main
