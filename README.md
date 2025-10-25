# Gensyn Monitor

Централизованный мониторинг нод RL-Swarm (Gensyn).
Лёгкий **агент** на каждой ноде шлёт heartbeat на **центральный сервер** (FastAPI + SQLite).
Сервер показывает таблицу статусов и шлёт алёрты в Telegram при смене состояния (**UP ↔ DOWN**).

---

## 📦 Состав репозитория

* `app.py` — API/веб/логика оповещений и admin-эндпоинты.
* `templates/index.html` — простая таблица статусов (автообновление каждые 10 с).
* `agents/linux/gensyn_agent.sh` — агент для Linux (работает через `systemd`-таймер).
* `agents/linux/gensyn-agent.service` / `agents/linux/gensyn-agent.timer` — юниты агента.
* `agents/windows/gensyn_agent.ps1` — агент для Windows (Task Scheduler).
* `requirements.txt` — зависимости сервера.
* `.env` — переменные окружения **сервера** (создай и заполни сам).

---

## 🧠 Как это работает

### 1) Агент на ноде

Раз в минуту (таймер):

* Ищет `screen`-сессию с именем `SCREEN_NAME` (по умолчанию `gensyn`) и проверяет, что

  * внутри **этой** `screen` запущен «боевой» процесс лаунчера (регэксп `ALLOW_REGEX`),
  * **и, при необходимости,** там же живёт `p2pd` (см. `REQUIRE_P2PD`),
  * (опционально) локальный порт `127.0.0.1:PORT` открыт (`CHECK_PORT=true`),
  * (опционально) лог свежий не старше `LOG_MAX_AGE` секунд.
* Формирует `status: "UP" | "DOWN"` и отправляет `POST /api/heartbeat` на сервер с заголовком
  `Authorization: Bearer <SHARED_SECRET>`.

### 2) Сервер мониторинга

* Принимает heartbeat, сохраняет `last_seen`, IP, `meta`, последний **reported** статус.
* В UI `/` показывает:

  * `computed` — текущее вычисленное состояние по таймауту (см. ниже),
  * `reported` — что прислал агент,
  * «возраст» (секунды с последнего heartbeat).
* Шлёт Telegram-оповещения при смене **computed** статуса (UP ↔ DOWN).

### 3) Как считается **computed** (по таймауту)

* Если от ноды **не было heartbeat** дольше `DOWN_THRESHOLD_SEC` → **DOWN**.
* Если heartbeat свежий → **UP** (даже если агент прислал `reported: DOWN`).

> Если хочешь, чтобы падение **процесса/порта/p2pd/лога** сразу давало DOWN в UI — включай **режим учёта статуса агента** (см. ниже).

---

## ✨ Что нового в агенте

* **Привязка к screen**: процесс засчитывается только если запущен **в нужной `screen`** (проверяем `STY=<pid>.gensyn` в окружении).
* **Режимы `REQUIRE_P2PD`**:

  * `false` — не проверять p2pd;
  * `any` — p2pd должен жить в системе;
  * `screen` — p2pd должен жить **в этой же** `screen`.
* **Проверка свежести лога**: `LOG_FILE` и `LOG_MAX_AGE` (секунды). Если файл не обновлялся — считаем DOWN.
* В `meta` при DOWN можно увидеть причину (`reason=...`) для быстрых расследований.

---

## 🚀 Быстрый старт (сервер)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Создай `.env` в корне (пример):

```ini
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=123456789

SHARED_SECRET=super-long-random-secret  # секрет для агентов
DOWN_THRESHOLD_SEC=180                  # таймаут неактивности в секундах
SITE_TITLE=Gensyn Nodes                 # заголовок страницы

# токен для админ-эндпоинтов /api/admin/*
ADMIN_TOKEN=change-me-admin-token
# (опц.) авто-число дней по умолчанию для admin/prune без тела запроса
PRUNE_DAYS=0
```

Запуск (локально):

```bash
uvicorn app:app --host 0.0.0.0 --port 8080
# открой http://localhost:8080/
```

> Из другой машины: `http://<PUBLIC_IP>:8080/` и открой порт 8080 в фаерволе/облаке.

### (опционально) systemd-сервис для сервера

```bash
sudo tee /etc/systemd/system/gensyn-monitor.service >/dev/null <<'EOF'
[Unit]
Description=Gensyn Monitor (Uvicorn)
Wants=network-online.target
After=network-online.target

[Service]
WorkingDirectory=/root/gensyn-monitor
Environment="PYTHONUNBUFFERED=1"
EnvironmentFile=-/root/gensyn-monitor/.env
ExecStart=/root/gensyn-monitor/.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now gensyn-monitor.service
systemctl status gensyn-monitor.service --no-pager
```

---

## 🖥️ Установка агента (Linux)

1. Установи скрипт агента:

```bash
sudo install -m0755 agents/linux/gensyn_agent.sh /usr/local/bin/gensyn_agent.sh
```

2. Поставь юниты:

```bash
sudo cp agents/linux/gensyn-agent.service /etc/systemd/system/
sudo cp agents/linux/gensyn-agent.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gensyn-agent.timer
```

3. Настрой переменные **(рекомендуемый способ — env-файл)**:

```bash
sudo tee /etc/gensyn-agent.env >/dev/null <<'EOF'
# --- КУДА СТУЧИМСЯ ---
SERVER_URL=http://<MONITOR_HOST>:8080
SHARED_SECRET=super-long-random-secret

# --- ИД НОДЫ/МЕТКИ ---
NODE_ID=my-gensyn-01
META=hetzner-fsn1

# --- ГДЕ ИСКАТЬ НОДУ ---
SCREEN_NAME=gensyn            # имя screen-сессии "<pid>.gensyn"

# --- СЕТЬ/ПОРТ UI ---
CHECK_PORT=true               # проверять ли порт
PORT=3000                     # какой порт проверять (127.0.0.1)

# --- РЕЖИМЫ ДЕТЕКЦИИ ---
PROC_FALLBACK_WITHOUT_SCREEN=false   # считать ли UP процессы вне screen
REQUIRE_P2PD=screen                  # false|any|screen — где искать p2pd

# --- ЛОГИ (свежесть) ---
LOG_FILE=/root/rl-swarm/logs/swarm_launcher.log  # путь к логу
LOG_MAX_AGE=300                                   # макс. «возраст» в сек

# --- РЕГЭКСПЫ (ОДИНАРНЫЕ КАВЫЧКИ!) ---
# «боевые» процессы (НОДА РАБОТАЕТ)
ALLOW_REGEX='python[[:space:]]*-m[[:space:]]*rgym_exp\.runner\.swarm_launcher'

# обёртки/стабы (НЕ считаем здоровьем)
DENY_REGEX='run_rl_swarm\.sh|while[[:space:]]+true|sleep[[:space:]]+60|bash[[:space:]]-c.*while[[:space:]]+true'
EOF
```

> Обрати внимание: регэкспы — **в одинарных кавычках**.
> Если у тебя другой путь к логу — поправь `LOG_FILE`. Если `p2pd` не живёт в этой же `screen`, можешь временно поставить `REQUIRE_P2PD=any` (или `false`) — но рекомендуем настроить `screen` так, чтобы `p2pd` был там же.

4. Проверка/логи агента:

```bash
systemctl status gensyn-agent.timer
journalctl -u gensyn-agent.service --no-pager -n 50
# разовый ручной запуск с трассировкой:
bash -x /usr/local/bin/gensyn_agent.sh |& tail -n 80
```

### Важная заметка про IPv4

Если в UI IP отображается IPv6 и хочется IPv4 — в `/etc/gensyn-agent.env` добавь:

```bash
IP_CMD=https://ipv4.icanhazip.com
```

---

## 🪟 Агент для Windows (кратко)

1. Скопируй `agents/windows/gensyn_agent.ps1` в `C:\gensyn\gensyn_agent.ps1`.
2. Создай задачу Планировщика раз в минуту (от имени SYSTEM).
3. Переменные через «Environment Variables» ОС или прямо в задаче:

```
SERVER_URL=http://<MONITOR_HOST>:8080
SHARED_SECRET=super-long-random-secret
NODE_ID=win-gensyn-01
META=dc=home-lab
CHECK_PORT=true
PORT=3000
```

Проверка вручную:

```powershell
powershell -ExecutionPolicy Bypass -File C:\gensyn\gensyn_agent.ps1
```

---

## 🧪 Диагностика (шпаргалка)

Имя screen:

```bash
SNAME="$(screen -ls | sed -nE "s/^[[:space:]]*([0-9]+\.${SCREEN_NAME:-gensyn})[[:space:]].*/\1/p" | head -n1)"; echo "$SNAME"
```

Проверить, что **лаунчер** и **p2pd** именно **в этой** screen:

```bash
for RX in 'python[[:space:]]*-m[[:space:]]*rgym_exp\.runner\.swarm_launcher' 'hivemind_cli/p2pd'; do
  echo "== $RX =="; for pid in $(pgrep -f "$RX"); do
    tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep -qx "STY=$SNAME" && ps -p "$pid" -o pid=,args=
  done
done
```

Свежесть лога:

```bash
stat -c '%Y %n' /root/rl-swarm/logs/swarm_launcher.log; date +%s
```

Порт:

```bash
ss -ltnp | grep :3000 || nc -zv 127.0.0.1 3000
```

---

## 🧰 Типичные проблемы

1. **Агент всё время UP, даже если нода упала**
   — Убедись, что установлен **последний** `gensyn_agent.sh` (в нём есть `p2pd_ok()` и `log_fresh()`).
   — Проверь, что `REQUIRE_P2PD=screen` и `LOG_FILE` указывает на реальный лог.
   — Если лаунчер живёт в другой `screen`, агент его не засчитает.

2. **DOWN не приходит сразу**
   — По умолчанию UI считает по таймауту heartbeat (computed).
   — Чтобы падение процессов мгновенно отражалось, оставь агенту проверку (`REQUIRE_P2PD`, `LOG_FILE`) — агент пошлёт `reported: DOWN`, а ты увидишь причину в `meta (reason=...)`.

3. **UI недоступен извне**
   — Проверь, что uvicorn слушает `0.0.0.0`, а порт 8080 открыт в UFW/облаке.

4. **В телеграм не приходят алёрты**
   — Проверь `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` в `.env` и сетевой доступ:

```bash
curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe"
```

---

## 🔐 Безопасность

* Все heartbeat-запросы требуют `Authorization: Bearer <SHARED_SECRET>`.
* Рекомендуется HTTPS-прокси (Nginx/Caddy/Traefik) и защита UI (basic auth / allow-list IP).
* Персональные секреты на ноду — не реализованы из коробки, но легко добавить.

---

## 📜 Публичное API

* `POST /api/heartbeat`
  Headers: `Authorization: Bearer <SHARED_SECRET>`
  Body:

  ```json
  {"node_id":"...","ip":"...","meta":"...","status":"UP|DOWN"}
  ```

* `GET /api/nodes` — JSON-список нод (`computed`, `reported`, `last_seen`, `age_sec`, `meta`).

* `GET /` — HTML-таблица.

---

## 🛠️ Admin API

Все admin-запросы требуют заголовок:

```
Authorization: Bearer <ADMIN_TOKEN>
```

Удалить ноду:

```bash
curl -X POST http://<HOST>:8080/api/admin/delete \
  -H "Authorization: Bearer <ADMIN_TOKEN>" -H "Content-Type: application/json" \
  -d '{"node_id":"fsn1-gensyn-01"}'
```

Переименовать:

```bash
curl -X POST http://<HOST>:8080/api/admin/rename \
  -H "Authorization: Bearer <ADMIN_TOKEN>" -H "Content-Type: application/json" \
  -d '{"old_id":"fsn1-gensyn-01","new_id":"fsn1-gensyn-#1"}'
```

Чистка «застывших»:

```bash
curl -X POST http://<HOST>:8080/api/admin/prune \
  -H "Authorization: Bearer <ADMIN_TOKEN>" -H "Content-Type: application/json" \
  -d '{"days":14}'
# или без тела, если PRUNE_DAYS задан в .env
```

---

## 🗃️ Бэкап БД

`monitor.db` — SQLite-файл в корне:

```bash
sqlite3 monitor.db ".backup 'backup-$(date +%F).db'"
```

---

## ✅ Чек-лист запуска

1. Сервер запущен, UI открывается.
2. Порт 8080 доступен.
3. На каждой ноде активен таймер агента (`systemctl status gensyn-agent.timer`).
4. `REQUIRE_P2PD=screen`, `LOG_FILE` указывает на реальный файл, `LOG_MAX_AGE` ≥ 300.
5. Тест падения:

   * `screen -S gensyn -X quit` или убей `p2pd` → агент пошлёт `reported: DOWN`, в `meta` будет `reason=...`;
   * при пропаже heartbeat через `DOWN_THRESHOLD_SEC` в UI **computed** станет **DOWN** и придёт алёрт.

---

Лицензия: MIT
