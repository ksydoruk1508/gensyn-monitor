#!/usr/bin/env bash
set -euo pipefail

SCREEN_NAME="gensyn"
SCREEN_BIN="/usr/bin/screen"
SCREEN_DIR="/run/screen/S-root"

LOG_FILE="/var/log/gensyn-swarm.log"

export HOME="/root"
export USER="root"
export LOGNAME="root"
export SHELL="/bin/bash"
export TERM="xterm-256color"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# helper для таймстампа
ts() { date -u +%F'T'%T'Z'; }

# гарантируем каталог для сокетов screen
if [[ ! -d "$SCREEN_DIR" ]]; then
    mkdir -p "$SCREEN_DIR"
    chown root:root "$SCREEN_DIR"
    chmod 700 "$SCREEN_DIR"
fi

# готовим лог
mkdir -p /var/log
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

echo "[$(ts)] launcher: start run, preparing gensyn session" >> "$LOG_FILE"

# убиваем старую сессию gensyn если она есть
if $SCREEN_BIN -list | grep -q "\.${SCREEN_NAME}"; then
    echo "[$(ts)] launcher: killing old screen $SCREEN_NAME" >> "$LOG_FILE"
    $SCREEN_BIN -S "$SCREEN_NAME" -X quit || true
    sleep 1
fi

# вот это тело, которое будет выполняться ВНУТРИ screen
# ключевые моменты:
#  - активируем venv
#  - запускаем run_rl_swarm.sh с автоподстановкой ответов
#  - вывод идёт и на экран, и в лог через tee
#  - после выхода run_rl_swarm.sh мы не вылетаем сразу, а остаёмся в интерактивном bash,
#    чтобы screen-сессия осталась живой и ты мог зайти посмотреть
SCREEN_CMD=$(cat << 'EOF'
set -euo pipefail

LOG_FILE="/var/log/gensyn-swarm.log"
ts() { date -u +%F'T'%T'Z'; }

echo "[$(ts)] screen-inner: starting inside screen session" | tee -a "$LOG_FILE"

cd /root/rl-swarm || {
    echo "[$(ts)] screen-inner: ERROR no /root/rl-swarm" | tee -a "$LOG_FILE"
    exec bash
}

if [[ -f ".venv/bin/activate" ]]; then
    . .venv/bin/activate
    echo "[$(ts)] screen-inner: venv activated" | tee -a "$LOG_FILE"
else
    echo "[$(ts)] screen-inner: ERROR no venv .venv/bin/activate" | tee -a "$LOG_FILE"
fi

chmod +x ./run_rl_swarm.sh 2>/dev/null || true

echo "[$(ts)] screen-inner: launching run_rl_swarm.sh with answers" | tee -a "$LOG_FILE"

# подаём подготовленные ответы в stdin
# 1) N
# 2) Gensyn/Qwen2.5-0.5B-Instruct
# 3) Y
printf 'N\nGensyn/Qwen2.5-0.5B-Instruct\nY\n' \
    | ./run_rl_swarm.sh 2>&1 | tee -a "$LOG_FILE"

echo "[$(ts)] screen-inner: run_rl_swarm.sh exited" | tee -a "$LOG_FILE"

# остаться в интерактивном шелле внутри screen
exec bash
EOF
)

# запускаем новую screen-сессию gensyn с нашим скриптом внутри
$SCREEN_BIN -dmS "$SCREEN_NAME" bash -c "$SCREEN_CMD"

echo "[$(ts)] launcher: spawned new screen $SCREEN_NAME" >> "$LOG_FILE"

# теперь важно: не выходим.
# держим этот launcher-процесс живым в фоне, чтобы systemd видел сервис running.
# если этот процесс умрёт, systemd перезапустит сервис,
# а перезапуск сервиса = убить старую сессию gensyn, создать новую, заново поднять rl-swarm
while true; do
    sleep 30
done
