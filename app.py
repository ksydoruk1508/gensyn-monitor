from typing import Optional
import os, asyncio, time
from fastapi import FastAPI, Request, HTTPException, Header, Body
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
import aiosqlite, httpx
from dotenv import load_dotenv

# ── Конфиг ─────────────────────────────────────────────────────────────────────
load_dotenv()
BOT_TOKEN  = os.getenv("TELEGRAM_BOT_TOKEN", "")
CHAT_ID    = os.getenv("TELEGRAM_CHAT_ID", "")
SHARED     = os.getenv("SHARED_SECRET", "")
THRESHOLD  = int(os.getenv("DOWN_THRESHOLD_SEC", "180"))  # сек. до статуса DOWN
SITE_TITLE = os.getenv("SITE_TITLE", "Gensyn Nodes")

# Админ-опции
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "")                 # Bearer токен админа
PRUNE_DAYS  = int(os.getenv("PRUNE_DAYS", "0"))            # 0 = не чистить

if not (BOT_TOKEN and CHAT_ID and SHARED):
    raise RuntimeError("Set TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SHARED_SECRET in .env")

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
        # миграция: добавить last_reported, если его нет
        try:
            await db.execute("ALTER TABLE nodes ADD COLUMN last_reported TEXT DEFAULT 'UP'")
        except Exception:
            pass  # колонка уже существует
        await db.commit()

@app.on_event("startup")
async def startup():
    await init_db()
    asyncio.create_task(watchdog_loop())

def fresh_since(last_seen: int) -> bool:
    return (int(time.time()) - int(last_seen)) <= THRESHOLD

async def send_tg(text: str):
    async with httpx.AsyncClient(timeout=10) as c:
        await c.post(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            data={"chat_id": CHAT_ID, "parse_mode": "Markdown", "text": text}
        )

async def upsert(node_id: str, ip: str, meta: Optional[str], reported: str):
    """
    reported — статус, присланный агентом: 'UP' | 'DOWN' (валидируем в handler’е).
    """
    now = int(time.time())
    async with aiosqlite.connect(DB) as db:
        await db.execute("""
            INSERT INTO nodes(node_id,ip,last_seen,last_state,last_computed,meta,last_reported)
            VALUES(?, ?, ?, 'DOWN','UP', ?, ?)
            ON CONFLICT(node_id) DO UPDATE
              SET ip=excluded.ip,
                  last_seen=excluded.last_seen,
                  meta=excluded.meta,
                  last_reported=excluded.last_reported
        """, (node_id, ip, now, meta, reported))
        await db.commit()

async def list_nodes():
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall("SELECT * FROM nodes ORDER BY node_id")
        now = int(time.time())
        out = []
        for r in rows:
            is_fresh = fresh_since(r["last_seen"])
            reported = (r["last_reported"] or "DOWN").upper() if "last_reported" in r.keys() else "UP"
            computed = "UP" if (is_fresh and reported == "UP") else "DOWN"
            out.append({
                "node_id": r["node_id"],
                "ip": r["ip"],
                "last_seen": r["last_seen"],
                "computed": computed,
                "last_state": r["last_state"],
                "meta": r["meta"],
                "age_sec": max(0, now - int(r["last_seen"])),
                "reported": reported
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

def auth_ok(h: Optional[str]) -> bool:
    if not h:
        return False
    p = h.split()
    return len(p) == 2 and p[0].lower() == "bearer" and p[1] == SHARED

def admin_ok(h: Optional[str]) -> bool:
    if not ADMIN_TOKEN:
        return False
    if not h:
        return False
    p = h.split()
    return len(p) == 2 and p[0].lower() == "bearer" and p[1] == ADMIN_TOKEN

# ── Публичное API ─────────────────────────────────────────────────────────────
@app.post("/api/heartbeat")
async def heartbeat(req: Request, authorization: Optional[str] = Header(default=None)):
    if not auth_ok(authorization):
        raise HTTPException(401, "Unauthorized")
    data = await req.json()
    node_id = str(data.get("node_id", "")).strip()
    if not node_id:
        raise HTTPException(400, "node_id required")
    ip = str(data.get("ip", "")).strip()
    meta = str(data.get("meta", "")) if data.get("meta") else None
    reported = str(data.get("status", "UP")).strip().upper()
    if reported not in ("UP", "DOWN"):
        reported = "DOWN"
    await upsert(node_id, ip, meta, reported)
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
    authorization: Optional[str] = Header(default=None),
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
    authorization: Optional[str] = Header(default=None),
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
    authorization: Optional[str] = Header(default=None),
    days: Optional[int] = Body(default=None)
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
