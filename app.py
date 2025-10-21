import os, asyncio, time
from fastapi import FastAPI, Request, HTTPException, Header
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

# ── API ───────────────────────────────────────────────────────────────────────
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
