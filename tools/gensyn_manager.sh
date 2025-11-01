#!/usr/bin/env bash
#
# Gensyn Manager
# - prepare machine
# - install/update/remove dashboard monitor
# - install/reinstall/remove heartbeat agent
# - install/remove autorestart (watchdog + launcher)
# - show status/logs
#
set -euo pipefail

########################################
# Color setup
########################################
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
BOLD="\033[1m"
RESET="\033[0m"

say_info()  { printf "${BLUE}[i]${RESET} %s\n" "$*"; }
say_ok()    { printf "${GREEN}[+]${RESET} %s\n" "$*"; }
say_warn()  { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
say_err()   { printf "${RED}[x]${RESET} %s\n" "$*" >&2; }

########################################
# Paths / constants
########################################

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# IMPORTANT:
# These must point to your repo.
# Right now you have it under ksydoruk1508/gensyn-monitor.
REPO_URL="https://github.com/ksydoruk1508/gensyn-monitor.git"
REPO_DIR="/opt/gensyn-monitor"
RAW_BASE="https://raw.githubusercontent.com/ksydoruk1508/gensyn-monitor/main"

SERVICE_NAME="gensyn-monitor"

# heartbeat agent
AGENT_BIN="/usr/local/bin/gensyn_agent.sh"
AGENT_ENV="/etc/gensyn-agent.env"
AGENT_SERVICE="/etc/systemd/system/gensyn-agent.service"
AGENT_TIMER="/etc/systemd/system/gensyn-agent.timer"

# autorestart (watchdog + screen launcher)
WATCHDOG_BIN="/usr/local/bin/gensyn-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/gensyn-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/gensyn-watchdog.timer"

LAUNCHER_BIN="/usr/local/bin/gensyn-screen-launcher.sh"
LAUNCHER_SERVICE="/etc/systemd/system/gensyn-screen-launcher.service"

SWARM_LOG="/var/log/gensyn-swarm.log"

########################################
# Banner
########################################
display_logo() {
  cat <<'EOF'
 _   _           _  _____
| \ | |         | ||____ |
|  \| | ___   __| |    / /_ __
| . ` |/ _ \ / _` |    \ \ '__|
| |\  | (_) | (_| |.___/ / |
\_| \_/\___/ \__,_|\____/|_|

     Gensyn Manager
       @NodesN3R
EOF
}

########################################
# Basic helpers
########################################
need_root() {
  if [[ $EUID -ne 0 ]]; then
    say_err "Run as root (sudo $0)"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

current_repo_dir() {
  # read WorkingDirectory from gensyn-monitor.service if exists
  local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
  if [[ -f "$service_file" ]]; then
    local dir
    dir=$(awk -F= '/^WorkingDirectory=/{print $2; exit}' "$service_file")
    if [[ -n "$dir" ]]; then
      printf '%s' "$dir"
      return 0
    fi
  fi
  printf '%s' "$REPO_DIR"
}

ask() {
  local prompt="$1" default="${2:-}"
  local value
  read -rp "$prompt${default:+ [$default]}: " value || true
  if [[ -z "${value:-}" && -n "$default" ]]; then
    value="$default"
  fi
  printf '%s' "${value:-}"
}

# safe single-arg shell quoting for .env style values
shell_quote() {
  if have_cmd python3; then
    python3 - "$1" <<'PY'
import shlex, sys
value = sys.argv[1] if len(sys.argv) > 1 else ""
print(shlex.quote(value))
PY
  else
    printf '%q' "$1"
  fi
}

json_string() {
  if have_cmd python3; then
    python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1] if len(sys.argv) > 1 else ""))
PY
  else
    local val="${1//\\/\\\\}"; val="${val//\"/\\\"}"
    printf '"%s"' "$val"
  fi
}

ensure_dos2unix() {
  if ! have_cmd dos2unix; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y dos2unix >/dev/null 2>&1 || true
  fi
}

crlf_fix() {
  ensure_dos2unix
  for f in "$@"; do
    [[ -f "$f" ]] && dos2unix -q "$f" || true
  done
}

wait_port_free() {
  local port="$1"
  if ss -ltn "( sport = :$port )" | grep -q ":$port"; then
    say_err "Port $port is already in use."
    ss -ltnp | grep ":$port" || true
    say_warn "Pick another port or stop that process."
    exit 1
  fi
}

maybe_open_firewall_port() {
  local port="$1"
  local answer
  read -rp "Open ${port}/tcp in firewall? (y/N): " answer || true
  case "${answer,,}" in
    y|yes)
      if have_cmd ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -n1 || true)
        if [[ "$ufw_status" =~ inactive ]]; then
          say_info "ufw installed but inactive -> skipping rule"
        else
          say_info "ufw allow ${port}/tcp"
          ufw allow "${port}/tcp" >/dev/null 2>&1 || ufw allow "${port}" >/dev/null 2>&1 || true
          ufw reload >/dev/null 2>&1 || true
        fi
      elif have_cmd firewall-cmd; then
        say_info "firewalld add-port ${port}/tcp"
        firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
      else
        say_warn "No supported firewall (ufw/firewalld). Add rule manually if needed."
      fi
      ;;
    *) say_info "Skipping firewall config." ;;
  esac
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]] ; }

json_validate() {
  local s="$1"
  if have_cmd jq; then
    echo "$s" | jq -e . >/dev/null 2>&1
    return $?
  elif have_cmd python3; then
    python3 - <<'PY' 2>/dev/null
import json,sys
try:
    json.loads(sys.argv[1])
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
    return $?
  else
    # no validator, just accept
    return 0
  fi
}

write_kv() {
  local k="$1" v="$2"
  v=${v//$'\r'/}
  v=${v//$'\n'/}
  printf '%s=%s\n' "$k" "$v"
}

########################################
# Monitor (.env prompt, install, update, status, logs, remove)
########################################

prompt_monitor_env() {
  local repo="$1" env_file="$repo/.env"

  say_info "Configuring .env for dashboard monitor"

  # defaults (can be pre-exported)
  local _bot="${DEFAULT_TELEGRAM_BOT_TOKEN:-}"
  local _chat="${DEFAULT_TELEGRAM_CHAT_ID:-}"
  local _shared="${DEFAULT_SHARED_SECRET:-}"
  local _admin="${DEFAULT_ADMIN_TOKEN:-}"
  local _title="${DEFAULT_SITE_TITLE:-Gensyn Nodes}"
  local _thr="${DEFAULT_DOWN_THRESHOLD_SEC:-180}"
  local _interval="${DEFAULT_GSWARM_REFRESH_INTERVAL:-600}"
  local _show_src="${DEFAULT_GSWARM_SHOW_SRC:-auto}"
  local _autosend="${DEFAULT_GSWARM_AUTO_SEND:-0}"
  local _nodemap="${DEFAULT_GSWARM_NODE_MAP:-}"

  if [[ -f "$env_file" ]]; then
    say_info "$env_file exists: empty answers will keep current values."
    set +u
    source "$env_file" 2>/dev/null || true
    _bot="${_bot:-${TELEGRAM_BOT_TOKEN:-}}"
    _chat="${_chat:-${TELEGRAM_CHAT_ID:-}}"
    _shared="${_shared:-${SHARED_SECRET:-}}"
    _admin="${_admin:-${ADMIN_TOKEN:-}}"
    _title="${_title:-${SITE_TITLE:-Gensyn Nodes}}"
    _thr="${_thr:-${DOWN_THRESHOLD_SEC:-180}}"
    _interval="${_interval:-${GSWARM_REFRESH_INTERVAL:-600}}"
    _show_src="${_show_src:-${GSWARM_SHOW_SRC:-auto}}"
    _autosend="${_autosend:-${GSWARM_AUTO_SEND:-0}}"
    _nodemap="${_nodemap:-${GSWARM_NODE_MAP:-}}"
    set -u
  fi

  TE_BOT="$(ask "TELEGRAM_BOT_TOKEN" "$_bot")"
  TE_CHAT="$(ask "TELEGRAM_CHAT_ID" "$_chat")"
  SHARED="$(ask "SHARED_SECRET" "$_shared")"
  ADMIN="$(ask "ADMIN_TOKEN (optional)" "$_admin")"
  TITLE="$(ask "SITE_TITLE" "$_title")"

  THR="$(ask "DOWN_THRESHOLD_SEC (seconds)" "$_thr")"
  while [[ -n "$THR" ]] && ! is_number "$THR"; do
    say_warn "Must be a number"
    THR="$(ask "DOWN_THRESHOLD_SEC (seconds)" "$_thr")"
  done

  INTV="$(ask "GSWARM_REFRESH_INTERVAL (seconds)" "$_interval")"
  while [[ -n "$INTV" ]] && ! is_number "$INTV"; do
    say_warn "Must be a number"
    INTV="$(ask "GSWARM_REFRESH_INTERVAL (seconds)" "$_interval")"
  done

  SHOW_SRC="$(ask "GSWARM_SHOW_SRC (auto/always/never)" "$_show_src")"
  case "${SHOW_SRC,,}" in
    always|never|auto) SHOW_SRC="${SHOW_SRC,,}" ;;
    *) SHOW_SRC="auto" ;;
  esac

  AUTOSEND="$(ask "GSWARM_AUTO_SEND (0/1)" "$_autosend")"
  [[ "$AUTOSEND" != "1" ]] && AUTOSEND="0"

  echo
  say_info "GSWARM_NODE_MAP must be valid JSON or empty."
  echo 'Example: {"node-1":{"eoa":"0x...","peer_ids":["Qm.."],"tgid":"123456"}}'
  NODEMAP_INPUT="$(ask "GSWARM_NODE_MAP (JSON or empty)" "$_nodemap")"
  if [[ -n "$NODEMAP_INPUT" ]] && ! json_validate "$NODEMAP_INPUT"; then
    say_warn "Invalid JSON. Using empty."
    NODEMAP_INPUT=""
  fi

  local tmp="$env_file.tmp.$$"
  {
    write_kv "TELEGRAM_BOT_TOKEN" "$TE_BOT"
    write_kv "TELEGRAM_CHAT_ID" "$TE_CHAT"
    write_kv "SHARED_SECRET" "$SHARED"
    write_kv "ADMIN_TOKEN" "$ADMIN"
    write_kv "SITE_TITLE" "$TITLE"
    write_kv "DOWN_THRESHOLD_SEC" "${THR:-180}"
    write_kv "GSWARM_REFRESH_INTERVAL" "${INTV:-600}"
    write_kv "GSWARM_SHOW_SRC" "${SHOW_SRC:-auto}"
    write_kv "GSWARM_AUTO_SEND" "${AUTOSEND:-0}"
    if [[ -n "$NODEMAP_INPUT" ]]; then
      echo "GSWARM_NODE_MAP=$NODEMAP_INPUT"
    else
      echo "GSWARM_NODE_MAP="
    fi
    # ensure DB_PATH present too
    write_kv "DB_PATH" "${repo}/monitor.db"
  } >"$tmp"
  mv -f "$tmp" "$env_file"

  say_ok ".env updated: $env_file"
}

prepare_device() {
  need_root
  say_info "Installing base dependencies..."
  apt-get update
  apt-get install -y python3 python3-venv python3-pip git sqlite3 curl jq unzip ca-certificates
  say_ok "Base environment is ready."
}

clone_or_update_repo() {
  local dest="$1"
  if [[ -d "$dest/.git" ]]; then
    say_info "Updating repository in $dest"
    git -C "$dest" fetch --all --prune >/dev/null 2>&1
    git -C "$dest" reset --hard origin/main >/dev/null 2>&1
  else
    say_info "Cloning repository into $dest"
    mkdir -p "$(dirname "$dest")"
    git clone "$REPO_URL" "$dest" >/dev/null 2>&1
  fi
}

install_monitor() {
  need_root
  local port repo
  port="$(ask "Uvicorn port" "8080")"
  repo="$(ask "Install directory for repo" "$REPO_DIR")"

  wait_port_free "$port"
  maybe_open_firewall_port "$port"
  clone_or_update_repo "$repo"

  cd "$repo"
  crlf_fix "$repo/.env" "$repo/example.env" || true
  prompt_monitor_env "$repo"

  say_info "Setting up venv and dependencies..."
  python3 -m venv .venv
  source .venv/bin/activate
  python -m pip install --upgrade pip
  pip install -r requirements.txt
  deactivate

  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Gensyn Monitor (Uvicorn)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${repo}
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=-${repo}/.env
ExecStart=${repo}/.venv/bin/uvicorn app:app --host 0.0.0.0 --port ${port}
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ${SERVICE_NAME}.service

  say_ok "Monitor is running on port ${port}"
}

update_monitor() {
  need_root
  local repo
  repo="$(ask "Repo directory" "$REPO_DIR")"
  if [[ ! -d "$repo" ]]; then
    say_err "Repo $repo not found. Install monitor first."
    return 1
  fi

  clone_or_update_repo "$repo"
  cd "$repo"
  source .venv/bin/activate
  python -m pip install --upgrade pip
  pip install -r requirements.txt
  deactivate

  systemctl restart ${SERVICE_NAME}.service
  say_ok "Monitor updated and restarted."
}

monitor_status()   { systemctl status ${SERVICE_NAME}.service; }
monitor_logs()     { journalctl -u ${SERVICE_NAME}.service -n 100 --no-pager; }

remove_monitor() {
  need_root
  systemctl disable --now ${SERVICE_NAME}.service || true
  rm -f /etc/systemd/system/${SERVICE_NAME}.service
  systemctl daemon-reload

  local default_repo delete_choice answer
  default_repo="$(current_repo_dir)"
  say_info "Current dashboard repo dir: ${default_repo}"
  read -rp "Delete that directory (${default_repo})? (y/N): " delete_choice || true
  if [[ "${delete_choice,,}" == "y" || "${delete_choice,,}" == "yes" ]]; then
    answer="$(ask "Confirm path to delete" "$default_repo")"
    if [[ -n "$answer" && -d "$answer" ]]; then
      rm -rf "$answer"
      say_ok "Removed $answer"
    else
      say_info "Directory not found or empty -> skip."
    fi
  else
    say_info "Keeping repo directory."
  fi

  say_ok "Monitor removed."
}

########################################
# Agent (install / reinstall / show / status / logs / remove)
########################################

ensure_repo_for_agent() {
  # Prefer local copy (same directory tree as this script)
  local local_agents="$REPO_ROOT/agents/linux"
  if [[ -f "$local_agents/gensyn_agent.sh" ]]; then
    echo "$local_agents"
    return 0
  fi
  # Otherwise pull fresh repo into /opt/gensyn-monitor
  if have_cmd git; then
    say_info "Local agent files not found, cloning into $REPO_DIR"
    clone_or_update_repo "$REPO_DIR"
    local_agents="$REPO_DIR/agents/linux"
    if [[ -f "$local_agents/gensyn_agent.sh" ]]; then
      echo "$local_agents"
      return 0
    fi
  fi
  echo ""
  return 1
}

install_agent_from_raw() {
  say_info "Downloading agent files from GitHub raw..."
  curl -fsSL "$RAW_BASE/agents/linux/gensyn_agent.sh"      -o "$AGENT_BIN"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-agent.service" -o "$AGENT_SERVICE"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-agent.timer"   -o "$AGENT_TIMER"
  chmod 0755 "$AGENT_BIN"
  chmod 0644 "$AGENT_SERVICE" "$AGENT_TIMER"
  crlf_fix "$AGENT_BIN" "$AGENT_SERVICE" "$AGENT_TIMER"
}

install_agent() {
  need_root

  local server secret node node_default meta eoa peers tgid dashurl admin_token
  server="$(ask "Monitor URL (ex http://host:8080)" "${DEFAULT_SERVER_URL:-}")"
  secret="$(ask "SHARED_SECRET" "${DEFAULT_SHARED_SECRET:-}")"
  node_default="${DEFAULT_NODE_ID:-$(hostname)-gensyn}"
  node="$(ask "NODE_ID" "$node_default")"
  meta="$(ask "META (freeform tag, optional)" "${DEFAULT_META:-}")"
  eoa="$(ask "GSWARM_EOA (EOA address 0x..., optional)" "${DEFAULT_GSWARM_EOA:-}")"
  peers="$(ask "GSWARM_PEER_IDS (comma-separated, optional)" "${DEFAULT_GSWARM_PEER_IDS:-}")"
  tgid="$(ask "GSWARM_TGID (Telegram ID for off-chain stats, optional)" "${DEFAULT_GSWARM_TGID:-}")"
  dashurl="$(ask "DASH_URL (optional, link to this node in dashboard)" "${DEFAULT_DASH_URL:-}")"
  admin_token="$(ask "ADMIN_TOKEN (/api/admin/delete token, optional)" "${DEFAULT_ADMIN_TOKEN:-}")"

  local agents_dir
  agents_dir="$(ensure_repo_for_agent || true)"

  if [[ -n "$agents_dir" ]]; then
    say_info "Using agent files from: $agents_dir"
    install -m0755 "$agents_dir/gensyn_agent.sh" "$AGENT_BIN"
    install -m0644 "$agents_dir/gensyn-agent.service" "$AGENT_SERVICE"
    install -m0644 "$agents_dir/gensyn-agent.timer"   "$AGENT_TIMER"
    crlf_fix "$AGENT_BIN" "$AGENT_SERVICE" "$AGENT_TIMER"
  else
    install_agent_from_raw
  fi

  {
    printf 'SERVER_URL=%s\n'        "$(shell_quote "$server")"
    printf 'SHARED_SECRET=%s\n'     "$(shell_quote "$secret")"
    printf 'NODE_ID=%s\n'           "$(shell_quote "$node")"
    printf 'META=%s\n'              "$(shell_quote "$meta")"
    printf 'GSWARM_EOA=%s\n'        "$(shell_quote "$eoa")"
    printf 'GSWARM_PEER_IDS=%s\n'   "$(shell_quote "$peers")"
    printf 'GSWARM_TGID=%s\n'       "$(shell_quote "$tgid")"
    printf 'DASH_URL=%s\n'          "$(shell_quote "$dashurl")"
    printf 'ADMIN_TOKEN=%s\n'       "$(shell_quote "$admin_token")"
    # critical: don't let gensyn_agent kill our gensyn screen session
    printf "AUTO_KILL_EMPTY_SCREEN='false'\n"
  } >"$AGENT_ENV"
  chmod 0644 "$AGENT_ENV"
  crlf_fix "$AGENT_ENV"

  systemctl daemon-reload
  systemctl enable --now "$(basename "$AGENT_TIMER")"

  say_ok "Agent enabled (timer $(basename "$AGENT_TIMER"))"
  say_info "Agent config file: $AGENT_ENV"

  if [[ -n "$server" ]]; then
    local endpoint="${server%/}/api/gswarm/check?include_nodes=true&send=false"
    say_info "Triggering initial G-Swarm collection -> $endpoint"
    if curl -fsS -X POST "$endpoint" -d '' >/dev/null 2>&1; then
      say_ok "Initial G-Swarm sync requested."
    else
      say_warn "G-Swarm API call failed or skipped."
    fi
  fi

  # make sure agent reloads env (AUTO_KILL_EMPTY_SCREEN=false)
  systemctl restart "$(basename "$AGENT_SERVICE")" || true
}

reinstall_agent() {
  need_root

  local prev_server="" prev_node="" prev_admin="" prev_secret="" prev_meta="" prev_eoa="" prev_peers="" prev_tgid="" prev_dash=""
  if [[ -f "$AGENT_ENV" ]]; then
    set +u
    source "$AGENT_ENV"
    prev_server="${SERVER_URL:-}"
    prev_node="${NODE_ID:-}"
    prev_admin="${ADMIN_TOKEN:-}"
    prev_secret="${SHARED_SECRET:-}"
    prev_meta="${META:-}"
    prev_eoa="${GSWARM_EOA:-}"
    prev_peers="${GSWARM_PEER_IDS:-}"
    prev_dash="${DASH_URL:-}"
    prev_tgid="${GSWARM_TGID:-}"
    set -u
  fi

  systemctl disable --now "$(basename "$AGENT_TIMER")" "$(basename "$AGENT_SERVICE")" || true

  export DEFAULT_SERVER_URL="${prev_server}"
  export DEFAULT_SHARED_SECRET="${prev_secret}"
  export DEFAULT_NODE_ID="${prev_node}"
  export DEFAULT_META="${prev_meta}"
  export DEFAULT_GSWARM_EOA="${prev_eoa}"
  export DEFAULT_GSWARM_PEER_IDS="${prev_peers}"
  export DEFAULT_GSWARM_TGID="${prev_tgid}"
  export DEFAULT_DASH_URL="${prev_dash}"
  export DEFAULT_ADMIN_TOKEN="${prev_admin}"

  install_agent

  unset DEFAULT_SERVER_URL DEFAULT_SHARED_SECRET DEFAULT_NODE_ID DEFAULT_META \
        DEFAULT_GSWARM_EOA DEFAULT_GSWARM_PEER_IDS DEFAULT_GSWARM_TGID \
        DEFAULT_DASH_URL DEFAULT_ADMIN_TOKEN

  local new_node="" new_server=""
  if [[ -f "$AGENT_ENV" ]]; then
    set +u
    source "$AGENT_ENV"
    new_node="${NODE_ID:-}"
    new_server="${SERVER_URL:-}"
    set -u
  fi

  # cleanup old node_id from dashboard if changed
  if [[ -n "$prev_server" && -n "$prev_admin" && -n "$prev_node" && "$prev_node" != "$new_node" ]]; then
    local endpoint="${prev_server%/}/api/admin/delete"
    local payload
    payload=$(json_string "$prev_node")
    if curl -fsS -X POST "$endpoint" \
         -H "Authorization: Bearer ${prev_admin}" \
         -H "Content-Type: application/json" \
         -d "{\"node_id\":${payload}}" >/dev/null 2>&1; then
      say_ok "Old node_id ${prev_node} removed from monitor."
    else
      say_warn "Failed to remove old node_id ${prev_node} from monitor."
    fi
  fi
}

show_agent_env() {
  if [[ -f "$AGENT_ENV" ]]; then
    echo "== $AGENT_ENV =="
    cat "$AGENT_ENV"
  else
    say_warn "$AGENT_ENV not found."
  fi
}

agent_status() {
  systemctl status "$(basename "$AGENT_TIMER")" "$(basename "$AGENT_SERVICE")"
}

agent_logs() {
  journalctl -u "$(basename "$AGENT_SERVICE")" -n 100 --no-pager
}

remove_agent() {
  need_root
  local server_env="" node_env="" admin_env=""
  if [[ -f "$AGENT_ENV" ]]; then
    set +u
    source "$AGENT_ENV"
    server_env="${SERVER_URL:-}"
    node_env="${NODE_ID:-}"
    admin_env="${ADMIN_TOKEN:-}"
    set -u
  fi

  systemctl disable --now "$(basename "$AGENT_TIMER")" "$(basename "$AGENT_SERVICE")" || true
  rm -f "$AGENT_TIMER" "$AGENT_SERVICE"
  rm -f "$AGENT_BIN" "$AGENT_ENV"
  systemctl daemon-reload

  # optional cleanup on monitor side
  if [[ -n "$server_env" && -n "$node_env" && -n "$admin_env" ]]; then
    local endpoint="${server_env%/}/api/admin/delete"
    say_info "Removing node from monitor -> $endpoint"
    if curl -fsS -X POST "$endpoint" \
         -H "Authorization: Bearer ${admin_env}" \
         -H "Content-Type: application/json" \
         -d "{\"node_id\":\"${node_env}\"}" >/dev/null 2>&1; then
      say_ok "Node ${node_env} removed from monitor."
    else
      say_warn "Could not call /api/admin/delete (skipped)."
    fi
  fi

  say_ok "Agent removed."
}

########################################
# Autorestart (watchdog + launcher)
########################################

install_autorestart() {
  need_root
  say_info "Installing autorestart (watchdog + launcher)..."

  # pull watchdog + launcher from repo raw
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.sh"              -o "$WATCHDOG_BIN"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.service"         -o "$WATCHDOG_SERVICE"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.timer"           -o "$WATCHDOG_TIMER"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-screen-launcher.sh"       -o "$LAUNCHER_BIN"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-screen-launcher.service"  -o "$LAUNCHER_SERVICE"

  chmod 0755 "$WATCHDOG_BIN" "$LAUNCHER_BIN"
  chmod 0644 "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$LAUNCHER_SERVICE"

  crlf_fix "$WATCHDOG_BIN" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$LAUNCHER_BIN" "$LAUNCHER_SERVICE"

  # ensure swarm log file exists
  if [[ ! -f "$SWARM_LOG" ]]; then
    touch "$SWARM_LOG"
    chmod 0644 "$SWARM_LOG"
  fi

  # make sure agent won't kill screen 'gensyn'
  if [[ -f "$AGENT_ENV" ]]; then
    if ! grep -q '^AUTO_KILL_EMPTY_SCREEN=' "$AGENT_ENV" 2>/dev/null; then
      echo "AUTO_KILL_EMPTY_SCREEN='false'" >> "$AGENT_ENV"
    else
      sed -i 's/^AUTO_KILL_EMPTY_SCREEN=.*/AUTO_KILL_EMPTY_SCREEN='"'"'false'"'"'/' "$AGENT_ENV"
    fi
  else
    {
      echo "AUTO_KILL_EMPTY_SCREEN='false'"
    } > "$AGENT_ENV"
    chmod 0644 "$AGENT_ENV"
  fi

  systemctl daemon-reload

  # restart agent to re-read env and stop killing the gensyn screen
  systemctl restart "$(basename "$AGENT_SERVICE")" || true

  # launcher: keeps/starts screen session "gensyn" and launches rl-swarm inside it
  systemctl enable --now "$(basename "$LAUNCHER_SERVICE")"

  # watchdog timer: checks heartbeat status=DOWN and restarts launcher if needed
  systemctl enable --now "$(basename "$WATCHDOG_TIMER")"

  say_ok "Autorestart installed."
  say_info "Screen session name: gensyn"
  say_info "Check sessions: screen -ls / attach: screen -r gensyn"
}

watchdog_logs() {
  need_root
  echo
  echo "=== live watchdog logs (Ctrl+C to exit) ==="
  echo
  journalctl -u "$(basename "$WATCHDOG_SERVICE")" -f --no-pager || true

  echo
  echo "=== tail of $SWARM_LOG (rl-swarm output inside screen gensyn) ==="
  tail -n 100 "$SWARM_LOG" 2>/dev/null || echo "[i] swarm log empty or missing"
  echo
}

remove_autorestart() {
  need_root
  say_info "Removing autorestart (watchdog + launcher)..."

  # stop/disable services
  systemctl disable --now "$(basename "$WATCHDOG_TIMER")" 2>/dev/null || true
  systemctl disable --now "$(basename "$WATCHDOG_SERVICE")" 2>/dev/null || true
  systemctl disable --now "$(basename "$LAUNCHER_SERVICE")" 2>/dev/null || true

  # kill screen session gensyn
  screen -S gensyn -X quit || true

  # delete files
  rm -f "$WATCHDOG_TIMER" "$WATCHDOG_SERVICE" "$WATCHDOG_BIN"
  rm -f "$LAUNCHER_SERVICE" "$LAUNCHER_BIN"

  systemctl daemon-reload

  say_ok "Autorestart removed."
  say_info "Log $SWARM_LOG kept for debugging (remove manually if you want)."
}

########################################
# Menu / Main
########################################

menu() {
  cat <<EOF

${BOLD}=== Gensyn Manager Menu ===${RESET}

[ Machine / Monitor ]
  1) Prepare machine (deps)
  2) Install dashboard monitor
  3) Update dashboard monitor
  4) Monitor status
  5) Monitor logs
  6) Remove dashboard monitor

[ Agent (heartbeat sender) ]
  7)  Install agent
  8)  Reinstall agent (stop+install)
  9)  Show agent config
  10) Agent status
  11) Agent logs
  12) Remove agent

[ Autorestart / watchdog ]
  13) Install autorestart (watchdog + launcher)
  14) Watchdog logs (live + swarm tail)
  15) Remove autorestart

  0) Exit

EOF
}

main() {
  display_logo
  while true; do
    menu
    read -rp "Choose option: " choice || true
    case "${choice:-}" in
      1)  prepare_device ;;
      2)  install_monitor ;;
      3)  update_monitor ;;
      4)  monitor_status ;;
      5)  monitor_logs ;;
      6)  remove_monitor ;;
      7)  install_agent ;;
      8)  reinstall_agent ;;
      9)  show_agent_env ;;
      10) agent_status ;;
      11) agent_logs ;;
      12) remove_agent ;;
      13) install_autorestart ;;
      14) watchdog_logs ;;
      15) remove_autorestart ;;
      0)  exit 0 ;;
      *)  say_warn "Unknown option" ;;
    esac
  done
}

main "$@"
