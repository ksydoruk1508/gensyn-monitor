import os, asyncio, time, sys
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Request, HTTPException, Header, Body
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
import aiosqlite, httpx
from dotenv import load_dotenv

# ── Работа с .env (обязательный Telegram + SHARED) ────────────────────────────
ROOT = Path(__file__).resolve().parent
ENV_PATH = ROOT / ".env"

def _env(name: str, default: Optional[str] = None) -> Optional[str]:
    val = os.getenv(name)
    return val if (val is not None and val != "") else default

def _upsert_env_file(**pairs: str) -> None:
    lines = []
    if ENV_PATH.exists():
        lines = ENV_PATH.read_text(encoding="utf-8").splitlines()

    def upsert(k: str, v: str):
        nonlocal lines
        set_line = f"{k}={v}"
        for i, ln in enumerate(lines):
            if ln.startswith(f"{k}="):
                lines[i] = set_line
                break
        else:
            lines.append(set_line)

    for k, v in pairs.items():
        if v is not None:
            upsert(k, v)
    if "DOWN_THRESHOLD_SEC" not in "\n".join(lines):
        lines.append("DOWN_THRESHOLD_SEC=180")  # дефолт как и раньше

    ENV_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")

def _prompt_if_tty(prompt: str, default: Optional[str] = None) -> Optional[str]:
    try:
        if sys.stdin.isatty():
            x = input(f"{prompt}{f' [{default}]' if default else ''}: ").strip()
            return x or default
    except Exception:
        pass
    return default

def ensure_required_env(require_telegram: bool = True) -> None:
    """
    Если поднимаем вручную (TTY) и чего-то нет — зададим вопросы и запишем в .env.
    Если под systemd/не TTY — бросим понятную ошибку с шаблоном .env.
    """
    # загрузим текущее .env
    load_dotenv(dotenv_path=ENV_PATH)

    shared = _env("SHARED_SECRET")
    bot    = _env("TELEGRAM_BOT_TOKEN")
    chat   = _env("TELEGRAM_CHAT_ID")

    missing = []
    if not shared:
        missing.append("SHARED_SECRET")
    if require_telegram and not bot:
        missing.append("TELEGRAM_BOT_TOKEN")
    if require_telegram and not chat:
        missing.append("TELEGRAM_CHAT_ID")

    if not missing:
        return  # все ок

    if sys.stdin.isatty():
        print("\nНе хватает настроек. Заполним сейчас и сохраним в .env\n")
        if not shared:
            shared = _prompt_if_tty("Введите SHARED_SECRET (общий секрет для агентов)")
        if require_telegram and not bot:
            bot = _prompt_if_tty("Введите TELEGRAM_BOT_TOKEN (токен бота)")
        if require_telegram and not chat:
            chat = _prompt_if_tty("Введите TELEGRAM_CHAT_ID (ID чата/пользователя)")

        still_missing = []
        if not shared: still_missing.append("SHARED_SECRET")
        if require_telegram and not bot:  still_missing.append("TELEGRAM_BOT_TOKEN")
        if require_telegram and not chat: still_missing.append("TELEGRAM_CHAT_ID")
        if still_missing:
            raise RuntimeError(
                "Не заданы обязательные переменные: "
                + ", ".join(still_missing)
                + f"\nДобавьте их в {ENV_PATH}:\n\n"
                  "SHARED_SECRET=...\n"
                  "TELEGRAM_BOT_TOKEN=...\n"
                  "TELEGRAM_CHAT_ID=...\n"
                  "DOWN_THRESHOLD_SEC=180\n"
                  "# ADMIN_TOKEN=...\n"
            )

        # Сохраняем и подхватываем в процесс
        _upsert_env_file(SHARED_SECRET=shared, TELEGRAM_BOT_TOKEN=bot or "", TELEGRAM_CHAT_ID=chat or "")
        os.environ["SHARED_SECRET"] = shared or ""
        os.environ["TELEGRAM_BOT_TOKEN"] = bot or ""
        os.environ["TELEGRAM_CHAT_ID"] = chat or ""
        return

    # не TTY — под systemd
    sample = (
        "Пример .env:\n"
        "SHARED_SECRET=замени_на_секрет\n"
        "TELEGRAM_BOT_TOKEN=123456:ABCDEF...\n"
        "TELEGRAM_CHAT_ID=123456789\n"
        "DOWN_THRESHOLD_SEC=180\n"
        "# ADMIN_TOKEN=по_желанию\n"
    )
    raise RuntimeError(
        "Отсутствуют обязательные переменные окружения: "
        + ", ".join(missing)
        + f"\nЗадайте их в {ENV_PATH} или через EnvironmentFile в systemd.\n\n"
        + sample
    )

# ВЫЗЫВАЕМ ДО СОЗДАНИЯ ПРИЛОЖЕНИЯ
ensure_required_env(require_telegram=True)

# ── Конфиг ─────────────────────────────────────────────────────────────────────
# (после ensure_required_env значения уже гарантированно есть)
load_dotenv(dotenv_path=ENV_PATH)  # на случай, если только что записали
BOT_TOKEN  = os.getenv("TELEGRAM_BOT_TOKEN", "")
CHAT_ID    = os.getenv("TELEGRAM_CHAT_ID", "")
SHARED     = os.getenv("SHARED_SECRET", "")
THRESHOLD  = int(os.getenv("DOWN_THRESHOLD_SEC", "180"))  # сек. до статуса DOWN
SITE_TITLE = os.getenv("SITE_TITLE", "Gensyn Nodes")

# Админ-опции
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "")                 # Bearer токен админа
PRUNE_DAYS  = int(os.getenv("PRUNE_DAYS", "0"))            # 0 = не чистить

DB = "monitor.db"

# ── Приложение ────────────────────────────────────────────────────────────────
app = FastAPI()
templates = Jinja2Templates(directory="templates")

async def init_db():
    async with aiosqlite.connect(DB) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS nodes(
                node_id TEXT PRIMARY KEY,
                ip TEXT,
                last_seen INTEGER,
                last_state TEXT,      -- последнее ОПОВЕЩЁННОЕ состояние
                last_computed TEXT,   -- текущее вычисленное
                meta TEXT
            )
        """)
        await db.commit()

@app.on_event("startup")
async def startup():
    await init_db()
    asyncio.create_task(watchdog_loop())

def computed_state(last_seen: int) -> str:
    return "UP" if (int(time.time()) - int(last_seen)) <= THRESHOLD else "DOWN"

async def send_tg(text: str):
    async with httpx.AsyncClient(timeout=10) as c:
        await c.post(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            data={"chat_id": CHAT_ID, "parse_mode": "Markdown", "text": text}
        )

async def upsert(node_id: str, ip: str, meta: str | None):
    now = int(time.time())
    async with aiosqlite.connect(DB) as db:
        await db.execute("""
            INSERT INTO nodes(node_id,ip,last_seen,last_state,last_computed,meta)
            VALUES(?, ?, ?, 'DOWN','UP', ?)
            ON CONFLICT(node_id) DO UPDATE
              SET ip=excluded.ip, last_seen=excluded.last_seen, meta=excluded.meta
        """, (node_id, ip, now, meta))
        await db.commit()

async def list_nodes():
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall("SELECT * FROM nodes ORDER BY node_id")
        now = int(time.time())
        out = []
        for r in rows:
            st = computed_state(r["last_seen"])
            out.append({
                "node_id": r["node_id"],
                "ip": r["ip"],
                "last_seen": r["last_seen"],
                "computed": st,
                "last_state": r["last_state"],
                "meta": r["meta"],
                "age_sec": max(0, now - int(r["last_seen"]))
            })
        return out

async def update_and_alert():
    nodes = await list_nodes()
    async with aiosqlite.connect(DB) as db:
        for n in nodes:
            if n["computed"] != n["last_state"]:
                mark = "✅" if n["computed"] == "UP" else "❌"
                ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
                txt = (
                    f"{mark} *Gensyn node {n['computed']}*\n"
                    f"Node ID: `{n['node_id']}`\nIP: `{n['ip'] or ''}`\n"
                    f"Age: `{n['age_sec']}s`\nTime: `{ts}`"
                )
                try:
                    await send_tg(txt)
                except Exception:
                    pass
                await db.execute(
                    "UPDATE nodes SET last_state=?, last_computed=? WHERE node_id=?",
                    (n["computed"], n["computed"], n["node_id"])
                )
        await db.commit()

async def watchdog_loop():
    while True:
        try:
            await update_and_alert()
        except Exception:
            pass
        await asyncio.sleep(60)

def auth_ok(h: str | None) -> bool:
    if not h:
        return False
    p = h.split()
    return len(p) == 2 and p[0].lower() == "bearer" and p[1] == SHARED

def admin_ok(h: str | None) -> bool:
    if not ADMIN_TOKEN:
        return False
    if not h:
        return False
    p = h.split()
    return len(p) == 2 and p[0].lower() == "bearer" and p[1] == ADMIN_TOKEN

# ── Публичное API ─────────────────────────────────────────────────────────────
@app.post("/api/heartbeat")
async def heartbeat(req: Request, authorization: str | None = Header(default=None)):
    if not auth_ok(authorization):
        raise HTTPException(401, "Unauthorized")
    data = await req.json()
    node_id = str(data.get("node_id", "")).strip()
    if not node_id:
        raise HTTPException(400, "node_id required")
    ip = str(data.get("ip", "")).strip()
    meta = str(data.get("meta", "")) if data.get("meta") else None
    await upsert(node_id, ip, meta)
    return {"ok": True}

@app.get("/api/nodes")
async def api_nodes():
    return JSONResponse(await list_nodes())

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(
        "index.html",
        {"request": request, "site_title": SITE_TITLE, "threshold": THRESHOLD}
    )

# ── Админ-API ─────────────────────────────────────────────────────────────────
@app.post("/api/admin/rename")
async def admin_rename(
    authorization: str | None = Header(default=None),
    old_id: str = Body(...),
    new_id: str = Body(...)
):
    if not admin_ok(authorization):
        raise HTTPException(401, "Unauthorized")
    old_id = (old_id or "").strip()
    new_id = (new_id or "").strip()
    if not old_id or not new_id:
        raise HTTPException(400, "old_id/new_id required")
    if old_id == new_id:
        return {"ok": True, "renamed": False}

    async with aiosqlite.connect(DB) as db:
        cur = await db.execute("SELECT 1 FROM nodes WHERE node_id=?", (new_id,))
        exists = await cur.fetchone()
        if exists:
            raise HTTPException(409, "new_id already exists")
        await db.execute("UPDATE nodes SET node_id=? WHERE node_id=?", (new_id, old_id))
        await db.commit()
    return {"ok": True, "renamed": True, "old_id": old_id, "new_id": new_id}

@app.post("/api/admin/delete")
async def admin_delete(
    authorization: str | None = Header(default=None),
    node_id: str = Body(..., embed=True)
):
    if not admin_ok(authorization):
        raise HTTPException(401, "Unauthorized")
    node_id = (node_id or "").strip()
    if not node_id:
        raise HTTPException(400, "node_id required")
    async with aiosqlite.connect(DB) as db:
        await db.execute("DELETE FROM nodes WHERE node_id=?", (node_id,))
        await db.commit()
    return {"ok": True, "deleted": node_id}

@app.post("/api/admin/prune")
async def admin_prune(
    authorization: str | None = Header(default=None),
    days: int | None = Body(default=None)
):
    if not admin_ok(authorization):
        raise HTTPException(401, "Unauthorized")
    cutoff_days = days if (days is not None) else PRUNE_DAYS
    if not cutoff_days or cutoff_days <= 0:
        return {"ok": True, "deleted": 0, "skipped": True}

    cutoff_ts = int(time.time()) - cutoff_days * 86400
    async with aiosqlite.connect(DB) as db:
        cur = await db.execute("SELECT COUNT(*) FROM nodes WHERE last_seen < ?", (cutoff_ts,))
        (cnt_before,) = await cur.fetchone()
        await db.execute("DELETE FROM nodes WHERE last_seen < ?", (cutoff_ts,))
        await db.commit()
    return {"ok": True, "deleted": int(cnt_before), "cutoff_days": cutoff_days}
