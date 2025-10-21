# Gensyn Monitor

Централизованный мониторинг нод RL-Swarm (Gensyn): лёгкий агент на каждом сервере шлёт heartbeat на центральный сервер (FastAPI + SQLite). Сервер показывает таблицу статусов и шлёт алёрты в Telegram при смене состояния (UP ↔ DOWN).

---

## 📦 Состав

- `app.py` — API/веб/логика оповещений.
- `templates/index.html` — простая таблица статусов (автообновление каждые 10s).
- `agents/linux/gensyn_agent.sh` — агент для Linux (работает с `systemd` таймером).
- `agents/linux/gensyn-agent.service` и `agents/linux/gensyn-agent.timer` — юниты.
- `agents/windows/gensyn_agent.ps1` — агент для Windows (Task Scheduler).
- `requirements.txt` — зависимости.
- `.env` — переменные окружения сервера (создайте и заполните сами).

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

> Если заходите с другого компьютера — используйте публичный IP: `http://<PUBLIC_IP>:8080/`, убедитесь что порт 8080 открыт в фаерволе/облачных правилах.

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

3. Задать переменные:

* Вариант А — редактировать `gensyn-agent.service` (Environment=…)
* Вариант Б — создать `/etc/gensyn-agent.env`:

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

  (Файл автоматически подхватится агентом при запуске.)

4. Проверка:

```bash
systemctl status gensyn-agent.timer
journalctl -u gensyn-agent.service --no-pager -n 50
```

---

## 🪟 Установка агента на Windows

1. Поместите `agents/windows/gensyn_agent.ps1` в `C:\gensyn\gensyn_agent.ps1`.

2. Создайте задачу Планировщика (раз в минуту):

```bat
schtasks /Create /TN "GensynHeartbeat" /SC MINUTE /MO 1 /F ^
  /TR "powershell.exe -ExecutionPolicy Bypass -File C:\gensyn\gensyn_agent.ps1" ^
  /RU SYSTEM
```

3. Переменные окружения (через System Properties → Environment Variables) **или** задайте в самой задаче:

```
SERVER_URL=http://<MONITOR_HOST>:8080
SHARED_SECRET=super-long-random-secret
NODE_ID=win-gensyn-01
META=dc=home-lab
CHECK_PORT=true
PORT=3000
```

Проверка:

* Запустить скрипт вручную (PowerShell → Run as Administrator):

  ```powershell
  powershell -ExecutionPolicy Bypass -File C:\gensyn\gensyn_agent.ps1
  ```

---

## 🧪 Быстрые проверки

* На сервере:

  ```bash
  curl -I http://127.0.0.1:8080/
  curl    http://127.0.0.1:8080/api/nodes
  ```
* С агента (Linux):

  ```bash
  SERVER_URL=http://<MONITOR_HOST>:8080 SHARED_SECRET=... NODE_ID=test \
  /usr/local/bin/gensyn_agent.sh
  ```

---

## 🔐 Безопасность

* Все heartbeat’ы требуют заголовок `Authorization: Bearer <SHARED_SECRET>`.
* Рекомендуется поставить HTTPS-reverse-proxy (Nginx/Caddy/Traefik) и защитить UI (basic auth или ограничение по IP).
* Можно расширить схему на **персональные секреты** на каждую ноду (добавить таблицу токенов и сверять их).

---

## ⚙️ Как определяется «здоровье» ноды

Linux-агент:

* Наличие `screen`-сессии с именем `gensyn` (переопределяется `SCREEN_NAME`).
* Наличие процесса `run_rl_swarm.sh | rl-swarm | python.*rl-swarm`.
* (Опционально) Доступность локального порта UI (`127.0.0.1:3000`), выключается `CHECK_PORT=false`.

Windows-агент:

* Поиск процесса `run_rl_swarm.sh | rl-swarm | python.*rl-swarm`.
* (Опционально) Проверка порта 3000.

Сервер считает ноду **DOWN**, если последний heartbeat старше `DOWN_THRESHOLD_SEC` (по умолчанию 180s). При смене состояния отправляется Telegram-сообщение.

---

## 🧰 Три типичные проблемы и решения

1. **Открываю `http://0.0.0.0:8080` — не работает**
   `0.0.0.0` — адрес привязки. Используйте `http://localhost:8080` на этой машине, либо `http://<PUBLIC_IP>:8080` извне.

2. **Снаружи не открывается `:8080`**
   Проверьте:

   * UFW / Windows Firewall (разрешить TCP/8080).
   * Облачный firewall (Hetzner/AWS/GCP).
   * Что uvicorn слушает `0.0.0.0`:

     ```bash
     ss -ltnp | grep :8080   # Linux
     netstat -ano | findstr :8080  # Windows
     ```

3. **Телеграм-алёрты не приходят**

   * Проверьте токен/CHAT_ID в `.env`.
   * На сервере:

     ```bash
     curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe"
     ```

---

## 🗃️ Резервные копии

Вся БД — файл `monitor.db` в корне. Достаточно периодически копировать:

```bash
sqlite3 monitor.db ".backup 'backup-$(date +%F).db'"
```

---

## 🔌 Рекомендации продакшн-развёртывания

* Reverse-proxy с HTTPS (Caddy/Nginx), rate-limit на `/api/heartbeat`.
* systemd-сервис для uvicorn (Linux) или NSSM-сервис (Windows).
* Мониторинг процесса uvicorn (systemd Restart=always / Windows Service Recovery).
* Логи Telegram-ошибок уводить в файл/journal при необходимости.

---

## 📜 API

* `POST /api/heartbeat`
  Headers: `Authorization: Bearer <SHARED_SECRET>`
  Body JSON: `{"node_id": "...", "ip": "...", "meta": "...", "status": "UP|DOWN"}`
  Ответ: `{"ok": true}`

* `GET /api/nodes` → JSON список нод со статусом, временем, возрастом.

* `GET /` → HTML-таблица.

---

## 🧩 Кастомизация

* Переименуйте `SCREEN_NAME`, измените `PORT`, отключите `CHECK_PORT`.
* Меняйте интервал таймера в `gensyn-agent.timer` (по умолчанию 60s).
* Правьте порог `DOWN_THRESHOLD_SEC` в `.env`.

---

## ✅ Чек-лист запуска

1. Сервер запущен, UI доступен локально.
2. Порт 8080 открыт (или настроен reverse-proxy).
3. На каждой ноде установлен и активен агент (Linux timer / Windows task).
4. Проверка падения: остановите `screen gensyn` → через ~3 мин статус **DOWN** и прилетит Telegram-алёрт.

---

Лицензия: MIT.
