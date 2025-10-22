#!/usr/bin/env bash
set -euo pipefail

# === Настройки по умолчанию ===
MONITOR_DIR="/opt/gensyn-monitor"
SERVICE_NAME="gensyn-monitor.service"
PY_BIN="python3"

RAW_BASE="https://raw.githubusercontent.com/ksydoruk1508/gensyn-monitor/main"
AGENT_BIN="/usr/local/bin/gensyn_agent.sh"
AGENT_SERVICE="/etc/systemd/system/gensyn-agent.service"
AGENT_TIMER="/etc/systemd/system/gensyn-agent.timer"
AGENT_ENV="/etc/gensyn-agent.env"

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Нужны права root. Запусти: sudo bash $0"
    exit 1
  fi
}

pause() { read -r -p "Дальше Enter..."; }

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer
  read -r -p "$prompt [y/n] (по умолчанию $default): " answer
  answer="${answer:-$default}"
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# pip внутри venv через ensurepip
_venv_pip() {
  local venv_py="$1"
  "$venv_py" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$venv_py" -m pip install --upgrade pip
}

# === 1) Подготовка хоста ===
prepare_host() {
  need_root
  echo "Обновляю пакеты и ставлю зависимости..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  apt-get install -y git curl ca-certificates ufw sqlite3 $PY_BIN python3-venv
  echo "Готово."
  pause
}

create_server_env() {
  local env_path="$MONITOR_DIR/.env"
  echo "Сейчас соберём .env для сервера."
  read -r -p "TELEGRAM_BOT_TOKEN: " TELEGRAM_BOT_TOKEN
  read -r -p "TELEGRAM_CHAT_ID: " TELEGRAM_CHAT_ID
  read -r -p "SHARED_SECRET (длинная случайная строка): " SHARED_SECRET
  read -r -p "DOWN_THRESHOLD_SEC (по умолчанию 180): " DOWN_THRESHOLD_SEC
  DOWN_THRESHOLD_SEC="${DOWN_THRESHOLD_SEC:-180}"
  read -r -p "SITE_TITLE (по умолчанию Gensyn Nodes): " SITE_TITLE
  SITE_TITLE="${SITE_TITLE:-Gensyn Nodes}"
  read -r -p "ADMIN_TOKEN (для admin API): " ADMIN_TOKEN
  read -r -p "PRUNE_DAYS (0 — выключено): " PRUNE_DAYS
  PRUNE_DAYS="${PRUNE_DAYS:-0}"

  cat > "$env_path" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
SHARED_SECRET=$SHARED_SECRET
DOWN_THRESHOLD_SEC=$DOWN_THRESHOLD_SEC
SITE_TITLE=$SITE_TITLE
ADMIN_TOKEN=$ADMIN_TOKEN
PRUNE_DAYS=$PRUNE_DAYS
EOF
  chmod 600 "$env_path"
  echo ".env создан: $env_path"
}

# === 2) Установка сервера мониторинга ===
install_monitor() {
  need_root
  echo "Установка сервера мониторинга в $MONITOR_DIR"
  mkdir -p "$MONITOR_DIR"
  if [[ ! -d "$MONITOR_DIR/.git" ]]; then
    echo "Клонирую репозиторий..."
    git clone https://github.com/ksydoruk1508/gensyn-monitor.git "$MONITOR_DIR"
  else
    echo "Репозиторий уже есть. Обновляю..."
    git -C "$MONITOR_DIR" fetch --all
    git -C "$MONITOR_DIR" reset --hard origin/main
  fi

  # спрашиваем порт
  read -r -p "Порт UI (по умолчанию 8080): " MONITOR_PORT
  MONITOR_PORT="${MONITOR_PORT:-8080}"

  echo "Создаю venv и ставлю зависимости..."
  cd "$MONITOR_DIR"
  $PY_BIN -m venv .venv
  local VENV_PY="$MONITOR_DIR/.venv/bin/python"
  _venv_pip "$VENV_PY"
  "$VENV_PY" -m pip install -r requirements.txt

  if [[ ! -f "$MONITOR_DIR/.env" ]]; then
    create_server_env
  else
    echo ".env уже существует. Пропускаю создание."
  fi

  # systemd unit c выбранным портом
  cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=Gensyn Monitor (Uvicorn)
Wants=network-online.target
After=network-online.target

[Service]
WorkingDirectory=$MONITOR_DIR
Environment="PYTHONUNBUFFERED=1"
EnvironmentFile=-$MONITOR_DIR/.env
ExecStart=$MONITOR_DIR/.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port ${MONITOR_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl status "$SERVICE_NAME" --no-pager || true

  # открыть выбранный порт в UFW по желанию
  if ask_yes_no "Открыть порт ${MONITOR_PORT}/tcp в UFW" "y"; then
    ufw allow "${MONITOR_PORT}/tcp" || true
    echo "Открыл ${MONITOR_PORT}/tcp в UFW."
  fi

  echo
  echo "Мониторинг запущен. Проверка: curl -I http://127.0.0.1:${MONITOR_PORT}/"
  pause
}

create_agent_env() {
  echo "Заполняем конфиг агента $AGENT_ENV"
  read -r -p "SERVER_URL (например http://<MONITOR_HOST>:<PORT>): " server_url
  read -r -p "SHARED_SECRET (тот же, что на сервере): " shared_secret
  read -r -p "NODE_ID (уникальный идентификатор ноды): " node_id
  read -r -p "META (метка, например hetzner-fsn1): " meta
  read -r -p "SCREEN_NAME (по умолчанию gensyn): " screen_name
  screen_name="${screen_name:-gensyn}"
  read -r -p "CHECK_PORT true/false (по умолчанию true): " check_port
  check_port="${check_port:-true}"
  read -r -p "PORT (по умолчанию 3000): " port
  port="${port:-3000}"
  read -r -p "IP_CMD (опц., например http://checkip.amazonaws.com/): " ip_cmd

  cat > "$AGENT_ENV" <<EOF
SERVER_URL=$server_url
SHARED_SECRET=$shared_secret
NODE_ID=$node_id
META=$meta
SCREEN_NAME=$screen_name
CHECK_PORT=$check_port
PORT=$port
${ip_cmd:+IP_CMD=$ip_cmd}
EOF
  chmod 600 "$AGENT_ENV"
  echo "Создан $AGENT_ENV"
}

# === 3) Установка агента (нода) ===
install_agent() {
  need_root
  echo "Скачиваю агент и юниты systemd..."
  curl -fsSL "$RAW_BASE/agents/linux/gensyn_agent.sh" -o "$AGENT_BIN"
  chmod 0755 "$AGENT_BIN"

  curl -fsSL "$RAW_BASE/agents/linux/gensyn-agent.service" -o "$AGENT_SERVICE"
  curl -fsSL "$RAW_BASE/agents/linux/gensyn-agent.timer" -o "$AGENT_TIMER"

  if [[ ! -f "$AGENT_ENV" ]]; then
    create_agent_env
  else
    echo "$AGENT_ENV уже существует. Пропускаю создание."
  fi

  systemctl daemon-reload
  systemctl enable --now "$(basename "$AGENT_TIMER")"
  systemctl status "$(basename "$AGENT_TIMER")" --no-pager || true

  echo
  echo "Логи агента: journalctl -u $(basename "$AGENT_SERVICE") --no-pager -n 50"
  pause
}

# === 4) Удалить мониторинг ===
remove_monitor() {
  need_root
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable --now "$SERVICE_NAME" || true
  fi
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload

  if ask_yes_no "Удалить каталог $MONITOR_DIR целиком" "y"; then
    rm -rf "$MONITOR_DIR"
    echo "Удалён $MONITOR_DIR"
  else
    echo "Каталог оставлен."
  fi
  echo "Мониторинг удалён."
  pause
}

# === 5) Удалить агента ===
remove_agent() {
  need_root
  if systemctl is-enabled --quiet "$(basename "$AGENT_TIMER")" 2>/dev/null || systemctl is-active --quiet "$(basename "$AGENT_TIMER")" 2>/dev/null; then
    systemctl disable --now "$(basename "$AGENT_TIMER")" || true
  fi
  if systemctl is-enabled --quiet "$(basename "$AGENT_SERVICE")" 2>/dev/null || systemctl is-active --quiet "$(basename "$AGENT_SERVICE")" 2>/dev/null; then
    systemctl disable --now "$(basename "$AGENT_SERVICE")" || true
  fi
  rm -f "$AGENT_TIMER" "$AGENT_SERVICE"
  systemctl daemon-reload

  if ask_yes_no "Удалить бинарник агента $AGENT_BIN" "y"; then
    rm -f "$AGENT_BIN"
  fi
  if ask_yes_no "Удалить конфиг $AGENT_ENV" "y"; then
    rm -f "$AGENT_ENV"
  fi
  echo "Агент удалён."
  pause
}

menu() {
  clear
  echo "==============================="
  echo " Gensyn Monitor — установщик"
  echo "==============================="
  echo "1) Подготовка оборудования"
  echo "2) Установка мониторинга (сервер)"
  echo "3) Установка агента (нода)"
  echo "4) Удалить мониторинг"
  echo "5) Удалить агента"
  echo "0) Выход"
  echo "==============================="
  read -r -p "Выбор: " choice
  case "$choice" in
    1) prepare_host ;;
    2) install_monitor ;;
    3) install_agent ;;
    4) remove_monitor ;;
    5) remove_agent ;;
    0) echo "Пока"; exit 0 ;;
    *) echo "Не то. Повтори."; pause ;;
  esac
}

while true; do
  menu
done
