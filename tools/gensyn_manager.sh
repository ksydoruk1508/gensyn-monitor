#!/usr/bin/env bash
#
# Gensyn Monitor helper.
# Готовит сервер, ставит/обновляет/удаляет мониторинг и агента,
# показывает статус/логи. Поддерживает DASH_URL для нод и интерактивное
# заполнение .env для дашборда.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_URL="https://github.com/k2wGG/gensyn-monitor.git"
REPO_DIR="/opt/gensyn-monitor"
RAW_BASE="https://raw.githubusercontent.com/k2wGG/gensyn-monitor/main"

SERVICE_NAME="gensyn-monitor"

AGENT_BIN="/usr/local/bin/gensyn_agent.sh"
AGENT_ENV="/etc/gensyn-agent.env"
AGENT_SERVICE="/etc/systemd/system/gensyn-agent.service"
AGENT_TIMER="/etc/systemd/system/gensyn-agent.timer"

display_logo() {
  cat <<'EOF'
 _   _           _  _____
| \ | |         | ||____ |
|  \| | ___   __| |    / /_ __
| . ` |/ _ \ / _` |    \ \ '__|
| |\  | (_) | (_| |.___/ / |
\_| \_/\___/ \__,_|\____/|_|
    Gensyn Monitor Manager
      Канал: @NodesN3R
EOF
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт от root (sudo $0)" >&2
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

# Безопасное квотирование для .env (python-dotenv сам парсит без кавычек)
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
    echo "[!] Порт $port занят:"
    ss -ltnp | grep ":$port" || true
    echo "    Выберите другой порт или остановите процесс, занимающий порт."
    exit 1
  fi
}

maybe_open_firewall_port() {
  local port="$1"
  local answer
  read -rp "Открыть порт ${port}/tcp во внешнем firewall? (y/N): " answer || true
  case "${answer,,}" in
    y|yes)
      if have_cmd ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -n1 || true)
        if [[ "$ufw_status" =~ inactive ]]; then
          echo "[i] ufw установлен, но не активен — правило не добавлено."
        else
          echo "[*] Добавляю правило: ufw allow ${port}/tcp"
          ufw allow "${port}/tcp" >/dev/null 2>&1 || ufw allow "${port}" >/dev/null 2>&1 || true
          ufw reload >/dev/null 2>&1 || true
        fi
      elif have_cmd firewall-cmd; then
        echo "[*] Добавляю правило firewalld для ${port}/tcp"
        firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
      else
        echo "[!] Поддерживаемый firewall не найден (ufw/firewalld). Добавьте правило вручную при необходимости."
      fi
      ;;
    *) echo "[i] Пропускаю настройку firewall." ;;
  esac
}

prepare_device() {
  need_root
  echo "[*] Обновляем пакеты и ставим зависимости…"
  apt-get update
  apt-get install -y python3 python3-venv python3-pip git sqlite3 curl jq unzip ca-certificates
  echo "[+] Готово"
}

clone_or_update_repo() {
  local dest="$1"
  if [[ -d "$dest/.git" ]]; then
    echo "[*] updating repository $dest" >&2
    git -C "$dest" fetch --all --prune >/dev/null 2>&1
    git -C "$dest" reset --hard origin/main >/dev/null 2>&1
  else
    echo "[*] cloning repository into $dest" >&2
    mkdir -p "$(dirname "$dest")"
    git clone "$REPO_URL" "$dest" >/dev/null 2>&1
  fi
}

ensure_repo_for_agent() {
  local local_agents="$REPO_ROOT/agents/linux"
  if [[ -f "$local_agents/gensyn_agent.sh" ]]; then
    echo "$local_agents"
    return 0
  fi
  if have_cmd git; then
    echo "[*] local agent files not found, cloning into $REPO_DIR" >&2
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

# ── Вспомогательные для интерактива .env ─────────────────────────────────────

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
    # Нет валидатора — не блокируем установку
    return 0
  fi
}

write_kv() {
  local k="$1" v="$2"
  v=${v//$'\r'/}
  v=${v//$'\n'/}
  printf '%s=%s\n' "$k" "$v"
}

prompt_monitor_env() {
  local repo="$1" env_file="$repo/.env"

  echo "[*] Настраиваем переменные окружения (.env)"

  # Значения по умолчанию через экспорт DEFAULT_*
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
    echo "[i] Найден существующий $env_file — пустые ответы сохранят текущее значение."
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
  ADMIN="$(ask "ADMIN_TOKEN (опционально)" "$_admin")"
  TITLE="$(ask "SITE_TITLE" "$_title")"

  THR="$(ask "DOWN_THRESHOLD_SEC (в секундах)" "$_thr")"
  while [[ -n "$THR" ]] && ! is_number "$THR"; do
    echo "[!] Должно быть число."; THR="$(ask "DOWN_THRESHOLD_SEC" "$_thr")"
  done

  INTV="$(ask "GSWARM_REFRESH_INTERVAL (секунды)" "$_interval")"
  while [[ -n "$INTV" ]] && ! is_number "$INTV"; do
    echo "[!] Должно быть число."; INTV="$(ask "GSWARM_REFRESH_INTERVAL" "$_interval")"
  done

  SHOW_SRC="$(ask "GSWARM_SHOW_SRC (auto/always/never)" "$_show_src")"
  case "${SHOW_SRC,,}" in
    always|never|auto) SHOW_SRC="${SHOW_SRC,,}" ;;
    *) SHOW_SRC="auto" ;;
  esac

  AUTOSEND="$(ask "GSWARM_AUTO_SEND (0/1)" "$_autosend")"
  [[ "$AUTOSEND" != "1" ]] && AUTOSEND="0"

  echo
  echo "[i] GSWARM_NODE_MAP — валидный JSON или пусто."
  echo "    Пример: {\"node-1\":{\"eoa\":\"0x...\",\"peer_ids\":[\"Qm..\"],\"tgid\":\"123456\"}}"
  NODEMAP_INPUT="$(ask "GSWARM_NODE_MAP (JSON, можно пусто)" "$_nodemap")"
  if [[ -n "$NODEMAP_INPUT" ]] && ! json_validate "$NODEMAP_INPUT"; then
    echo "[!] Некорректный JSON. Оставляю пусто."
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
  } >"$tmp"
  mv -f "$tmp" "$env_file"
  echo "[+] Файл .env обновлён: $env_file"
}

install_monitor() {
  need_root
  local port repo
  port="$(ask "Порт для uvicorn" "8080")"
  repo="$(ask "Каталог для установки репозитория" "$REPO_DIR")"

  wait_port_free "$port"
  maybe_open_firewall_port "$port"
  clone_or_update_repo "$repo"

  cd "$repo"
  crlf_fix "$repo/.env" "$repo/example.env" || true

  prompt_monitor_env "$repo"

  echo "[*] Настраиваем venv и зависимости…"
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
  echo "[+] Мониторинг запущен на порту ${port}"
}

update_monitor() {
  need_root
  local repo
  repo="$(ask "Каталог репозитория" "$REPO_DIR")"
  if [[ ! -d "$repo" ]]; then
    echo "[!] Не найден $repo. Сначала поставьте монитор (п.2)."
    return 1
  fi
  clone_or_update_repo "$repo"
  cd "$repo"
  source .venv/bin/activate
  python -m pip install --upgrade pip
  pip install -r requirements.txt
  deactivate
  systemctl restart ${SERVICE_NAME}.service
  echo "[+] Монитор обновлён и перезапущен."
}

install_agent_from_raw() {
  echo "[*] Скачиваю файлы агента из GitHub (RAW)…"
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
  server="$(ask "URL мониторинга (например http://host:8080)" "${DEFAULT_SERVER_URL:-}")"
  secret="$(ask "SHARED_SECRET" "${DEFAULT_SHARED_SECRET:-}")"
  node_default="${DEFAULT_NODE_ID:-$(hostname)-gensyn}"
  node="$(ask "NODE_ID" "$node_default")"
  meta="$(ask "META (произвольная строка, можно пусто)" "${DEFAULT_META:-}")"
  eoa="$(ask "GSWARM_EOA (0x… — EOA адрес, опционально)" "${DEFAULT_GSWARM_EOA:-}")"
  peers="$(ask "GSWARM_PEER_IDS (через запятую, опционально)" "${DEFAULT_GSWARM_PEER_IDS:-}")"
  tgid="$(ask "GSWARM_TGID (Telegram ID для off-chain, опционально)" "${DEFAULT_GSWARM_TGID:-}")"
  dashurl="$(ask "DASH_URL (адрес этой ноды в дашборде, опционально)" "${DEFAULT_DASH_URL:-}")"
  admin_token="$(ask "ADMIN_TOKEN (для /api/admin/delete, опционально)" "${DEFAULT_ADMIN_TOKEN:-}")"

  local agents_dir
  agents_dir="$(ensure_repo_for_agent || true)"

  if [[ -n "$agents_dir" ]]; then
    echo "[*] using agent files from: $agents_dir" >&2
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
  } >"$AGENT_ENV"
  chmod 0644 "$AGENT_ENV"
  crlf_fix "$AGENT_ENV"

  systemctl daemon-reload
  systemctl enable --now "$(basename "$AGENT_TIMER")"
  echo "[+] Агент включён (таймер $(basename "$AGENT_TIMER"))"
  echo "[i] Конфиг агента: $AGENT_ENV"

  if [[ -n "$server" ]]; then
    local endpoint="${server%/}/api/gswarm/check?include_nodes=true&send=false"
    echo "[*] Запрашиваю начальный сбор G-Swarm (${endpoint})…"
    if curl -fsS -X POST "$endpoint" -d '' >/dev/null 2>&1; then
      echo "[+] G-Swarm синхронизирован, данные появятся после перезагрузки UI."
    else
      echo "[!] Не удалось вызвать G-Swarm API (пропущено)." >&2
    fi
  fi
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
  export DEFAULT_DASH_URL="${prev_dash}"
  export DEFAULT_GSWARM_TGID="${prev_tgid}"
  export DEFAULT_ADMIN_TOKEN="${prev_admin}"

  install_agent

  unset DEFAULT_SERVER_URL DEFAULT_SHARED_SECRET DEFAULT_NODE_ID DEFAULT_META \
        DEFAULT_GSWARM_EOA DEFAULT_GSWARM_PEER_IDS DEFAULT_GSWARM_TGID DEFAULT_DASH_URL DEFAULT_ADMIN_TOKEN

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
      echo "[+] Старый node_id ${prev_node} удалён с монитора."
    else
      echo "[!] Не удалось удалить старый node_id ${prev_node} с монитора (пропущено)." >&2
    fi
  fi
}

show_agent_env() {
  if [[ -f "$AGENT_ENV" ]]; then
    echo "== $AGENT_ENV =="
    cat "$AGENT_ENV"
  else
    echo "[!] Файл $AGENT_ENV не найден."
  fi
}

monitor_status()   { systemctl status ${SERVICE_NAME}.service; }
monitor_logs()     { journalctl -u ${SERVICE_NAME}.service -n 100 --no-pager; }
agent_status()     { systemctl status "$(basename "$AGENT_TIMER")" "$(basename "$AGENT_SERVICE")"; }
agent_logs()       { journalctl -u "$(basename "$AGENT_SERVICE")" -n 100 --no-pager; }

remove_monitor() {
  need_root
  systemctl disable --now ${SERVICE_NAME}.service || true
  rm -f /etc/systemd/system/${SERVICE_NAME}.service
  systemctl daemon-reload

  local default_repo delete_choice answer
  default_repo="$(current_repo_dir)"
  echo "[i] Текущий каталог дашборда: ${default_repo}"
  read -rp "Удалить директорию репозитория (${default_repo})? (y/N): " delete_choice || true
  if [[ "${delete_choice,,}" == "y" || "${delete_choice,,}" == "yes" ]]; then
    answer="$(ask "Укажите путь для удаления" "$default_repo")"
    if [[ -n "$answer" && -d "$answer" ]]; then
      rm -rf "$answer"
      echo "[+] Удалён $answer"
    else
      echo "[i] Каталог не найден или не указан — пропущено."
    fi
  else
    echo "[i] Каталог оставлен."
  fi
  echo "[+] Мониторинг удалён"
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
    echo "[*] Удаляю ноду из монитора (${endpoint})…"
    if curl -fsS -X POST "$endpoint" \
         -H "Authorization: Bearer ${admin_env}" \
         -H "Content-Type: application/json" \
         -d "{\"node_id\":\"${node_env}\"}" >/dev/null 2>&1; then
      echo "[+] Нода ${node_env} удалена из монитора."
    else
      echo "[!] Не удалось вызвать /api/admin/delete (пропущено)." >&2
    fi
  fi

  echo "[+] Агент удалён"
}

menu() {
  cat <<'EOF'
==== Gensyn Manager ====
1) Подготовить устройство (зависимости)
2) Установить мониторинг
3) Обновить мониторинг (git pull + pip + restart)
4) Установить агента
5) Переустановить агента (остановить+установить)
6) Показать конфиг агента
7) Статус мониторинга
8) Логи мониторинга
9) Статус агента
10) Логи агента
11) Удалить мониторинг
12) Удалить агента
0) Выход
EOF
}

main() {
  display_logo
  while true; do
    menu
    read -rp "Выберите пункт: " choice || true
    case "${choice:-}" in
      1) prepare_device ;;
      2) install_monitor ;;
      3) update_monitor ;;
      4) install_agent ;;
      5) reinstall_agent ;;
      6) show_agent_env ;;
      7) monitor_status ;;
      8) monitor_logs ;;
      9) agent_status ;;
      10) agent_logs ;;
      11) remove_monitor ;;
      12) remove_agent ;;
      0) exit 0 ;;
      *) echo "Неизвестный пункт" ;;
    esac
  done
}

main "$@"
