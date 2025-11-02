#!/usr/bin/env bash
# ============================================================================
# Gensyn Manager — monitor / agent / autorestart (RU/EN)
# Repo:  https://github.com/ksydoruk1508/gensyn-monitor
# Target: Ubuntu/Debian (нужен root/sudo)
# Version: 1.0.0
# ============================================================================
set -Eeuo pipefail

# -----------------------------
# Colors / UI
# -----------------------------
cG=$'\033[0;32m'; cC=$'\033[0;36m'; cB=$'\033[0;34m'; cR=$'\033[0;31m'
cY=$'\033[1;33m'; cM=$'\033[1;35m'; c0=$'\033[0m'; cBold=$'\033[1m'; cDim=$'\033[2m'

ok()   { echo -e "${cG}[OK]${c0} ${*}"; }
info() { echo -e "${cC}[INFO]${c0} ${*}"; }
warn() { echo -e "${cY}[WARN]${c0} ${*}"; }
err()  { echo -e "${cR}[ERR]${c0} ${*}"; }
hr()   { echo -e "${cDim}────────────────────────────────────────────────────────${c0}"; }

logo(){ cat <<'EOF'
 _   _           _  _____
| \ | |         | ||____ |
|  \| | ___   __| |    / /_ __
| . ` |/ _ \ / _` |    \ \ '__|
| |\  | (_) | (_| |.___/ / |
\_| \_/\___/ \__,_|\____/|_|

        Gensyn Manager
    https://t.me/NodesN3R
EOF
}

SCRIPT_VERSION="1.0.2"

# -----------------------------
# Paths / Constants
# -----------------------------
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# важно: репозиторий и RAW должны быть из твоего гита
REPO_URL="https://github.com/ksydoruk1508/gensyn-monitor.git"
REPO_DIR="/opt/gensyn-monitor"
RAW_BASE="https://raw.githubusercontent.com/ksydoruk1508/gensyn-monitor/main"

SERVICE_NAME="gensyn-monitor"

# агент (heartbeat sender)
AGENT_BIN="/usr/local/bin/gensyn_agent.sh"
AGENT_ENV="/etc/gensyn-agent.env"
AGENT_SERVICE="/etc/systemd/system/gensyn-agent.service"
AGENT_TIMER="/etc/systemd/system/gensyn-agent.timer"

# авторестарт роя (watchdog + screen launcher)
WATCHDOG_BIN="/usr/local/bin/gensyn-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/gensyn-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/gensyn-watchdog.timer"

LAUNCHER_BIN="/usr/local/bin/gensyn-screen-launcher.sh"
LAUNCHER_SERVICE="/etc/systemd/system/gensyn-screen-launcher.service"

# лог работы роя внутри screen gensyn
SWARM_LOG="/var/log/gensyn-swarm.log"

# -----------------------------
# Language (RU/EN)
# -----------------------------
LANG="ru"

choose_lang(){
  clear; logo
  echo -e "\n${cBold}${cM}Select language / Выберите язык${c0}"
  echo "1) Русский"
  echo "2) English"
  read -rp "> " a
  case "${a:-}" in
    2) LANG="en" ;;
    *) LANG="ru" ;;
  esac
}

tr(){
  local k="${1:-}"; [[ -z "$k" ]] && return 0
  if [[ "$LANG" == "en" ]]; then
    case "$k" in
      need_root)          echo "Run as root (sudo) — some actions will fail otherwise.";;

      deps_begin)         echo "Installing base deps (python3, curl, jq, etc.)...";;
      deps_done)          echo "Base deps installed.";;

      ask_uvicorn_port)   echo "Uvicorn port for dashboard:";;
      ask_repo_dir)       echo "Install directory for repo:";;
      venv_setup)         echo "Setting up venv and Python deps...";;
      monitor_ok)         echo "Monitor is running on port";;
      monitor_upd_done)   echo "Monitor updated and restarted.";;

      env_intro)          echo "Configuring .env for dashboard monitor";;
      env_found)          echo ".env exists, empty answer keeps old value.";;

      ask_bot)            echo "TELEGRAM_BOT_TOKEN";;
      ask_chat)           echo "TELEGRAM_CHAT_ID";;
      ask_shared)         echo "SHARED_SECRET";;
      ask_admin)          echo "ADMIN_TOKEN (optional)";;
      ask_title)          echo "SITE_TITLE";;
      ask_thr)            echo "DOWN_THRESHOLD_SEC (seconds)";;
      ask_intv)           echo "GSWARM_REFRESH_INTERVAL (seconds)";;
      ask_show_src)       echo "GSWARM_SHOW_SRC (auto/always/never)";;
      ask_autosend)       echo "GSWARM_AUTO_SEND (0/1)";;
      env_json_hint_1)    echo "GSWARM_NODE_MAP must be valid JSON or empty.";;
      env_json_hint_2)    echo "Example: {\"node-1\":{\"eoa\":\"0x...\",\"peer_ids\":[\"Qm..\"],\"tgid\":\"123456\"}}";;
      ask_nodemap)        echo "GSWARM_NODE_MAP (JSON or empty)";;
      bad_json)           echo "Invalid JSON. Using empty.";;

      env_done)           echo ".env updated:";;

      port_busy)          echo "Port is already in use. Pick another port or stop that process:";;
      fw_q)               echo "Open this port in firewall (ufw/firewalld)? (y/N):";;
      fw_inactive)        echo "ufw is installed but inactive -> skipping rule.";;
      fw_skip)            echo "Skipping firewall config.";;

      repo_not_found)     echo "Repo not found. Install monitor first.";;

      monitor_dir_now)    echo "Current dashboard repo dir:";;
      ask_delete_repo)    echo "Delete this directory? (y/N):";;
      ask_confirm_rm)     echo "Confirm path to delete";;
      repo_deleted)       echo "Removed:";;
      repo_skip)          echo "Directory not removed (skipped).";;
      monitor_removed)    echo "Monitor removed.";;

      agent_dl)           echo "Downloading agent files from GitHub raw...";;
      agent_using_local)  echo "Using agent files from local repo:";;
      ask_server)         echo "Monitor URL (ex http://host:8080)";;
      ask_secret)         echo "SHARED_SECRET";;
      ask_node)           echo "NODE_ID";;
      ask_meta)           echo "META (freeform tag, optional)";;
      ask_eoa)            echo "GSWARM_EOA (EOA address 0x..., optional)";;
      ask_peers)          echo "GSWARM_PEER_IDS (comma-separated, optional)";;
      ask_tgid)           echo "GSWARM_TGID (Telegram ID, optional)";;
      ask_dashurl)        echo "DASH_URL (dashboard link for this node, optional)";;
      ask_admin_token)    echo "ADMIN_TOKEN (/api/admin/delete token, optional)";;

      agent_cfg_path)     echo "Agent config:";;
      agent_timer_on)     echo "Agent enabled (timer)";;
      agent_initial_push) echo "Requesting initial G-Swarm sync...";;
      agent_initial_ok)   echo "Initial G-Swarm sync requested.";;
      agent_initial_fail) echo "Could not call G-Swarm API (skipped).";;

      agent_old_removed)  echo "Old node_id removed from monitor.";;
      agent_old_fail)     echo "Could not remove old node_id from monitor.";;

      agent_env_missing)  echo "Agent env file not found.";;

      ask_repo_keep)      echo "Keeping repo directory.";;

      rm_agent_api)       echo "Removing node from monitor via /api/admin/delete...";;
      rm_agent_done)      echo "Agent removed.";;

      autorestart_install) echo "Installing autorestart (watchdog + launcher)...";;
      autorestart_ok)      echo "Autorestart installed.";;
      autorestart_hint)    echo "Screen session name: gensyn (screen -ls / screen -r gensyn)";;

      autorestart_logs_live) echo "=== live watchdog logs (Ctrl+C to exit) ===";;
      autorestart_logs_tail) echo "=== tail of swarm log (rl-swarm inside screen gensyn) ===";;
      swarmlog_empty)       echo "[i] swarm log empty or missing";;

      autorestart_rm)       echo "Removing autorestart (watchdog + launcher)...";;
      autorestart_rm_ok)    echo "Autorestart removed.";;
      swarm_left)           echo "Swarm log left in";;

      press_enter)       echo "Press Enter to return to menu...";;

      menu_title)        echo "Gensyn Manager — dashboard / agent / autorestart";;
      m1)  echo "Prepare machine (deps)";;
      m2)  echo "Install dashboard monitor";;
      m3)  echo "Update dashboard monitor";;
      m4)  echo "Monitor status";;
      m5)  echo "Monitor logs";;
      m6)  echo "Remove dashboard monitor";;

      m7)  echo "Install agent";;
      m8)  echo "Reinstall agent (stop+install)";;
      m9)  echo "Show agent config";;
      m10) echo "Agent status";;
      m11) echo "Agent logs";;
      m12) echo "Remove agent";;

      m13) echo "Install autorestart (watchdog + launcher)";;
      m14) echo "Watchdog logs (live + swarm tail)";;
      m15) echo "Remove autorestart";;

      m16) echo "Change language";;
      m0) echo "Exit";;
    esac
  else
    case "$k" in
      need_root)          echo "Нужны root-права (sudo), иначе часть действий упрётся в отказ.";;

      deps_begin)         echo "Ставлю базовые зависимости (python3, curl, jq и так далее)...";;
      deps_done)          echo "Зависимости установлены.";;

      ask_uvicorn_port)   echo "Порт uvicorn для дашборда:";;
      ask_repo_dir)       echo "Куда ставим репозиторий:";;
      venv_setup)         echo "Готовлю venv и питон-зависимости...";;
      monitor_ok)         echo "Мониторинг поднят на порту";;
      monitor_upd_done)   echo "Монитор обновлён и перезапущен.";;

      env_intro)          echo "Настраиваю .env для дашборда мониторинга";;
      env_found)          echo ".env уже есть, пустой ответ оставит старое значение.";;

      ask_bot)            echo "TELEGRAM_BOT_TOKEN";;
      ask_chat)           echo "TELEGRAM_CHAT_ID";;
      ask_shared)         echo "SHARED_SECRET";;
      ask_admin)          echo "ADMIN_TOKEN (опционально)";;
      ask_title)          echo "SITE_TITLE";;
      ask_thr)            echo "DOWN_THRESHOLD_SEC (в секундах)";;
      ask_intv)           echo "GSWARM_REFRESH_INTERVAL (в секундах)";;
      ask_show_src)       echo "GSWARM_SHOW_SRC (auto/always/never)";;
      ask_autosend)       echo "GSWARM_AUTO_SEND (0/1)";;
      env_json_hint_1)    echo "GSWARM_NODE_MAP — валидный JSON или пусто.";;
      env_json_hint_2)    echo "Пример: {\"node-1\":{\"eoa\":\"0x...\",\"peer_ids\":[\"Qm..\"],\"tgid\":\"123456\"}}";;
      ask_nodemap)        echo "GSWARM_NODE_MAP (JSON или пусто)";;
      bad_json)           echo "JSON кривой. Оставляю пусто.";;

      env_done)           echo ".env обновлён:";;

      port_busy)          echo "Порт уже занят. Освободи порт или выбери другой:";;
      fw_q)               echo "Открыть этот порт во фаерволе (ufw/firewalld)? (y/N):";;
      fw_inactive)        echo "ufw есть, но он выключен. Пропускаю правило.";;
      fw_skip)            echo "Фаервол трогать не будем.";;

      repo_not_found)     echo "Каталог с монитором не найден. Сначала поставь монитор.";;

      monitor_dir_now)    echo "Папка дашборда сейчас:";;
      ask_delete_repo)    echo "Удалить эту папку? (y/N):";;
      ask_confirm_rm)     echo "Подтверди путь, который удаляем";;
      repo_deleted)       echo "Удалил:";;
      repo_skip)          echo "Папку не трогаю.";;
      monitor_removed)    echo "Мониторинг удалён.";;

      agent_dl)           echo "Скачиваю файлы агента из GitHub raw...";;
      agent_using_local)  echo "Беру файлы агента с диска:";;
      ask_server)         echo "URL мониторинга (например http://host:8080)";;
      ask_secret)         echo "SHARED_SECRET";;
      ask_node)           echo "NODE_ID";;
      ask_meta)           echo "META (любая подпись узла, можно пусто)";;
      ask_eoa)            echo "GSWARM_EOA (0x..., опционально)";;
      ask_peers)          echo "GSWARM_PEER_IDS (через запятую, опционально)";;
      ask_tgid)           echo "GSWARM_TGID (Telegram ID, опц.)";;
      ask_dashurl)        echo "DASH_URL (ссылка на ноду в дашборде, опц.)";;
      ask_admin_token)    echo "ADMIN_TOKEN (для /api/admin/delete, опц.)";;

      agent_cfg_path)     echo "Конфиг агента:";;
      agent_timer_on)     echo "Агент включён (таймер)";;
      agent_initial_push) echo "Дёргаю первичный сбор G-Swarm...";;
      agent_initial_ok)   echo "Запросил первичный сбор G-Swarm.";;
      agent_initial_fail) echo "Не получилось дёрнуть G-Swarm API, пропустил.";;

      agent_old_removed)  echo "Старый node_id убран из монитора.";;
      agent_old_fail)     echo "Не смог убрать старый node_id с монитора.";;

      agent_env_missing)  echo "Файл окружения агента не найден.";;

      ask_repo_keep)      echo "Каталог оставляем.";;

      rm_agent_api)       echo "Удаляю ноду из монитора через /api/admin/delete...";;
      rm_agent_done)      echo "Агент удалён.";;

      autorestart_install) echo "Ставлю авторестарт (watchdog + launcher)...";;
      autorestart_ok)      echo "Авторестарт установлен.";;
      autorestart_hint)    echo "screen-сессия будет называться gensyn (screen -ls / screen -r gensyn)";;

      autorestart_logs_live) echo "=== живые логи watchdog (Ctrl+C чтобы выйти) ===";;
      autorestart_logs_tail) echo "=== хвост лога роя (rl-swarm внутри screen gensyn) ===";;
      swarmlog_empty)       echo "[i] лог роя пустой или ещё не создался";;

      autorestart_rm)       echo "Убираю авторестарт (watchdog + launcher)...";;
      autorestart_rm_ok)    echo "Авторестарт удалён.";;
      swarm_left)           echo "Лог роя оставил в";;

      press_enter)       echo "Нажми Enter чтобы вернуться в меню...";;

      menu_title)        echo "Gensyn Manager — монитор / агент / авторестарт";;
      m1)  echo "Подготовить сервер";;
      m2)  echo "Установить мониторинг (на главном сервере)";;
      m3)  echo "Обновить мониторинг";;
      m4)  echo "Статус мониторинга";;
      m5)  echo "Логи мониторинга";;
      m6)  echo "Удалить мониторинг";;

      m7)  echo "Установить агента (на сервере с нодой)";;
      m8)  echo "Переустановить агента";;
      m9)  echo "Показать конфиг агента";;
      m10) echo "Статус агента";;
      m11) echo "Логи агента";;
      m12) echo "Удалить агента";;

      m13) echo "Поставить авторестарт";;
      m14) echo "Логи авторестарта";;
      m15) echo "Удалить авторестарт";;

      m16) echo "Сменить язык / Change language";;
      m0) echo "Выход";;
    esac
  fi
}

# -----------------------------
# helpers
# -----------------------------
need_root(){
  if [[ $EUID -ne 0 ]]; then
    err "$(tr need_root)"
    exit 1
  fi
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

ask(){
  local prompt="$1" def="${2:-}"
  read -rp "${prompt}${def:+ [$def]}: " val || true
  if [[ -z "${val:-}" && -n "$def" ]]; then
    val="$def"
  fi
  printf '%s' "${val:-}"
}

shell_quote(){
  if have_cmd python3; then
    python3 - "$1" <<'PY'
import shlex,sys
v=sys.argv[1] if len(sys.argv)>1 else ""
print(shlex.quote(v))
PY
  else
    printf '%q' "$1"
  fi
}

json_string(){
  if have_cmd python3; then
    python3 - "$1" <<'PY'
import json,sys
print(json.dumps(sys.argv[1] if len(sys.argv)>1 else ""))
PY
  else
    local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"
    printf '"%s"' "$v"
  fi
}

ensure_dos2unix(){
  if ! have_cmd dos2unix; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y dos2unix >/dev/null 2>&1 || true
  fi
}

crlf_fix(){
  ensure_dos2unix
  for f in "$@"; do
    [[ -f "$f" ]] && dos2unix -q "$f" || true
  done
}

is_number(){ [[ "$1" =~ ^[0-9]+$ ]]; }

json_validate(){
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
except:
  sys.exit(1)
PY
    return $?
  else
    return 0
  fi
}

write_kv(){
  local k="$1" v="$2"
  v=${v//$'\r'/}
  v=${v//$'\n'/}
  printf '%s=%s\n' "$k" "$v"
}

current_repo_dir(){
  local svc="/etc/systemd/system/${SERVICE_NAME}.service"
  if [[ -f "$svc" ]]; then
    local d
    d=$(awk -F= '/^WorkingDirectory=/{print $2; exit}' "$svc")
    if [[ -n "$d" ]]; then
      printf '%s' "$d"
      return 0
    fi
  fi
  printf '%s' "$REPO_DIR"
}

wait_port_free(){
  local port="$1"
  if ss -ltn "( sport = :$port )" | grep -q ":$port"; then
    err "$(tr port_busy)"
    ss -ltnp | grep ":$port" || true
    exit 1
  fi
}

maybe_open_firewall_port(){
  local port="$1"
  read -rp "$(tr fw_q) " ans || true
  case "${ans,,}" in
    y|yes)
      if have_cmd ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -n1 || true)
        if [[ "$ufw_status" =~ inactive ]]; then
          info "$(tr fw_inactive)"
        else
          info "ufw allow ${port}/tcp"
          ufw allow "${port}/tcp" >/dev/null 2>&1 || ufw allow "${port}" >/dev/null 2>&1 || true
          ufw reload >/dev/null 2>&1 || true
        fi
      elif have_cmd firewall-cmd; then
        info "firewalld add-port ${port}/tcp"
        firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
      else
        warn "no ufw/firewalld found, add rule manually if needed."
      fi
      ;;
    *)
      info "$(tr fw_skip)"
      ;;
  esac
}

# -----------------------------
# prepare machine
# -----------------------------
prepare_deps(){
  need_root
  info "$(tr deps_begin)"
  apt-get update
  apt-get install -y python3 python3-venv python3-pip git sqlite3 curl jq unzip ca-certificates
  ok   "$(tr deps_done)"
}

# -----------------------------
# clone/update repo
# -----------------------------
clone_or_update_repo(){
  local dest="$1"
  if [[ -d "$dest/.git" ]]; then
    info "git pull in $dest"
    git -C "$dest" fetch --all --prune >/dev/null 2>&1
    git -C "$dest" reset --hard origin/main >/dev/null 2>&1
  else
    info "git clone to $dest"
    mkdir -p "$(dirname "$dest")"
    git clone "$REPO_URL" "$dest" >/dev/null 2>&1
  fi
}

# -----------------------------
# prompt .env for monitor
# -----------------------------
prompt_monitor_env(){
  local repo="$1" env_file="$repo/.env"

  info "$(tr env_intro)"

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
    info "$(tr env_found)"
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

  TE_BOT="$(ask "$(tr ask_bot)" "$_bot")"
  TE_CHAT="$(ask "$(tr ask_chat)" "$_chat")"
  SHARED="$(ask "$(tr ask_shared)" "$_shared")"
  ADMIN="$(ask "$(tr ask_admin)" "$_admin")"
  TITLE="$(ask "$(tr ask_title)" "$_title")"

  THR="$(ask "$(tr ask_thr)" "$_thr")"
  while [[ -n "$THR" ]] && ! is_number "$THR"; do
    warn "number required"
    THR="$(ask "$(tr ask_thr)" "$_thr")"
  done

  INTV="$(ask "$(tr ask_intv)" "$_interval")"
  while [[ -n "$INTV" ]] && ! is_number "$INTV"; do
    warn "number required"
    INTV="$(ask "$(tr ask_intv)" "$_interval")"
  done

  SHOW_SRC="$(ask "$(tr ask_show_src)" "$_show_src")"
  case "${SHOW_SRC,,}" in auto|always|never) ;; *) SHOW_SRC="auto";; esac

  AUTOSEND="$(ask "$(tr ask_autosend)" "$_autosend")"
  [[ "$AUTOSEND" != "1" ]] && AUTOSEND="0"

  echo
  echo "$(tr env_json_hint_1)"
  echo "$(tr env_json_hint_2)"
  NODEMAP_INPUT="$(ask "$(tr ask_nodemap)" "$_nodemap")"
  if [[ -n "$NODEMAP_INPUT" ]] && ! json_validate "$NODEMAP_INPUT"; then
    warn "$(tr bad_json)"
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
  } > "$tmp"
  mv -f "$tmp" "$env_file"

  ok "$(tr env_done) $env_file"
}

# -----------------------------
# install / update monitor
# -----------------------------
install_monitor(){
  need_root
  local port repo

  port="$(ask "$(tr ask_uvicorn_port)" "8080")"
  repo="$(ask "$(tr ask_repo_dir)" "$REPO_DIR")"

  wait_port_free "$port"
  maybe_open_firewall_port "$port"
  clone_or_update_repo "$repo"

  cd "$repo"
  crlf_fix "$repo/.env" "$repo/example.env" || true
  prompt_monitor_env "$repo"

  info "$(tr venv_setup)"
  python3 -m venv .venv
  source .venv/bin/activate
  python -m pip install --upgrade pip
  pip install -r requirements.txt
  deactivate

  cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
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

  ok "$(tr monitor_ok) $port"
}

update_monitor(){
  need_root
  local repo
  repo="$(ask "$(tr ask_repo_dir)" "$REPO_DIR")"

  if [[ ! -d "$repo" ]]; then
    err "$(tr repo_not_found)"
    return 1
  fi

  clone_or_update_repo "$repo"

  cd "$repo"
  source .venv/bin/activate
  python -m pip install --upgrade pip
  pip install -r requirements.txt
  deactivate

  systemctl restart ${SERVICE_NAME}.service
  ok "$(tr monitor_upd_done)"
}

monitor_status(){
  systemctl status ${SERVICE_NAME}.service
}
monitor_logs(){
  journalctl -u ${SERVICE_NAME}.service -n 100 --no-pager
}

remove_monitor(){
  need_root
  systemctl disable --now ${SERVICE_NAME}.service || true
  rm -f /etc/systemd/system/${SERVICE_NAME}.service
  systemctl daemon-reload

  local default_repo delete_choice confirm_path
  default_repo="$(current_repo_dir)"

  info "$(tr monitor_dir_now) ${default_repo}"
  read -rp "$(tr ask_delete_repo) " delete_choice || true
  if [[ "${delete_choice,,}" == "y" || "${delete_choice,,}" == "yes" ]]; then
    confirm_path="$(ask "$(tr ask_confirm_rm)" "$default_repo")"
    if [[ -n "$confirm_path" && -d "$confirm_path" ]]; then
      rm -rf "$confirm_path"
      ok "$(tr repo_deleted) $confirm_path"
    else
      info "$(tr repo_skip)"
    fi
  else
    info "$(tr ask_repo_keep)"
  fi

  ok "$(tr monitor_removed)"
}

# -----------------------------
# agent install / reinstall / status / logs / remove
# -----------------------------
ensure_repo_for_agent(){
  local local_agents="$REPO_ROOT/agents/linux"

  if [[ -f "$local_agents/gensyn_agent.sh" ]]; then
    echo "$local_agents"
    return 0
  fi

  if have_cmd git; then
    info "agent files not found locally, cloning to $REPO_DIR" >&2
    clone_or_update_repo "$REPO_DIR" >&2
    local_agents="$REPO_DIR/agents/linux"
    if [[ -f "$local_agents/gensyn_agent.sh" ]]; then
      echo "$local_agents"
      return 0
    fi
  fi

  echo ""
  return 1
}

install_agent_from_raw(){
  info "$(tr agent_dl)"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn_agent.sh"      -o "$AGENT_BIN"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-agent.service" -o "$AGENT_SERVICE"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-agent.timer"   -o "$AGENT_TIMER"
  chmod 0755 "$AGENT_BIN"
  chmod 0644 "$AGENT_SERVICE" "$AGENT_TIMER"
  crlf_fix "$AGENT_BIN" "$AGENT_SERVICE" "$AGENT_TIMER"
}

install_agent(){
  need_root

  server="$(ask "$(tr ask_server)" "${DEFAULT_SERVER_URL:-}")"
  secret="$(ask "$(tr ask_secret)" "${DEFAULT_SHARED_SECRET:-}")"
  node_default="${DEFAULT_NODE_ID:-$(hostname)-gensyn}"
  node_id="$(ask "$(tr ask_node)" "$node_default")"
  meta="$(ask "$(tr ask_meta)" "${DEFAULT_META:-}")"
  eoa="$(ask "$(tr ask_eoa)" "${DEFAULT_GSWARM_EOA:-}")"
  peers="$(ask "$(tr ask_peers)" "${DEFAULT_GSWARM_PEER_IDS:-}")"
  tgid="$(ask "$(tr ask_tgid)" "${DEFAULT_GSWARM_TGID:-}")"
  dashurl="$(ask "$(tr ask_dashurl)" "${DEFAULT_DASH_URL:-}")"
  admin_token="$(ask "$(tr ask_admin_token)" "${DEFAULT_ADMIN_TOKEN:-}")"

  local agents_dir
  agents_dir="$(ensure_repo_for_agent || true)"

  if [[ -n "$agents_dir" ]]; then
    info "$(tr agent_using_local) $agents_dir"
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
    printf 'NODE_ID=%s\n'           "$(shell_quote "$node_id")"
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

  ok "$(tr agent_timer_on) $(basename "$AGENT_TIMER")"
  info "$(tr agent_cfg_path) $AGENT_ENV"

  if [[ -n "$server" ]]; then
    endpoint="${server%/}/api/gswarm/check?include_nodes=true&send=false"
    info "$(tr agent_initial_push) $endpoint"
    if curl -fsS -X POST "$endpoint" -d '' >/dev/null 2>&1; then
      ok "$(tr agent_initial_ok)"
    else
      warn "$(tr agent_initial_fail)"
    fi
  fi

  # перезапустить сервис агента, чтоб он перечитал AUTO_KILL_EMPTY_SCREEN=false
  systemctl restart "$(basename "$AGENT_SERVICE")" || true
}

reinstall_agent(){
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
    prev_tgid="${GSWARM_TGID:-}"
    prev_dash="${DASH_URL:-}"
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
    endpoint="${prev_server%/}/api/admin/delete"
    payload=$(json_string "$prev_node")
    if curl -fsS -X POST "$endpoint" \
         -H "Authorization: Bearer ${prev_admin}" \
         -H "Content-Type: application/json" \
         -d "{\"node_id\":${payload}}" >/dev/null 2>&1; then
      ok "$(tr agent_old_removed)"
    else
      warn "$(tr agent_old_fail)"
    fi
  fi
}

show_agent_env(){
  if [[ -f "$AGENT_ENV" ]]; then
    echo "== $AGENT_ENV =="
    cat "$AGENT_ENV"
  else
    warn "$(tr agent_env_missing)"
  fi
}

agent_status(){
  systemctl status "$(basename "$AGENT_TIMER")" "$(basename "$AGENT_SERVICE")"
}
agent_logs(){
  journalctl -u "$(basename "$AGENT_SERVICE")" -n 100 --no-pager
}

remove_agent(){
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
  rm -f "$AGENT_TIMER" "$AGENT_SERVICE" "$AGENT_BIN" "$AGENT_ENV"
  systemctl daemon-reload

  if [[ -n "$server_env" && -n "$node_env" && -n "$admin_env" ]]; then
    info "$(tr rm_agent_api) $server_env"
    curl -fsS -X POST "${server_env%/}/api/admin/delete" \
      -H "Authorization: Bearer ${admin_env}" \
      -H "Content-Type: application/json" \
      -d "{\"node_id\":\"${node_env}\"}" >/dev/null 2>&1 || true
  fi

  ok "$(tr rm_agent_done)"
}

# -----------------------------
# autorestart (watchdog + launcher)
# -----------------------------
install_autorestart(){
  need_root
  info "$(tr autorestart_install)"

  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.sh"              -o "$WATCHDOG_BIN"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.service"         -o "$WATCHDOG_SERVICE"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-watchdog.timer"           -o "$WATCHDOG_TIMER"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-screen-launcher.sh"       -o "$LAUNCHER_BIN"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-screen-launcher.service"  -o "$LAUNCHER_SERVICE"

  chmod 0755 "$WATCHDOG_BIN" "$LAUNCHER_BIN"
  chmod 0644 "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$LAUNCHER_SERVICE"
  crlf_fix "$WATCHDOG_BIN" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$LAUNCHER_BIN" "$LAUNCHER_SERVICE"

  # лог роя
  if [[ ! -f "$SWARM_LOG" ]]; then
    touch "$SWARM_LOG"
    chmod 0644 "$SWARM_LOG"
  fi

  # агент не должен убивать пустую screen gensyn
  if [[ -f "$AGENT_ENV" ]]; then
    if ! grep -q '^AUTO_KILL_EMPTY_SCREEN=' "$AGENT_ENV" 2>/dev/null; then
      echo "AUTO_KILL_EMPTY_SCREEN='false'" >> "$AGENT_ENV"
    else
      sed -i "s/^AUTO_KILL_EMPTY_SCREEN=.*/AUTO_KILL_EMPTY_SCREEN='false'/" "$AGENT_ENV"
    fi
  else
    echo "AUTO_KILL_EMPTY_SCREEN='false'" > "$AGENT_ENV"
    chmod 0644 "$AGENT_ENV"
  fi

  systemctl daemon-reload

  # агент перечитывает env
  systemctl restart "$(basename "$AGENT_SERVICE")" || true
  # launcher создает screen gensyn и запускает рой
  systemctl enable --now "$(basename "$LAUNCHER_SERVICE")"
  # watchdog.timer периодически проверяет статус и если DOWN рестартит launcher
  systemctl enable --now "$(basename "$WATCHDOG_TIMER")"

  ok "$(tr autorestart_ok)"
  info "$(tr autorestart_hint)"
}

watchdog_logs(){
  need_root
  echo
  echo "$(tr autorestart_logs_live)"
  echo
  journalctl -u "$(basename "$WATCHDOG_SERVICE")" -f --no-pager || true

  echo
  echo "$(tr autorestart_logs_tail)"
  if ! tail -n 100 "$SWARM_LOG" 2>/dev/null; then
    echo "$(tr swarmlog_empty)"
  fi
  echo
}

remove_autorestart(){
  need_root
  info "$(tr autorestart_rm)"

  systemctl disable --now "$(basename "$WATCHDOG_TIMER")" 2>/dev/null || true
  systemctl disable --now "$(basename "$WATCHDOG_SERVICE")" 2>/dev/null || true
  systemctl disable --now "$(basename "$LAUNCHER_SERVICE")" 2>/dev/null || true

  # гасим screen gensyn
  screen -S gensyn -X quit || true

  rm -f "$WATCHDOG_TIMER" "$WATCHDOG_SERVICE" "$WATCHDOG_BIN"
  rm -f "$LAUNCHER_SERVICE" "$LAUNCHER_BIN"

  systemctl daemon-reload

  ok "$(tr autorestart_rm_ok)"
  info "$(tr swarm_left) $SWARM_LOG"
}

# -----------------------------
# Menu
# -----------------------------
main_menu(){
  choose_lang
  info "$(tr need_root)"; hr

  while true; do
    clear; logo; hr
    echo -e "${cBold}${cM}$(tr menu_title)${c0} ${cDim}(v${SCRIPT_VERSION})${c0}\n"

    echo "1)  $(tr m1)"
    echo "2)  $(tr m2)"
    echo "3)  $(tr m3)"
    echo "4)  $(tr m4)"
    echo "5)  $(tr m5)"
    echo "6)  $(tr m6)"
    hr
    echo "7)  $(tr m7)"
    echo "8)  $(tr m8)"
    echo "9)  $(tr m9)"
    echo "10) $(tr m10)"
    echo "11) $(tr m11)"
    echo "12) $(tr m12)"
    hr
    echo "13) $(tr m13)"
    echo "14) $(tr m14)"
    echo "15) $(tr m15)"
    hr
    echo "16) $(tr m16)"
    echo "0) $(tr m0)"
    hr

    read -rp "> " ch
    case "${ch:-}" in
      1)  prepare_deps ;;
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
      16) choose_lang ;;
      0) exit 0 ;;
      *)  ;;
    esac

    echo -e "\n$(tr press_enter)"
    read -r
  done
}

main_menu
