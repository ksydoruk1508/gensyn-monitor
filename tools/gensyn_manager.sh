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

########################################
# Global language (will be set in choose_lang)
########################################
LANG_MODE="RU"   # default RU, we'll ask on start

########################################
# Paths / constants
########################################

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# IMPORTANT:
# Must point to your repo
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
# i18n helpers
########################################

t_banner() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    cat <<'EOF'
 _   _           _  _____
| \ | |         | ||____ |
|  \| | ___   __| |    / /_ __
| . ` |/ _ \ / _` |    \ \ '__|
| |\  | (_) | (_| |.___/ / |
\_| \_/\___/ \__,_|\____/|_|

     Gensyn Manager
   @NodesN3R / autosync
EOF
  else
    cat <<'EOF'
 _   _           _  _____
| \ | |         | ||____ |
|  \| | ___   __| |    / /_ __
| . ` |/ _ \ / _` |    \ \ '__|
| |\  | (_) | (_| |.___/ / |
\_| \_/\___/ \__,_|\____/|_|

     Gensyn Manager
   @NodesN3R / автоподдержка
EOF
  fi
}

t_choose_lang_prompt() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Language is set to EN."
  else
    echo "Текущий язык RU. Хочешь переключиться на EN? (y/N): "
  fi
}

# log wrappers with color
say_info() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    printf "${BLUE}[i]${RESET} %s\n" "$*"
  else
    printf "${BLUE}[i]${RESET} %s\n" "$*"  # текст уже переведём в момент вызова
  fi
}
say_ok() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    printf "${GREEN}[+]${RESET} %s\n" "$*"
  else
    printf "${GREEN}[+]${RESET} %s\n" "$*"
  fi
}
say_warn() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    printf "${YELLOW}[!]${RESET} %s\n" "$*"
  else
    printf "${YELLOW}[!]${RESET} %s\n" "$*"
  fi
}
say_err() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    printf "${RED}[x]${RESET} %s\n" "$*" >&2
  else
    printf "${RED}[x]${RESET} %s\n" "$*" >&2
  fi
}

# short translated strings we reuse
msg_need_root() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Run as root (sudo $0)"
  else
    echo "Запусти от root (sudo $0)"
  fi
}
msg_port_in_use() {
  local port="$1"
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Port $port is already in use. Pick another port or stop that process."
  else
    echo "Порт $port уже занят. Освободи порт или выбери другой."
  fi
}
msg_firewall_question() {
  local port="$1"
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo -n "Open ${port}/tcp in firewall? (y/N): "
  else
    echo -n "Открыть порт ${port}/tcp во внешнем firewall? (y/N): "
  fi
}
msg_invalid_number() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Must be a number."
  else
    echo "Нужно число."
  fi
}
msg_json_hint() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "GSWARM_NODE_MAP must be valid JSON or empty. Example:"
  else
    echo "GSWARM_NODE_MAP должен быть валидным JSON или пустым. Пример:"
  fi
}
msg_json_bad() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Invalid JSON. Using empty."
  else
    echo "JSON некорректный. Оставляю пусто."
  fi
}
msg_repo_not_found() {
  local repo="$1"
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Repo $repo not found. Install monitor first."
  else
    echo "Каталог $repo не найден. Сначала поставь монитор."
  fi
}
msg_monitor_running() {
  local port="$1"
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Monitor is running on port $port"
  else
    echo "Мониторинг запущен на порту $port"
  fi
}
msg_monitor_removed() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Monitor removed."
  else
    echo "Мониторинг удалён."
  fi
}
msg_keep_repo_question() {
  local path="$1"
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Delete repo directory ($path)? (y/N): "
  else
    echo "Удалить директорию репозитория ($path)? (y/N): "
  fi
}
msg_repo_kept() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Keeping repo directory."
  else
    echo "Каталог оставлен."
  fi
}
msg_agent_enabled() {
  local timer="$1"
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Agent enabled (timer $timer)"
  else
    echo "Агент включён (таймер $timer)"
  fi
}
msg_swarm_tail_head() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "=== tail of swarm log (rl-swarm inside screen gensyn) ==="
  else
    echo "=== хвост лога роя (rl-swarm внутри screen gensyn) ==="
  fi
}
msg_watchdog_live() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "=== live watchdog logs (Ctrl+C to exit) ==="
  else
    echo "=== живые логи watchdog (Ctrl+C чтобы выйти) ==="
  fi
}
msg_autorestart_installed() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Autorestart installed."
  else
    echo "Авторестарт установлен."
  fi
}
msg_autorestart_removed() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Autorestart removed."
  else
    echo "Авторестарт удалён."
  fi
}

t_menu() {
  if [[ "$LANG_MODE" == "EN" ]]; then
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
  else
    cat <<EOF

${BOLD}=== Меню Gensyn Manager ===${RESET}

[ Сервер / Мониторинг ]
  1) Подготовить сервер (зависимости)
  2) Установить мониторинг (дашборд)
  3) Обновить мониторинг
  4) Статус мониторинга
  5) Логи мониторинга
  6) Удалить мониторинг

[ Агент (heartbeat sender) ]
  7)  Установить агента
  8)  Переустановить агента (остановить+установить)
  9)  Показать конфиг агента
  10) Статус агента
  11) Логи агента
  12) Удалить агента

[ Авторестарт / watchdog ]
  13) Установить авторестарт (watchdog + launcher)
  14) Логи авторестарта (онлайн + хвост роя)
  15) Удалить авторестарт

  0) Выход

EOF
  fi
}

t_choose_option() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo -n "Choose option: "
  else
    echo -n "Выбери пункт: "
  fi
}

t_firewalld_inactive() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "ufw is installed but inactive -> rule not added."
  else
    echo "ufw установлен, но выключен. Правило не добавлено."
  fi
}

t_skipping_firewall() {
  if [[ "$LANG_MODE" == "EN" ]]; then
    echo "Skipping firewall config."
  else
    echo "Файрвол пропускаем."
  fi
}

########################################
# Basic helpers (root, shell tools, etc.)
########################################

need_root() {
  if [[ $EUID -ne 0 ]]; then
    say_err "$(msg_need_root)"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

current_repo_dir() {
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
    say_err "$(msg_port_in_use "$port")"
    ss -ltnp | grep ":$port" || true
    exit 1
  fi
}

maybe_open_firewall_port() {
  local port="$1"
  read -rp "$(msg_firewall_question "$port")" answer || true
  case "${answer,,}" in
    y|yes)
      if have_cmd ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -n1 || true)
        if [[ "$ufw_status" =~ inactive ]]; then
          say_info "$(t_firewalld_inactive)"
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
    *) say_info "$(t_skipping_firewall)" ;;
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
# Monitor: env prompt / install / update / status / logs / remove
########################################

prompt_monitor_env() {
  local repo="$1" env_file="$repo/.env"

  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Configuring .env for dashboard monitor"
  else
    say_info "Настраиваем .env для дашборда мониторинга"
  fi

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
    if [[ "$LANG_MODE" == "EN" ]]; then
      say_info "$env_file exists: empty answers will keep current values."
    else
      say_info "Нашёл $env_file. Пустой ответ оставит текущее значение."
    fi
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

  if [[ "$LANG_MODE" == "EN" ]]; then
    TE_BOT="$(ask "TELEGRAM_BOT_TOKEN" "$_bot")"
    TE_CHAT="$(ask "TELEGRAM_CHAT_ID" "$_chat")"
    SHARED="$(ask "SHARED_SECRET" "$_shared")"
    ADMIN="$(ask "ADMIN_TOKEN (optional)" "$_admin")"
    TITLE="$(ask "SITE_TITLE" "$_title")"

    THR="$(ask "DOWN_THRESHOLD_SEC (seconds)" "$_thr")"
  else
    TE_BOT="$(ask "TELEGRAM_BOT_TOKEN" "$_bot")"
    TE_CHAT="$(ask "TELEGRAM_CHAT_ID" "$_chat")"
    SHARED="$(ask "SHARED_SECRET" "$_shared")"
    ADMIN="$(ask "ADMIN_TOKEN (опционально)" "$_admin")"
    TITLE="$(ask "SITE_TITLE" "$_title")"

    THR="$(ask "DOWN_THRESHOLD_SEC (в секундах)" "$_thr")"
  fi

  while [[ -n "$THR" ]] && ! is_number "$THR"; do
    say_warn "$(msg_invalid_number)"
    if [[ "$LANG_MODE" == "EN" ]]; then
      THR="$(ask "DOWN_THRESHOLD_SEC (seconds)" "$_thr")"
    else
      THR="$(ask "DOWN_THRESHOLD_SEC (в секундах)" "$_thr")"
    fi
  done

  if [[ "$LANG_MODE" == "EN" ]]; then
    INTV="$(ask "GSWARM_REFRESH_INTERVAL (seconds)" "$_interval")"
  else
    INTV="$(ask "GSWARM_REFRESH_INTERVAL (секунды)" "$_interval")"
  fi

  while [[ -n "$INTV" ]] && ! is_number "$INTV"; do
    say_warn "$(msg_invalid_number)"
    if [[ "$LANG_MODE" == "EN" ]]; then
      INTV="$(ask "GSWARM_REFRESH_INTERVAL (seconds)" "$_interval")"
    else
      INTV="$(ask "GSWARM_REFRESH_INTERVAL (секунды)" "$_interval")"
    fi
  done

  if [[ "$LANG_MODE" == "EN" ]]; then
    SHOW_SRC="$(ask "GSWARM_SHOW_SRC (auto/always/never)" "$_show_src")"
  else
    SHOW_SRC="$(ask "GSWARM_SHOW_SRC (auto/always/never)" "$_show_src")"
  fi

  case "${SHOW_SRC,,}" in
    always|never|auto) SHOW_SRC="${SHOW_SRC,,}" ;;
    *) SHOW_SRC="auto" ;;
  esac

  if [[ "$LANG_MODE" == "EN" ]]; then
    AUTOSEND="$(ask "GSWARM_AUTO_SEND (0/1)" "$_autosend")"
  else
    AUTOSEND="$(ask "GSWARM_AUTO_SEND (0/1)" "$_autosend")"
  fi
  [[ "$AUTOSEND" != "1" ]] && AUTOSEND="0"

  echo
  msg_json_hint
  echo '  {"node-1":{"eoa":"0x...","peer_ids":["Qm.."],"tgid":"123456"}}'

  if [[ "$LANG_MODE" == "EN" ]]; then
    NODEMAP_INPUT="$(ask "GSWARM_NODE_MAP (JSON or empty)" "$_nodemap")"
  else
    NODEMAP_INPUT="$(ask "GSWARM_NODE_MAP (JSON или пусто)" "$_nodemap")"
  fi

  if [[ -n "$NODEMAP_INPUT" ]] && ! json_validate "$NODEMAP_INPUT"; then
    say_warn "$(msg_json_bad)"
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
    write_kv "DB_PATH" "${repo}/monitor.db"
  } >"$tmp"
  mv -f "$tmp" "$env_file"

  if [[ "$LANG_MODE" == "EN" ]]; then
    say_ok ".env updated: $env_file"
  else
    say_ok ".env обновлён: $env_file"
  fi
}

prepare_device() {
  need_root
  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Installing base dependencies..."
  else
    say_info "Ставим базовые зависимости..."
  fi
  apt-get update
  apt-get install -y python3 python3-venv python3-pip git sqlite3 curl jq unzip ca-certificates
  if [[ "$LANG_MODE" == "EN" ]]; then
    say_ok "Base environment is ready."
  else
    say_ok "Готово."
  fi
}

clone_or_update_repo() {
  local dest="$1"
  if [[ -d "$dest/.git" ]]; then
    say_info "Updating repo in $dest"
    git -C "$dest" fetch --all --prune >/dev/null 2>&1
    git -C "$dest" reset --hard origin/main >/dev/null 2>&1
  else
    say_info "Cloning repo into $dest"
    mkdir -p "$(dirname "$dest")"
    git clone "$REPO_URL" "$dest" >/dev/null 2>&1
  fi
}

install_monitor() {
  need_root
  local port repo

  if [[ "$LANG_MODE" == "EN" ]]; then
    port="$(ask "Uvicorn port" "8080")"
    repo="$(ask "Install directory for repo" "$REPO_DIR")"
  else
    port="$(ask "Порт uvicorn" "8080")"
    repo="$(ask "Куда ставим репозиторий" "$REPO_DIR")"
  fi

  wait_port_free "$port"
  maybe_open_firewall_port "$port"
  clone_or_update_repo "$repo"

  cd "$repo"
  crlf_fix "$repo/.env" "$repo/example.env" || true
  prompt_monitor_env "$repo"

  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Setting up venv and dependencies..."
  else
    say_info "Готовлю venv и зависимости..."
  fi

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

  say_ok "$(msg_monitor_running "$port")"
}

update_monitor() {
  need_root
  local repo
  if [[ "$LANG_MODE" == "EN" ]]; then
    repo="$(ask "Repo directory" "$REPO_DIR")"
  else
    repo="$(ask "Каталог репозитория" "$REPO_DIR")"
  fi

  if [[ ! -d "$repo" ]]; then
    say_err "$(msg_repo_not_found "$repo")"
    return 1
  fi

  clone_or_update_repo "$repo"
  cd "$repo"
  source .venv/bin/activate
  python -m pip install --upgrade pip
  pip install -r requirements.txt
  deactivate

  systemctl restart ${SERVICE_NAME}.service
  if [[ "$LANG_MODE" == "EN" ]]; then
    say_ok "Monitor updated and restarted."
  else
    say_ok "Монитор обновлён и перезапущен."
  fi
}

monitor_status() {
  systemctl status ${SERVICE_NAME}.service
}
monitor_logs() {
  journalctl -u ${SERVICE_NAME}.service -n 100 --no-pager
}

remove_monitor() {
  need_root
  systemctl disable --now ${SERVICE_NAME}.service || true
  rm -f /etc/systemd/system/${SERVICE_NAME}.service
  systemctl daemon-reload

  local default_repo delete_choice answer
  default_repo="$(current_repo_dir)"

  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Current dashboard repo dir: ${default_repo}"
    read -rp "$(msg_keep_repo_question "$default_repo")" delete_choice || true
  else
    say_info "Текущая папка дашборда: ${default_repo}"
    read -rp "$(msg_keep_repo_question "$default_repo")" delete_choice || true
  fi

  if [[ "${delete_choice,,}" == "y" || "${delete_choice,,}" == "yes" ]]; then
    if [[ "$LANG_MODE" == "EN" ]]; then
      answer="$(ask "Confirm path to delete" "$default_repo")"
    else
      answer="$(ask "Подтверди путь для удаления" "$default_repo")"
    fi
    if [[ -n "$answer" && -d "$answer" ]]; then
      rm -rf "$answer"
      say_ok "Removed $answer"
    else
      if [[ "$LANG_MODE" == "EN" ]]; then
        say_info "Directory not found or empty -> skip."
      else
        say_info "Каталог не найден или не указан. Пропустил."
      fi
    fi
  else
    say_info "$(msg_repo_kept)"
  fi

  say_ok "$(msg_monitor_removed)"
}

########################################
# Agent: install / reinstall / show / status / logs / remove
########################################

ensure_repo_for_agent() {
  local local_agents="$REPO_ROOT/agents/linux"
  if [[ -f "$local_agents/gensyn_agent.sh" ]]; then
    echo "$local_agents"
    return 0
  fi
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

  if [[ "$LANG_MODE" == "EN" ]]; then
    server="$(ask "Monitor URL (ex http://host:8080)" "${DEFAULT_SERVER_URL:-}")"
    secret="$(ask "SHARED_SECRET" "${DEFAULT_SHARED_SECRET:-}")"
    node_default="${DEFAULT_NODE_ID:-$(hostname)-gensyn}"
    node="$(ask "NODE_ID" "$node_default")"
    meta="$(ask "META (freeform tag, optional)" "${DEFAULT_META:-}")"
    eoa="$(ask "GSWARM_EOA (EOA address 0x..., optional)" "${DEFAULT_GSWARM_EOA:-}")"
    peers="$(ask "GSWARM_PEER_IDS (comma-separated, optional)" "${DEFAULT_GSWARM_PEER_IDS:-}")"
    tgid="$(ask "GSWARM_TGID (Telegram ID, optional)" "${DEFAULT_GSWARM_TGID:-}")"
    dashurl="$(ask "DASH_URL (link to this node in dashboard, optional)" "${DEFAULT_DASH_URL:-}")"
    admin_token="$(ask "ADMIN_TOKEN (/api/admin/delete token, optional)" "${DEFAULT_ADMIN_TOKEN:-}")"
  else
    server="$(ask "URL мониторинга (например http://host:8080)" "${DEFAULT_SERVER_URL:-}")"
    secret="$(ask "SHARED_SECRET" "${DEFAULT_SHARED_SECRET:-}")"
    node_default="${DEFAULT_NODE_ID:-$(hostname)-gensyn}"
    node="$(ask "NODE_ID" "$node_default")"
    meta="$(ask "META (любая подпись узла, можно пусто)" "${DEFAULT_META:-}")"
    eoa="$(ask "GSWARM_EOA (адрес 0x..., опционально)" "${DEFAULT_GSWARM_EOA:-}")"
    peers="$(ask "GSWARM_PEER_IDS (через запятую, опционально)" "${DEFAULT_GSWARM_PEER_IDS:-}")"
    tgid="$(ask "GSWARM_TGID (Telegram ID для off-chain, опц.)" "${DEFAULT_GSWARM_TGID:-}")"
    dashurl="$(ask "DASH_URL (ссылка на ноду в дашборде, опц.)" "${DEFAULT_DASH_URL:-}")"
    admin_token="$(ask "ADMIN_TOKEN (для /api/admin/delete, опц.)" "${DEFAULT_ADMIN_TOKEN:-}")"
  fi

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
    printf "AUTO_KILL_EMPTY_SCREEN='false'\n"
  } >"$AGENT_ENV"
  chmod 0644 "$AGENT_ENV"
  crlf_fix "$AGENT_ENV"

  systemctl daemon-reload
  systemctl enable --now "$(basename "$AGENT_TIMER")"

  say_ok "$(msg_agent_enabled "$(basename "$AGENT_TIMER")")"

  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Agent config: $AGENT_ENV"
  else
    say_info "Конфиг агента: $AGENT_ENV"
  fi

  if [[ -n "$server" ]]; then
    local endpoint="${server%/}/api/gswarm/check?include_nodes=true&send=false"
    if [[ "$LANG_MODE" == "EN" ]]; then
      say_info "Triggering initial G-Swarm collection -> $endpoint"
    else
      say_info "Дёргаю начальный сбор G-Swarm -> $endpoint"
    fi
    if curl -fsS -X POST "$endpoint" -d '' >/dev/null 2>&1; then
      if [[ "$LANG_MODE" == "EN" ]]; then
        say_ok "Initial G-Swarm sync requested."
      else
        say_ok "Запросил первичный сбор G-Swarm."
      fi
    else
      if [[ "$LANG_MODE" == "EN" ]]; then
        say_warn "G-Swarm API call failed or skipped."
      else
        say_warn "Не получилось дернуть G-Swarm API, пропускаю."
      fi
    fi
  fi

  # reload agent service so it reads AUTO_KILL_EMPTY_SCREEN=false
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

  if [[ -n "$prev_server" && -n "$prev_admin" && -n "$prev_node" && "$prev_node" != "$new_node" ]]; then
    local endpoint="${prev_server%/}/api/admin/delete"
    local payload
    payload=$(json_string "$prev_node")
    if curl -fsS -X POST "$endpoint" \
         -H "Authorization: Bearer ${prev_admin}" \
         -H "Content-Type: application/json" \
         -d "{\"node_id\":${payload}}" >/dev/null 2>&1; then
      if [[ "$LANG_MODE" == "EN" ]]; then
        say_ok "Old node_id ${prev_node} removed from monitor."
      else
        say_ok "Старый node_id ${prev_node} выпилен из монитора."
      fi
    else
      if [[ "$LANG_MODE" == "EN" ]]; then
        say_warn "Failed to remove old node_id ${prev_node} from monitor."
      else
        say_warn "Не смог убрать старый node_id ${prev_node} с монитора."
      fi
    fi
  fi
}

show_agent_env() {
  if [[ -f "$AGENT_ENV" ]]; then
    echo "== $AGENT_ENV =="
    cat "$AGENT_ENV"
  else
    if [[ "$LANG_MODE" == "EN" ]]; then
      say_warn "$AGENT_ENV not found."
    else
      say_warn "Файл $AGENT_ENV не найден."
    fi
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

  if [[ -n "$server_env" && -n "$node_env" && -n "$admin_env" ]]; then
    local endpoint="${server_env%/}/api/admin/delete"
    if [[ "$LANG_MODE" == "EN" ]]; then
      say_info "Removing node from monitor -> $endpoint"
    else
      say_info "Удаляю ноду из монитора -> $endpoint"
    fi
    if curl -fsS -X POST "$endpoint" \
         -H "Authorization: Bearer ${admin_env}" \
         -H "Content-Type: application/json" \
         -d "{\"node_id\":\"${node_env}\"}" >/dev/null 2>&1; then
      if [[ "$LANG_MODE" == "EN" ]]; then
        say_ok "Node ${node_env} removed from monitor."
      else
        say_ok "Нода ${node_env} удалена с дашборда."
      fi
    else
      if [[ "$LANG_MODE" == "EN" ]]; then
        say_warn "Could not call /api/admin/delete (skipped)."
      else
        say_warn "Не получилось вызвать /api/admin/delete, пропущено."
      fi
    fi
  fi

  if [[ "$LANG_MODE" == "EN" ]]; then
    say_ok "Agent removed."
  else
    say_ok "Агент удалён."
  fi
}

########################################
# Autorestart (watchdog + launcher)
########################################

install_autorestart() {
  need_root

  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Installing autorestart (watchdog + launcher)..."
  else
    say_info "Ставлю авторестарт (watchdog + launcher)..."
  fi

  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.sh"              -o "$WATCHDOG_BIN"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.service"         -o "$WATCHDOG_SERVICE"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.timer"           -o "$WATCHDOG_TIMER"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-screen-launcher.sh"       -o "$LAUNCHER_BIN"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-screen-launcher.service"  -o "$LAUNCHER_SERVICE"

  chmod 0755 "$WATCHDOG_BIN" "$LAUNCHER_BIN"
  chmod 0644 "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$LAUNCHER_SERVICE"

  crlf_fix "$WATCHDOG_BIN" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$LAUNCHER_BIN" "$LAUNCHER_SERVICE"

  if [[ ! -f "$SWARM_LOG" ]]; then
    touch "$SWARM_LOG"
    chmod 0644 "$SWARM_LOG"
  fi

  # make sure agent won't kill screen "gensyn"
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

  systemctl restart "$(basename "$AGENT_SERVICE")" || true
  systemctl enable --now "$(basename "$LAUNCHER_SERVICE")"
  systemctl enable --now "$(basename "$WATCHDOG_TIMER")"

  say_ok "$(msg_autorestart_installed)"
  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Screen session name: gensyn (check: screen -ls / attach: screen -r gensyn)"
  else
    say_info "screen-сессия будет называться gensyn (проверка: screen -ls / заход: screen -r gensyn)"
  fi
}

watchdog_logs() {
  need_root
  echo
  msg_watchdog_live
  echo
  journalctl -u "$(basename "$WATCHDOG_SERVICE")" -f --no-pager || true

  echo
  msg_swarm_tail_head
  tail -n 100 "$SWARM_LOG" 2>/dev/null || {
    if [[ "$LANG_MODE" == "EN" ]]; then
      echo "[i] swarm log empty or missing"
    else
      echo "[i] лог роя пустой или ещё не создан"
    fi
  }
  echo
}

remove_autorestart() {
  need_root

  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Removing autorestart (watchdog + launcher)..."
  else
    say_info "Убираю авторестарт (watchdog + launcher)..."
  fi

  systemctl disable --now "$(basename "$WATCHDOG_TIMER")" 2>/dev/null || true
  systemctl disable --now "$(basename "$WATCHDOG_SERVICE")" 2>/dev/null || true
  systemctl disable --now "$(basename "$LAUNCHER_SERVICE")" 2>/dev/null || true

  screen -S gensyn -X quit || true

  rm -f "$WATCHDOG_TIMER" "$WATCHDOG_SERVICE" "$WATCHDOG_BIN"
  rm -f "$LAUNCHER_SERVICE" "$LAUNCHER_BIN"

  systemctl daemon-reload

  say_ok "$(msg_autorestart_removed)"
  if [[ "$LANG_MODE" == "EN" ]]; then
    say_info "Swarm log left at $SWARM_LOG (remove manually if you want)."
  else
    say_info "Лог роя оставил: $SWARM_LOG. Сам решай, удалять или нет."
  fi
}

########################################
# Language switch
########################################

choose_lang() {
  # default RU, offer to switch to EN
  echo
  echo "--------------------------------"
  echo "RU / EN?"
  echo "По умолчанию всё будет на русском."
  echo "If you want English prompts, type: en"
  echo "--------------------------------"
  read -rp "> " lang || true

  case "${lang,,}" in
    en|eng|english)
      LANG_MODE="EN"
      ;;
    *)
      LANG_MODE="RU"
      ;;
  esac
}

########################################
# Menu / Main
########################################

main_menu_loop() {
  while true; do
    t_menu
    t_choose_option
    read choice || true
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
      *)
        if [[ "$LANG_MODE" == "EN" ]]; then
          say_warn "Unknown option"
        else
          say_warn "Неизвестный пункт"
        fi
        ;;
    esac
  done
}

main() {
  t_banner
  choose_lang
  main_menu_loop
}

main "$@"
