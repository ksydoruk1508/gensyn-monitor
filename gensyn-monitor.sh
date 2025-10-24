#!/usr/bin/env bash
set -euo pipefail

# ==============================
#  Gensyn Monitor — установщик
# ==============================

# Пути
MONITOR_DIR="/opt/gensyn-monitor"
SERVICE_NAME="gensyn-monitor.service"

AGENT_BIN="/usr/local/bin/gensyn_agent.sh"
AGENT_ENV="/etc/gensyn-agent.env"
AGENT_SERVICE="/etc/systemd/system/gensyn-agent.service"
AGENT_TIMER="/etc/systemd/system/gensyn-agent.timer"
IP_HELPER="/usr/local/bin/get_ipv4_ip.sh"

PY_BIN="python3"

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "нужны права root. запусти: sudo bash $0"
    exit 1
  fi
}

pause() { read -r -p "дальше Enter..."; }

# ---- venv pip bootstrap ----
_venv_pip() {
  local vpy="$1"
  "$vpy" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$vpy" -m pip install --upgrade pip
}

# ---- IPv4 helper ----
write_ip_helper() {
  cat > "$IP_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if command -v curl >/dev/null 2>&1; then
  curl -4 -s https://ifconfig.me | tr -d '\r\n'
else
  wget -qO- -4 https://ifconfig.me | tr -d '\r\n'
fi
EOF
  chmod 0755 "$IP_HELPER"
}

# ==============================
# 1) Подготовка сервера
# ==============================
prepare_host() {
  need_root
  echo "[*] обновляю пакеты и ставлю зависимости..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  apt-get install -y \
    git curl wget ca-certificates ufw sqlite3 jq \
    screen netcat-openbsd \
    $PY_BIN python3-venv
  echo "[ok] базовые пакеты готовы"
  pause
}

# ==============================
# 2) Установка мониторинга (сервер)
# ==============================
install_monitor() {
  need_root
  echo "[*] ставлю мониторинг в $MONITOR_DIR"
  mkdir -p "$MONITOR_DIR"
  if [[ -d "$MONITOR_DIR/.git" ]]; then
    git -C "$MONITOR_DIR" fetch --all
    git -C "$MONITOR_DIR" reset --hard origin/main
  else
    git clone https://github.com/ksydoruk1508/gensyn-monitor.git "$MONITOR_DIR"
  fi

  read -r -p "порт UI (по умолчанию 8080): " MONITOR_PORT
  MONITOR_PORT="${MONITOR_PORT:-8080}"

  cd "$MONITOR_DIR"
  $PY_BIN -m venv .venv
  local VENV_PY="$MONITOR_DIR/.venv/bin/python"
  _venv_pip "$VENV_PY"
  "$VENV_PY" -m pip install -r requirements.txt

  if [[ ! -f "$MONITOR_DIR/.env" ]]; then
    echo "[*] собираю .env"
    read -r -p "TELEGRAM_BOT_TOKEN: " TELEGRAM_BOT_TOKEN
    read -r -p "TELEGRAM_CHAT_ID: " TELEGRAM_CHAT_ID
    read -r -p "SHARED_SECRET: " SHARED_SECRET
    read -r -p "DOWN_THRESHOLD_SEC (по умолчанию 180): " DOWN_THRESHOLD_SEC
    DOWN_THRESHOLD_SEC="${DOWN_THRESHOLD_SEC:-180}"
    read -r -p "SITE_TITLE (по умолчанию Gensyn Nodes): " SITE_TITLE
    SITE_TITLE="${SITE_TITLE:-Gensyn Nodes}"
    read -r -p "ADMIN_TOKEN (опц.): " ADMIN_TOKEN
    read -r -p "PRUNE_DAYS (0 — выкл.): " PRUNE_DAYS
    PRUNE_DAYS="${PRUNE_DAYS:-0}"

    cat > "$MONITOR_DIR/.env" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
SHARED_SECRET=$SHARED_SECRET
DOWN_THRESHOLD_SEC=$DOWN_THRESHOLD_SEC
SITE_TITLE=$SITE_TITLE
ADMIN_TOKEN=$ADMIN_TOKEN
PRUNE_DAYS=$PRUNE_DAYS
EOF
    chmod 600 "$MONITOR_DIR/.env"
  else
    echo "[=] .env уже есть — пропускаю"
  fi

  # systemd unit под выбранный порт
  cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=Gensyn Monitor (Uvicorn)
Wants=network-online.target
After=network-online.target

[Service]
WorkingDirectory=$MONITOR_DIR
Environment="PYTHONUNBUFFERED=1"
EnvironmentFile=-$MONITOR_DIR/.env
ExecStart=$MONITOR_DIR/.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port $MONITOR_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  echo "[*] открываю порт $MONITOR_PORT/tcp в ufw"
  ufw allow "$MONITOR_PORT/tcp" || true
  echo "[ok] мониторинг запущен. проверка: curl -I http://127.0.0.1:$MONITOR_PORT/"
  pause
}

# ==============================
# 3) Установка агента (нода)
# ==============================

write_agent_script() {
  cat > "$AGENT_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gensyn-agent.env

# ---------- IPv4 helper ----------
: "${IP_CMD:=/usr/local/bin/get_ipv4_ip.sh}"
if [[ ! -x "$IP_CMD" ]]; then
  IP_CMD="bash -c 'curl -4 -s https://ifconfig.me | tr -d \"\r\n\"'"
fi
set +e
IP=$(eval "$IP_CMD" 2>/dev/null)
set -e

# ---------- URL helpers ----------
trim_trailing_slash() { printf '%s' "${1%/}"; }
HB_BASE="$(trim_trailing_slash "${SERVER_URL}")"
CANDIDATE_URLS=(
  "${HB_BASE}/heartbeat"
  "${HB_BASE}/api/heartbeat"
)

# ---------- Логика активности ----------
is_screen_active() { screen -S gensyn -Q select . >/dev/null 2>&1; }

has_joining_round() {
  local log_file="/tmp/gensyn_screen_log.txt"
  if screen -S gensyn -Q select . >/devалл 2>&1; then
    # вся история окна
    screen -S gensyn -X hardcopy -h "$log_file" >/dev/null 2>&1 || true
  fi
  [[ -s "$log_file" ]] && grep -q "Joining round" "$log_file"
}

status="DOWN"
reason=""
if is_screen_active && has_joining_round; then
  status="UP"
else
  if ! is_screen_active; then
    reason="no screen 'gensyn'"
  elif ! has_joining_round; then
    reason="no 'Joining round' in screen history"
  fi
fi

# ---------- JSON payload ----------
if command -v jq >/dev/null 2>&1; then
  payload=$(jq -nc \
    --arg id "$NODE_ID" \
    --arg ip "${IP:-}" \
    --arg meta "${META:-}" \
    --arg st "$status" \
    --arg ss "${SHARED_SECRET:-}" \
    '{node_id:$id, ip:$ip, meta:$meta, status:$st, shared_secret:$ss}')
else
  payload="{\"node_id\":\"${NODE_ID}\",\"ip\":\"${IP:-}\",\"meta\":\"${META:-}\",\"status\":\"${status}\",\"shared_secret\":\"${SHARED_SECRET:-}\"}"
fi

# ---------- Заголовки секрета ----------
HDR_COMMON=(-H "Content-Type: application/json")
[[ -n "${SHARED_SECRET:-}" ]] && HDR_COMMON+=(
  -H "X-Shared-Secret: ${SHARED_SECRET}"
  -H "Authorization: Bearer ${SHARED_SECRET}"
  -H "X-Admin-Token: ${SHARED_SECRET}"
)

# ---------- Отправка с проверкой кода ----------
sent=0
last_code=""
for url in "${CANDIDATE_URLS[@]}"; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$url" "${HDR_COMMON[@]}" -d "$payload" || echo "")
  last_code="$code"
  # 2xx — успех
  if [[ "$code" =~ ^2[0-9]{2}$ ]]; then
    sent=1
    logger -t gensyn-agent "[beat] sent status=${status} url=${url} http=${code} node_id=${NODE_ID} ip=${IP:-}"
    break
  fi
done

if [[ "$sent" -eq 0 ]]; then
  logger -t gensyn-agent "[beat] FAILED status=${status} http=${last_code:-none} node_id=${NODE_ID} ip=${IP:-} urls=${CANDIDATE_URLS[*]}"
fi

# Дополнительный читабельный лог причины, если DOWN
if [[ "$status" != "UP" ]]; then
  logger -t gensyn-agent "[beat] DOWN reason='${reason}'"
fi
EOF
  chmod 0755 "$AGENT_BIN"
}

write_agent_units() {
  cat > "$AGENT_SERVICE" <<EOF
[Unit]
Description=Gensyn agent (smart heartbeat)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$AGENT_ENV
ExecStart=$AGENT_BIN
Nice=10
EOF

  cat > "$AGENT_TIMER" <<EOF
[Unit]
Description=Run gensyn-agent every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=$(basename "$AGENT_SERVICE")

[Install]
WantedBy=timers.target
EOF
}

install_agent() {
  need_root
  echo "[*] установка агента"
  write_ip_helper

  if [[ ! -f "$AGENT_ENV" ]]; then
    read -r -p "SERVER_URL (например http://<монитор>:8080): " SERVER_URL
    read -r -p "SHARED_SECRET (как на сервере): " SHARED_SECRET
    read -r -p "NODE_ID (уникальное имя ноды): " NODE_ID
    read -r -p "META (метка, например hetzner-fsn1): " META
    cat > "$AGENT_ENV" <<EOF
SERVER_URL=$SERVER_URL
SHARED_SECRET=$SHARED_SECRET
NODE_ID=$NODE_ID
META=$META
IP_CMD=$IP_HELPER
EOF
    chmod 600 "$AGENT_ENV"
    echo "[ok] создан $AGENT_ENV (IP helper: $IP_HELPER)"
  else
    echo "[=] $AGENT_ENV уже существует — не трогаю"
    # страховка: если IP_CMD отсутствует — допишем
    if ! grep -q '^IP_CMD=' "$AGENT_ENV"; then
      echo "IP_CMD=$IP_HELPER" >> "$AGENT_ENV"
    fi
  fi

  write_agent_script
  write_agent_units

  systemctl daemon-reload
  systemctl enable --now "$(basename "$AGENT_TIMER")"
  # разовый запуск для немедленной регистрации
  systemctl start "$(basename "$AGENT_SERVICE")"

  echo "[ok] агент установлен. логи ниже:"
  journalctl -u "$(basename "$AGENT_SERVICE")" -n 50 --no-pager || true
  pause
}

# ==============================
# 4) Логи мониторинга
# ==============================
show_monitor_logs() {
  need_root
  echo "=== gensyn-monitor.service (последние 200 строк) ==="
  journalctl -u "$SERVICE_NAME" -n 200 --no-pager || true
  pause
}

# ==============================
# 5) Логи агента
# ==============================
show_agent_logs() {
  need_root
  echo "=== gensyn-agent.service (последние 200 строк) ==="
  journalctl -u "$(basename "$AGENT_SERVICE")" -n 200 --no-pager || true
  echo
  echo "=== gensyn-agent.timer (последние 50 строк) ==="
  journalctl -u "$(basename "$AGENT_TIMER")" -n 50 --no-pager || true
  pause
}

# ==============================
# 6) Удаление мониторинга
# ==============================
remove_monitor() {
  need_root
  echo "[*] останавливаю и удаляю мониторинг"
  # попробуем вытащить порт до удаления юнита, чтобы закрыть в ufw
  if [[ -f "/etc/systemd/system/$SERVICE_NAME" ]]; then
    PORT=$(grep -oP -- "--port\s+\K[0-9]+" "/etc/systemd/system/$SERVICE_NAME" || true)
  else
    PORT=""
  fi

  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload

  if [[ -n "${PORT:-}" ]]; then
    ufw delete allow "${PORT}/tcp" 2>/dev/null || true
  fi

  if [[ -d "$MONITOR_DIR" ]]; then
    read -r -p "удалить каталог $MONITOR_DIR (включая БД)? [y/N]: " ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      rm -rf "$MONITOR_DIR"
      echo "[ok] удалён $MONITOR_DIR"
    else
      echo "[=] каталог оставлен"
    fi
  fi
  echo "[ok] мониторинг удалён"
  pause
}

# ==============================
# 7) Удаление агента
# ==============================
remove_agent() {
  need_root
  echo "[*] останавливаю и удаляю агента"
  systemctl disable --now "$(basename "$AGENT_TIMER")" 2>/dev/null || true
  systemctl disable --now "$(basename "$AGENT_SERVICE")" 2>/dev/null || true
  rm -f "$AGENT_TIMER" "$AGENT_SERVICE" "$AGENT_BIN" "$IP_HELPER"
  systemctl daemon-reload

  if [[ -f "$AGENT_ENV" ]]; then
    read -r -p "удалить конфиг $AGENT_ENV? [y/N]: " ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      rm -f "$AGENT_ENV"
      echo "[ok] удалён $AGENT_ENV"
    else
      echo "[=] конфиг оставлен"
    fi
  fi
  echo "[ok] агент удалён"
  pause
}

# ==============================
# Меню
# ==============================
menu() {
  clear
  echo "==============================="
  echo " Gensyn Monitor — установщик"
  echo "==============================="
  echo "1) Подготовка сервера"
  echo "2) Установка мониторинга (сервер)"
  echo "3) Установка агента (нода)"
  echo "4) Логи мониторинга"
  echo "5) Логи агента"
  echo "6) Удалить мониторинг"
  echo "7) Удалить агента"
  echo "0) Выход"
  echo "==============================="
  read -r -p "выбор: " choice
  case "$choice" in
    1) prepare_host ;;
    2) install_monitor ;;
    3) install_agent ;;
    4) show_monitor_logs ;;
    5) show_agent_logs ;;
    6) remove_monitor ;;
    7) remove_agent ;;
    0) echo "пока"; exit 0 ;;
    *) echo "не то. попробуй ещё"; pause ;;
  esac
}

while true; do
  menu
done
