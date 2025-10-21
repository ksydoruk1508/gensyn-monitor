# Gensyn Monitor

Централизованный мониторинг нод RL-Swarm (Gensyn): лёгкий агент на каждом сервере шлёт heartbeat на центральный сервер (FastAPI + SQLite). Сервер показывает таблицу статусов и шлёт алёрты в Telegram при смене состояния (UP ↔ DOWN).

---

## 📦 Состав

- `app.py` — API/веб/логика оповещений и админ-эндпоинты.
- `templates/index.html` — простая таблица статусов (автообновление каждые 10s).
- `agents/linux/gensyn_agent.sh` — агент для Linux (работает с `systemd` таймером).
- `agents/linux/gensyn-agent.service` и `agents/linux/gensyn-agent.timer` — юниты агента.
- `agents/windows/gensyn_agent.ps1` — агент для Windows (Task Scheduler).
- `requirements.txt` — зависимости.
- `.env` — переменные окружения **сервера** (создайте и заполните сами).

---

## 🔧 Установка (сервер)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Создайте `.env` в корне (пример):

```ini
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=123456789
SHARED_SECRET=super-long-random-secret
DOWN_THRESHOLD_SEC=180
SITE_TITLE=Gensyn Nodes

# Админ-доступ к management API:
ADMIN_TOKEN=change-me-admin-token
# (опц.) авто-чистка старых записей через admin/prune без указания days
PRUNE_DAYS=0
```

Запуск (Linux/macOS):

```bash
uvicorn app:app --host 0.0.0.0 --port 8080 --reload
# откройте http://localhost:8080/
```

Запуск (Windows PowerShell / VS Code):

```powershell
.\.venv\Scripts\Activate.ps1
uvicorn app:app --host 0.0.0.0 --port 8080 --reload
# откройте http://localhost:8080/
```

> Если заходите с другого компьютера — используйте публичный IP: `http://<PUBLIC_IP>:8080/` и убедитесь, что порт 8080 открыт в фаерволе/облачных правилах.

---

## 🖥️ Установка **systemd-сервиса** для сервера (Linux, опционально)

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

## 🖥️ Установка агента на Linux

1. Установить скрипт:

```bash
sudo install -m0755 agents/linux/gensyn_agent.sh /usr/local/bin/gensyn_agent.sh
```

2. Настроить `systemd`:

```bash
sudo cp agents/linux/gensyn-agent.service /etc/systemd/system/
sudo cp agents/linux/gensyn-agent.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gensyn-agent.timer
```

3. Задать переменные (выберите один вариант):

* **A)** редактировать `gensyn-agent.service` (строки `Environment=…`)
* **B)** создать `/etc/gensyn-agent.env` (подхватится скриптом автоматически):

```bash
sudo tee /etc/gensyn-agent.env >/dev/null <<EOF
SERVER_URL=http://<MONITOR_HOST>:8080
SHARED_SECRET=super-long-random-secret
NODE_ID=my-gensyn-01
META=hetzner-fsn1
SCREEN_NAME=gensyn
CHECK_PORT=true
PORT=3000
EOF
```

4. Проверка:

```bash
systemctl status gensyn-agent.timer
journalctl -u gensyn-agent.service --no-pager -n 50
```

> IPv4 вместо IPv6 в колонке IP: в агенте измените функцию `public_ip` на `curl -4` **или** задайте `IP_CMD=https://ipv4.icanhazip.com` в `/etc/gensyn-agent.env`.

---

## 🪟 Установка агента на Windows

1. Поместите `agents/windows/gensyn_agent.ps1` → `C:\gensyn\gensyn_agent.ps1`.

2. Создайте задачу Планировщика (раз в минуту):

```bat
schtasks /Create /TN "GensynHeartbeat" /SC MINUTE /MO 1 /F ^
  /TR "powershell.exe -ExecutionPolicy Bypass -File C:\gensyn\gensyn_agent.ps1" ^
  /RU SYSTEM
```

3. Переменные окружения (через System Properties → Environment Variables) **или** задайте в задаче:

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

## 🧪 Быстрые проверки

На сервере:

```bash
curl -I http://127.0.0.1:8080/
curl    http://127.0.0.1:8080/api/nodes
```

С агента (Linux, разовый запрос):

```bash
SERVER_URL=http://<MONITOR_HOST>:8080 SHARED_SECRET=... NODE_ID=test \
/usr/local/bin/gensyn_agent.sh
```

---

## 🔐 Безопасность

* Все heartbeat’ы требуют заголовок `Authorization: Bearer <SHARED_SECRET>`.
* Для продакшена: HTTPS-reverse-proxy (Nginx/Caddy/Traefik) и защита UI (basic auth/ограничение по IP).
* При необходимости — **персональные секреты** на ноду (не реализованы из коробки, но легко добавить).

---

## ⚙️ Как определяется «здоровье» ноды

**Linux-агент** проверяет:

* `screen`-сессию с именем `gensyn` (`SCREEN_NAME` настраивается),
* процессы `run_rl_swarm.sh | rl-swarm | python.*rl-swarm`,
* (опц.) доступность `127.0.0.1:3000` (`CHECK_PORT=true`).

**Windows-агент**:

* процессы `run_rl_swarm.sh | rl-swarm | python.*rl-swarm`,
* (опц.) порт `3000`.

Сервер считает ноду **DOWN**, если `last_seen` старше `DOWN_THRESHOLD_SEC`. При переходах UP ↔ DOWN отправляется Telegram-оповещение.

---

## 🧰 Типичные проблемы

1. **Открываю `http://0.0.0.0:8080` — не работает**
   Используйте `http://localhost:8080` или `http://<PUBLIC_IP>:8080`.

2. **Снаружи не открывается `:8080`**
   Откройте порт в UFW/Windows Firewall/облачном фаерволе. Проверьте, что uvicorn слушает `0.0.0.0`:

   ```bash
   ss -ltnp | grep :8080        # Linux
   netstat -ano | findstr :8080 # Windows
   ```

3. **Телеграм-алёрты не приходят**
   Проверьте `.env` (TOKEN/CHAT_ID), а также сетевой доступ:

   ```bash
   curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe"
   ```

---

## 🗃️ Резервные копии

Вся БД — файл `monitor.db` в корне:

```bash
sqlite3 monitor.db ".backup 'backup-$(date +%F).db'"
```

---

## 📜 Публичное API

* `POST /api/heartbeat`
  Headers: `Authorization: Bearer <SHARED_SECRET>`
  Body JSON: `{"node_id": "...", "ip": "...", "meta": "...", "status": "UP|DOWN"}`
  Ответ: `{"ok": true}`

* `GET /api/nodes` → JSON список нод со статусом, временем, возрастом.

* `GET /` → HTML-таблица.

---

## 🛠️ Admin API (переименование/удаление/чистка)

Требуется `ADMIN_TOKEN` в `.env`. Передавайте в заголовке:

```
Authorization: Bearer <ADMIN_TOKEN>
```

### Удалить ноду

Если в `app.py` эндпоинт объявлен с `node_id: str = Body(..., embed=True)` (так в текущей версии):

```bash
TOKEN=<ADMIN_TOKEN>
curl -X POST http://<HOST>:8080/api/admin/delete \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"node_id":"fsn1-gensyn-01"}'
# {"ok": true, "deleted": "fsn1-gensyn-01"}
```

> Если у вас старая версия без `embed=True`, то эндпоинт принимает **сырую строку**:
> `--data-raw '"fsn1-gensyn-01"'`

### Переименовать ноду

```bash
curl -X POST http://<HOST>:8080/api/admin/rename \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"old_id":"fsn1-gensyn-01","new_id":"fsn1-gensyn-#1"}'
# {"ok": true, "renamed": true, "old_id": "...", "new_id": "..."}
```

> **Важно:** если агент продолжит слать heartbeat со старым `NODE_ID`, запись появится снова. Обновите `/etc/gensyn-agent.env` на ноде и перезапустите агент.

### Очистка «застывших» записей

```bash
# разовая чистка записей старше N дней
curl -X POST http://<HOST>:8080/api/admin/prune \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"days":14}'
# или без тела, если PRUNE_DAYS задан в .env
```

---

## 🧩 Кастомизация

* Меняйте `SCREEN_NAME`, `CHECK_PORT`, `PORT` в агенте.
* Интервал таймера в `gensyn-agent.timer` (по умолчанию 60s).
* Порог DOWN в `.env`: `DOWN_THRESHOLD_SEC`.
* Заголовок страницы в `.env`: `SITE_TITLE`.

---

## ✅ Чек-лист запуска

1. Сервер запущен, UI открывается локально.
2. Порт 8080 открыт/проксирован.
3. На каждой ноде активен агент (Linux timer / Windows task).
4. Тест падения: `screen -S gensyn -X quit` → через `DOWN_THRESHOLD_SEC` в UI **DOWN** и в Telegram придёт ❌; поднимите ноду — придёт ✅.

---

Лицензия: MIT
