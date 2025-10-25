#!/usr/bin/env bash
#
# Gensyn Monitor helper.
# Готовит сервер, ставит/обновляет/удаляет мониторинг и агента,
# показывает статус/логи. Поддерживает DASH_URL для нод.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_URL="https://github.com/k2wGG/gensyn-monitor.git"
REPO_DIR="/opt/gensyn-monitor"

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

ask() {
  local prompt="$1" default="${2:-}"
  local value
  read -rp "$prompt${default:+ [$default]}: " value || true
  if [[ -z "${value:-}" && -n "$default" ]]; then
    value="$default"
  fi
  printf '%s' "${value:-}"
}

ensure_dos2unix() {
  if ! have_cmd dos2unix; then
    apt-get update && apt-get install -y dos2unix >/dev/null
  fi
}

crlf_fix() {
  # Безопасно прогоняем файлы через dos2unix (если они вдруг с CRLF)
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

prepare_device() {
  need_root
  echo "[*] Обновляем пакеты и ставим зависимости…"
  apt-get update
  apt-get install -y python3 python3-venv python3-pip git sqlite3 curl jq unzip
  echo "[+] Готово"
}

clone_or_update_repo() {
  local dest="$1"
  if [[ -d "$dest/.git" ]]; then
    echo "[*] Обновляем репозиторий $dest"
    git -C "$dest" fetch --all --prune
    git -C "$dest" reset --hard origin/main
  else
    echo "[*] Клонируем репозиторий в $dest"
    mkdir -p "$(dirname "$dest")"
    git clone "$REPO_URL" "$dest"
  fi
}

install_monitor() {
  need_root
  local port repo
  port="$(ask "Порт для uvicorn" "8080")"
  repo="$(ask "Каталог для установки репозитория" "$REPO_DIR")"

  wait_port_free "$port"
  clone_or_update_repo "$repo"

  cd "$repo"
  crlf_fix "$repo/.env" "$repo/example.env" || true

  echo "[*] Настраиваем venv и зависимости…"
  python3 -m venv .venv
  source .venv/bin/activate
  python -m pip install --upgrade pip
  pip install -r requirements.txt
  deactivate

  if [[ ! -f .env ]]; then
    cp example.env .env
    echo "[i] Сконфигурируйте .env (nano $repo/.env) перед стартом сервиса, если ещё не сделали."
  fi

  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Gensyn Monitor (Uvicorn)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${repo}
Environment=PYTHONUNBUFFERED=1
# Вдобавок к python-dotenv, пробрасываем .env и в окружение процесса (добровольно)
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

install_agent() {
  need_root
  local server secret node meta eoa peers dashurl
  server="$(ask "URL мониторинга (например http://host:8080)")"
  secret="$(ask "SHARED_SECRET" "")"
  node="$(ask "NODE_ID" "$(hostname)-gensyn")"
  meta="$(ask "META (произвольная строка, можно пусто)" "")"
  eoa="$(ask "GSWARM_EOA (0x… — EOA адрес, опционально)" "")"
  peers="$(ask "GSWARM_PEER_IDS (через запятую, опционально)" "")"
  dashurl="$(ask "DASH_URL (адрес этой ноды в дашборде, опционально)" "")"

  local agent_src="$REPO_ROOT/agents/linux/gensyn_agent.sh"
  local svc_src="$REPO_ROOT/agents/linux/gensyn-agent.service"
  local tmr_src="$REPO_ROOT/agents/linux/gensyn-agent.timer"

  if [[ ! -f "$agent_src" || ! -f "$svc_src" || ! -f "$tmr_src" ]]; then
    echo "[!] Не найдены файлы агента в $REPO_ROOT/agents/linux. Укажите корректный REPO_ROOT."
    exit 1
  fi

  install -m0755 "$agent_src" "$AGENT_BIN"
  crlf_fix "$AGENT_BIN"

  cat >"$AGENT_ENV" <<EOF
SERVER_URL=${server}
SHARED_SECRET=${secret}
NODE_ID=${node}
META=${meta}
GSWARM_EOA=${eoa}
GSWARM_PEER_IDS=${peers}
DASH_URL=${dashurl}
EOF
  chmod 0644 "$AGENT_ENV"
  crlf_fix "$AGENT_ENV"

  # Ставим unit-файлы (из репозитория → системные каталоги)
  install -m0644 "$svc_src" "$AGENT_SERVICE"
  install -m0644 "$tmr_src" "$AGENT_TIMER"
  crlf_fix "$AGENT_SERVICE" "$AGENT_TIMER"

  systemctl daemon-reload
  systemctl enable --now "$(basename "$AGENT_TIMER")"
  echo "[+] Агент включён (таймер $(basename "$AGENT_TIMER"))"
  echo "[i] Конфиг агента: $AGENT_ENV"
}

reinstall_agent() {
  need_root
  systemctl disable --now "$(basename "$AGENT_TIMER")" "$(basename "$AGENT_SERVICE")" || true
  install_agent
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

  local answer
  answer="$(ask "Удалить директорию репозитория? Введите путь (пусто = не удалять)" "")"
  if [[ -n "$answer" && -d "$answer" ]]; then
    rm -rf "$answer"
    echo "[+] Удалён $answer"
  fi
  echo "[+] Мониторинг удалён"
}

remove_agent() {
  need_root
  systemctl disable --now "$(basename "$AGENT_TIMER")" "$(basename "$AGENT_SERVICE")" || true
  rm -f "$AGENT_TIMER" "$AGENT_SERVICE"
  rm -f "$AGENT_BIN" "$AGENT_ENV"
  systemctl daemon-reload
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
