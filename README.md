# Gensyn Monitor

Централизованный мониторинг нод RL‑Swarm (Gensyn). Лёгкий агент на каждом сервере отправляет heartbeat на центральное FastAPI‑приложение (SQLite в качестве хранилища). Монитор показывает статус всех узлов, собирает статистику G‑Swarm (wins / rewards / rank), умеет отправлять алёрты и HTML-отчёты в Telegram.

---

## ⭐ Основные возможности

- Приём heartbeat от произвольного числа нод, сохранение IP, таймстемпов и произвольного `meta`.
- Автоматический расчёт статуса (`UP` / `DOWN`) и оповещение о его смене в Telegram.
- Интеграция с G‑Swarm: сбор on-chain и off-chain данных, хранение истории, генерация отчётов, diff wins/rewards.
- Веб-дашборд с автообновлением, раскрывающимися карточками по каждому узлу, тёмной темой и кнопкой ручного обновления.
- CLI-менеджер, который разворачивает монитор и агента, обновляет, удаляет и показывает логи.
- Настройка через `.env` и (опционально) `GSWARM_NODE_MAP`, чтобы привязать узлы без установки агента.

---

## 📦 Состав репозитория

- `app.py` — основное FastAPI-приложение (API, веб-интерфейс, фоновые задания, admin-эндпоинты).
- `templates/index.html` — дашборд (таблица, раскрывающиеся карточки G‑Swarm, кнопки Refresh/Dark mode).
- `integrations/gswarm_checker.py` — сбор on-chain/off-chain статистики G‑Swarm и подготовка HTML-отчётов.
- `agents/linux/gensyn_agent.sh` — heartbeat‑агент под Linux (systemd service + timer).
- `agents/linux/gensyn-agent.service` / `agents/linux/gensyn-agent.timer` — юниты для systemd.
- `agents/windows/gensyn_agent.ps1` — агент под Windows (Task Scheduler).
- `tools/gensyn_manager.sh` — интерактивный менеджер: готовит сервер, ставит/обновляет монитор и агента, показывает логи.
- `requirements.txt` — зависимости Python.
- `.env` / `example.env` — пример и рабочий набор переменных окружения.
- `monitor.db` — SQLite база с данными по узлам и G‑Swarm.

---

## 🧠 Как это работает

### 1. Агент на ноде

- Раз в минуту (systemd timer) проверяет `screen`‑сессию (`SCREEN_NAME`, по умолчанию `gensyn`).
- Считает узел живым, только если внутри этой `screen` найден процесс лаунчера (`ALLOW_REGEX`), p2pd (`REQUIRE_P2PD=screen`) и свежий лог (`LOG_FILE` + `LOG_MAX_AGE`).
- При необходимости проверяет открытый порт (`127.0.0.1:PORT`).
- Отправляет `POST /api/heartbeat` с полями:
  - `node_id`, `status` (`UP`/`DOWN`), `meta`, `ip`;
  - `gswarm_eoa` и `gswarm_peer_ids` (если настроены) — для G‑Swarm.
- В `meta` при падении кладёт причину `reason=...` (например, `no_screen`, `no_proc`, `log_stale`).

### 2. Сервер мониторинга

- Сохраняет данные в SQLite (`monitor.db`), считает «возраст» последнего heartbeat и вычисляет `computed`‑статус.
- Рассылает Telegram-уведомления при смене `computed` состояния (UP ↔ DOWN).
- Фоновая задача `gswarm_loop()` (раз в `GSWARM_REFRESH_INTERVAL`) запускает `run_once()`:
  - собирает peers через смарт-контракты и off-chain API (`GSWARM_TGID`),
  - сохраняет статистику (`gswarm_stats`, `gswarm_updated`, `gswarm_peer_ids`),
  - при `GSWARM_AUTO_SEND=1` отправляет HTML-отчёт в Telegram.
- Эндпоинт `/api/gswarm/check` позволяет форсировать сбор статистики (и по желанию отправить отчёт).

### 3. Дашборд

- Таблица с колонками: `Node ID`, `IP`, `Статус`, `Последний heartbeat`, `Возраст`, `G‑Swarm`, `Meta`.
- Кнопки в панели:
  - «Порог переключения» показывает `DOWN_THRESHOLD_SEC`.
  - «Обновить» вручную перезапрашивает `/api/nodes`.
  - «Dark mode» сохраняет выбранную тему в `localStorage`.
- Щёлкните по строке, чтобы раскрыть карточку G‑Swarm:
  - список peers с wins/rewards/rank,
  - предупреждения о пропавших peers,
  - EOA и время последней проверки.
- Автообновление каждые 10 секунд (без кэширования).

---

## 🚀 Быстрый старт (сервер)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Создайте `.env` (пример):

```ini
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=123456789

SHARED_SECRET=super-long-random-secret   # ключ для агентов
DOWN_THRESHOLD_SEC=180                   # таймаут без heartbeat
SITE_TITLE=Gensyn Nodes                  # заголовок страницы

ADMIN_TOKEN=change-me-admin-token        # для /api/admin/*
PRUNE_DAYS=0                             # автопрочистка (0 = выкл)

# --- G-SWARM ---
GSWARM_ETH_RPC_URL=https://gensyn-testnet.g.alchemy.com/public
GSWARM_EOAS=0x...,0x...                  # список EOA, можно пусто
GSWARM_PROXIES=0xFaD7...,0x7745...,0x69C6...
GSWARM_TGID=123456789                    # Telegram ID для off-chain API
GSWARM_REFRESH_INTERVAL=600              # сек между обновлениями
GSWARM_SHOW_PROBLEMS=1                   # показать блок "Problems"
GSWARM_SHOW_SRC=auto                     # подписи источников wins/rewards
GSWARM_AUTO_SEND=0                       # 1 = фоновые отчёты в Telegram
GSWARM_NODE_MAP={"node-1":{"eoa":"0x...","peer_ids":["Qm..."]}}
```

Запуск (локально):

```bash
uvicorn app:app --host 0.0.0.0 --port 8080
# Открой http://localhost:8080/
```

Для продакшена рекомендуем systemd unit (см. пример из предыдущей версии README). Не забудьте открыть порт в фаерволе.

---

## 🧰 Интерактивный менеджер (`tools/gensyn_manager.sh`)

```bash
sudo tools/gensyn_manager.sh
```

Меню:

1. Подготовить устройство (apt install python/git/sqlite3/curl/jq, dos2unix).
2. Установить мониторинг (вопросы по .env → venv → `pip install` → systemd).
3. Обновить мониторинг (git pull + зависимости + restart).
4. Установить агента (Linux): создаёт `/etc/gensyn-agent.env`, ставит systemd service/timer, вызывает `/api/gswarm/check`.
5. Переустановить агента с сохранением предыдущих значений.
6. Показать `/etc/gensyn-agent.env`.
7–8. Статус/логи монитора.
9–10. Статус/логи агента.
11–12. Удалить мониторинг / удалить агента.

Скрипт автоматически приводит файлы к UNIX-окончаниям, чтобы не ловить `/usr/bin/env: ‘bash\r’`.

---

## 🖥️ Установка агента вручную (Linux)

1. Скопируйте скрипт:

```bash
sudo install -m0755 agents/linux/gensyn_agent.sh /usr/local/bin/gensyn_agent.sh
```

2. Установите юниты:

```bash
sudo cp agents/linux/gensyn-agent.service /etc/systemd/system/
sudo cp agents/linux/gensyn-agent.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gensyn-agent.timer
```

3. Настройте `/etc/gensyn-agent.env`:

```ini
SERVER_URL=http://monitor.example.com:8080
SHARED_SECRET=super-long-random-secret

NODE_ID=my-gensyn-01
META=hetzner-fsn1

SCREEN_NAME=gensyn
CHECK_PORT=true
PORT=3000

PROC_FALLBACK_WITHOUT_SCREEN=false
REQUIRE_P2PD=screen

LOG_FILE=/root/rl-swarm/logs/swarm_launcher.log
LOG_MAX_AGE=300

GSWARM_EOA=0x1234...
GSWARM_PEER_IDS=            # можно оставить пустым
DASH_URL=https://monitor.example.com/node/my-gensyn-01

ALLOW_REGEX='python[[:space:]]*-m[[:space:]]*rgym_exp\.runner\.swarm_launcher'
DENY_REGEX='run_rl_swarm\.sh|while[[:space:]]+true|sleep[[:space:]]+60|bash[[:space:]]-c.*while[[:space:]]+true'
```

Проверка:

```bash
systemctl status gensyn-agent.timer
journalctl -u gensyn-agent.service -n 50 --no-pager
# ручной прогон
bash -x /usr/local/bin/gensyn_agent.sh |& tail -n 80
```

> IPv4 вместо IPv6: положите `IP_CMD=https://ipv4.icanhazip.com` в `/etc/gensyn-agent.env`.

### Windows

Скопируйте `agents/windows/gensyn_agent.ps1`, создайте задачу в Планировщике (раз в минуту от имени SYSTEM), задайте переменные `SERVER_URL`, `SHARED_SECRET`, `NODE_ID`, `META`, `CHECK_PORT`, `PORT`. Проверка:

```powershell
powershell -ExecutionPolicy Bypass -File C:\gensyn\gensyn_agent.ps1
```

---

## 🧪 Диагностика

- Имя screen:
  ```bash
  screen -ls | sed -nE "s/^[[:space:]]*([0-9]+\.${SCREEN_NAME:-gensyn})[[:space:]].*/\1/p" | head -n1
  ```
- Убедиться, что процессы внутри нужной screen:
  ```bash
  for RX in 'rgym_exp\.runner\.swarm_launcher' 'hivemind_cli/p2pd'; do
    echo "== $RX =="; for pid in $(pgrep -f "$RX"); do
      tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep -qx "STY=$SCREEN_NAME" && ps -p "$pid" -o pid=,args=
    done
  done
  ```
- Свежесть лога:
  ```bash
  stat -c '%Y %n' /root/rl-swarm/logs/swarm_launcher.log
  date +%s
  ```
- Проверка порта:
  ```bash
  ss -ltnp | grep :3000 || nc -zv 127.0.0.1 3000
  ```

---

## ❗ Типичные проблемы

1. **Агент всегда UP** — установите последнюю версию `gensyn_agent.sh`, проверьте `REQUIRE_P2PD=screen`, `LOG_FILE`, `LOG_MAX_AGE`, убедитесь, что процессы живут в правильной `screen`.
2. **DOWN с задержкой** — вычисление `computed` идёт по таймауту. Чтобы видеть моментальные падения, полагайтесь на `reported: DOWN` от агента и причину в `meta`. В UI отобразится сразу.
3. **UI недоступен** — проверьте, что uvicorn слушает `0.0.0.0`, а порт проброшен в UFW/облаке.
4. **Нет сообщений в Telegram** — убедитесь, что `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` верные, токен работает:
   ```bash
   curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe"
   ```
5. **Пустая колонка G‑Swarm** — не передан `GSWARM_EOA` и не заполнен `GSWARM_NODE_MAP`. Посмотрите лог сервиса: `[GSWARM] refresh: nothing to do`. Запустите вручную:
   ```bash
   curl -X POST "http://127.0.0.1:8080/api/gswarm/check?include_nodes=true&send=false"
   ```

---

## 🔐 Безопасность

- Все heartbeat-запросы требуют `Authorization: Bearer <SHARED_SECRET>`.
- Рекомендуется ставить HTTPS-прокси (Nginx/Traefik/Caddy) и ограничивать доступ к UI (basic auth / allow-list).
- `ADMIN_TOKEN` держите отдельно, используйте только на доверенных хостах.

---

## 📡 API

- `POST /api/heartbeat` — приём heartbeat (Bearer `SHARED_SECRET`):
  ```json
  {
    "node_id": "my-gensyn-01",
    "ip": "00.00.00.220",
    "meta": "hetzner",
    "status": "UP",
    "gswarm_eoa": "0x1234...",
    "gswarm_peer_ids": ["Qm..."]
  }
  ```
- `GET /api/nodes` — JSON со всеми узлами, текущими статусами и G‑Swarm блоками.
- `POST /api/gswarm/check?include_nodes=true&send=false` — ручной сбор статистики (при `send=true` HTML-отчёт уйдёт в Telegram).
- `GET /` — HTML-дашборд.

### Admin API (Bearer `ADMIN_TOKEN`)

- `POST /api/admin/delete` — удалить узел.
- `POST /api/admin/rename` — переименовать узел.
- `POST /api/admin/prune` — удалить узлы старше `days` (использует `PRUNE_DAYS`, если тело пустое).

---

## 🗃️ Бэкап базы

```bash
sqlite3 monitor.db ".backup 'backup-$(date +%F).db'"
```

---

## ✅ Чек-лист перед запуском

1. `.env` заполнен, лишних комментариев в значениях нет.
2. `TELEGRAM_*`, `SHARED_SECRET`, `ADMIN_TOKEN` корректные, боту доступен интернет.
3. Монитор запущен (`systemctl status gensyn-monitor.service`), порт открыт.
4. На каждой ноде активен таймер агента (`systemctl status gensyn-agent.timer`).
5. `GSWARM_EOA` задан (или `GSWARM_NODE_MAP` описывает peers), `GSWARM_REFRESH_INTERVAL` ≥ 60.
6. Ручной тест:
   - отправьте `status":"UP"` и затем `status":"DOWN"` — в Telegram придёт алёрт;
   - вызовите `/api/gswarm/check?include_nodes=true&send=true` — убедитесь, что отчёт отправился.

---

Лицензия: MIT

