from typing import Optional, List, Dict, Any
import os, asyncio, time, json, logging
from fastapi import FastAPI, Request, HTTPException, Header, Body, Query
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
import aiosqlite, httpx
from dotenv import load_dotenv
from integrations.gswarm_checker import run_once

# ── Конфиг ─────────────────────────────────────────────────────────────────────
load_dotenv()
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger("gensyn-monitor")

BOT_TOKEN  = os.getenv("TELEGRAM_BOT_TOKEN", "")
CHAT_ID    = os.getenv("TELEGRAM_CHAT_ID", "")
SHARED     = os.getenv("SHARED_SECRET", "")
THRESHOLD  = int(os.getenv("DOWN_THRESHOLD_SEC", "180"))  # сек. до статуса DOWN
SITE_TITLE = os.getenv("SITE_TITLE", "Gensyn Nodes")

# Админ-опции
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "")                 # Bearer токен админа
PRUNE_DAYS  = int(os.getenv("PRUNE_DAYS", "0"))            # 0 = не чистить

# G-Swarm фоновые обновления
GSWARM_REFRESH_INTERVAL = int(os.getenv("GSWARM_REFRESH_INTERVAL", "600"))
GSWARM_AUTO_SEND = os.getenv("GSWARM_AUTO_SEND", "0") == "1"
GSWARM_NODE_MAP_RAW = os.getenv("GSWARM_NODE_MAP", "").strip()

def _dedup(seq: List[str]) -> List[str]:
    seen = set()
    out: List[str] = []
    for item in seq:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out

def _normalize_eoa(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    return value.strip().lower()

def parse_peer_ids(value: Any) -> List[str]:
    if value is None:
        return []
    seq: List[str]
    if isinstance(value, list):
        seq = [str(x) for x in value]
    elif isinstance(value, str):
        val = value.strip()
        if not val:
            return []
        if val.startswith("["):
            try:
                maybe = json.loads(val)
                if isinstance(maybe, list):
                    seq = [str(x) for x in maybe]
                else:
                    seq = [val]
            except Exception:
                seq = [s.strip() for s in val.split(",")]
        else:
            seq = [s.strip() for s in val.split(",")]
    else:
        seq = [str(value)]
    peers = [s.strip() for s in seq if s and s.strip()]
    return _dedup(peers)

def peers_to_store(peers: List[str] | None) -> Optional[str]:
    peers = [p for p in (peers or []) if p]
    if not peers:
        return None
    return json.dumps(_dedup(peers), ensure_ascii=False)

def _load_env_node_map(raw: str) -> Dict[str, Dict[str, Any]]:
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except Exception as exc:
        logger.warning("Failed to parse GSWARM_NODE_MAP: %s", exc)
        return {}
    out: Dict[str, Dict[str, Any]] = {}
    for node_id, cfg in data.items():
        if not isinstance(cfg, dict):
            continue
        eoa = (cfg.get("eoa") or "").strip() or None
        peers = parse_peer_ids(cfg.get("peer_ids"))
        if not eoa and not peers:
            continue
        out[node_id] = {"eoa": eoa, "peer_ids": peers}
    return out

ENV_GSWARM_NODE_MAP = _load_env_node_map(GSWARM_NODE_MAP_RAW)

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
        # миграции
        try:
            await db.execute("ALTER TABLE nodes ADD COLUMN last_reported TEXT DEFAULT 'UP'")
        except Exception:
            pass
        for ddl in (
            "ALTER TABLE nodes ADD COLUMN gswarm_eoa TEXT",
            "ALTER TABLE nodes ADD COLUMN gswarm_peer_ids TEXT",
            "ALTER TABLE nodes ADD COLUMN gswarm_stats TEXT",
            "ALTER TABLE nodes ADD COLUMN gswarm_updated INTEGER",
        ):
            try:
                await db.execute(ddl)
            except Exception:
                pass
        await db.commit()

@app.on_event("startup")
async def startup():
    await init_db()
    asyncio.create_task(watchdog_loop())
    if GSWARM_REFRESH_INTERVAL > 0:
        asyncio.create_task(gswarm_loop())

def fresh_since(last_seen: int) -> bool:
    return (int(time.time()) - int(last_seen)) <= THRESHOLD

async def send_tg(text: str):
    async with httpx.AsyncClient(timeout=10) as c:
        await c.post(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            data={"chat_id": CHAT_ID, "parse_mode": "Markdown", "text": text}
        )

async def upsert(
    node_id: str,
    ip: str,
    meta: Optional[str],
    reported: str,
    gswarm_eoa: Optional[str],
    gswarm_peer_ids: Optional[List[str]]
):
    """
    reported — статус, присланный агентом: 'UP' | 'DOWN' (валидируем в handler’е).
    """
    now = int(time.time())
    gswarm_eoa = (gswarm_eoa or "").strip() or None
    peers_blob = peers_to_store(gswarm_peer_ids)
    async with aiosqlite.connect(DB) as db:
        await db.execute("""
            INSERT INTO nodes(
                node_id,ip,last_seen,last_state,last_computed,meta,last_reported,gswarm_eoa,gswarm_peer_ids
            )
            VALUES(?, ?, ?, 'DOWN','UP', ?, ?, ?, ?)
            ON CONFLICT(node_id) DO UPDATE
              SET ip=excluded.ip,
                  last_seen=excluded.last_seen,
                  meta=excluded.meta,
                  last_reported=excluded.last_reported,
                  gswarm_eoa=excluded.gswarm_eoa,
                  gswarm_peer_ids=excluded.gswarm_peer_ids
        """, (node_id, ip, now, meta, reported, gswarm_eoa, peers_blob))
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

            # peers из БД
            peer_ids = parse_peer_ids(r["gswarm_peer_ids"] if "gswarm_peer_ids" in r.keys() else None)

            # безопасный парсинг stats
            gswarm_stats = None
            raw_stats = r["gswarm_stats"] if "gswarm_stats" in r.keys() else None
            if raw_stats:
                try:
                    gswarm_stats = json.loads(raw_stats)
                except Exception:
                    logger.warning("Bad gswarm_stats JSON for %s", r["node_id"])
                    gswarm_stats = None

            # env-оверрайды
            env_cfg = ENV_GSWARM_NODE_MAP.get(r["node_id"])
            env_eoa = env_cfg.get("eoa") if env_cfg else None
            env_peers = env_cfg.get("peer_ids") if env_cfg else []

            # итоговые значения для UI
            stats_eoa = gswarm_stats.get("eoa") if isinstance(gswarm_stats, dict) else None
            eoa_value = r["gswarm_eoa"] or env_eoa or stats_eoa
            peers_value = peer_ids or env_peers

            updated_val = r["gswarm_updated"] if "gswarm_updated" in r.keys() else None
            gswarm_block = None
            if eoa_value or peers_value or gswarm_stats:
                gswarm_block = {
                    "eoa": eoa_value,
                    "peer_ids": peers_value,
                    "stats": gswarm_stats,
                    "updated": updated_val
                }

            out.append({
                "node_id": r["node_id"],
                "ip": r["ip"],
                "last_seen": r["last_seen"],
                "computed": computed,
                "last_state": r["last_state"],
                "meta": r["meta"],
                "age_sec": max(0, now - int(r["last_seen"])),
                "reported": reported,
                "gswarm": gswarm_block
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

async def _gswarm_sources() -> tuple[List[str], Dict[str, Dict[str, Any]]]:
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall(
            "SELECT node_id, gswarm_eoa, gswarm_peer_ids FROM nodes"
        )
    eoas: List[str] = []
    node_configs: Dict[str, Dict[str, Any]] = {}
    existing_ids = {r["node_id"] for r in rows}
    for r in rows:
        eoa_raw = (r["gswarm_eoa"] or "").strip()
        eoa_norm = _normalize_eoa(eoa_raw)
        peers = parse_peer_ids(r["gswarm_peer_ids"])
        cfg: Dict[str, Any] = {}
        if eoa_raw:
            eoas.append(eoa_raw)
            cfg["eoa"] = eoa_raw
        if eoa_norm:
            cfg["eoa_norm"] = eoa_norm
        if peers:
            cfg["peer_ids"] = peers
        if cfg:
            node_configs[r["node_id"]] = cfg
    for node_id, cfg in ENV_GSWARM_NODE_MAP.items():
        if node_id not in existing_ids:
            continue
        stored = node_configs.setdefault(node_id, {})
        if cfg.get("eoa") and not stored.get("eoa"):
            stored["eoa"] = cfg["eoa"]
            stored["eoa_norm"] = _normalize_eoa(cfg["eoa"])
            eoas.append(cfg["eoa"])
        if cfg.get("peer_ids"):
            if stored.get("peer_ids"):
                stored["peer_ids"] = _dedup([*stored["peer_ids"], *cfg["peer_ids"]])
            else:
                stored["peer_ids"] = cfg["peer_ids"]
    return _dedup(eoas), node_configs

def _apply_auto_peers(node_configs: Dict[str, Dict[str, Any]], eoa_peer_map: Dict[str, List[str]]) -> None:
    if not eoa_peer_map:
        return
    norm_map = { (key or "").lower(): val for key, val in eoa_peer_map.items() if key }
    for cfg in node_configs.values():
        eoa_norm = cfg.get("eoa_norm")
        if not eoa_norm:
            continue
        peers = norm_map.get(eoa_norm)
        if not peers:
            continue
        if not cfg.get("peer_ids"):
            cfg["peer_ids"] = list(dict.fromkeys(peers))
        if not cfg.get("eoa"):
            cfg["eoa"] = eoa_norm

def _build_node_gswarm(per_peer: Dict[str, Dict[str, Any]], peers: List[str], last_check: str | None):
    matched: Dict[str, Dict[str, Any]] = {}
    missing: List[str] = []
    total_wins = 0
    total_rewards = 0
    ranked = 0
    for pid in peers:
        data = per_peer.get(pid)
        if data:
            matched[pid] = data
            wins_val = int(data.get("wins", 0) or 0)
            rewards_val = int(data.get("rewards", 0) or 0)
            total_wins += wins_val
            total_rewards += rewards_val
            if wins_val > 0:
                ranked += 1
        else:
            missing.append(pid)
    if not matched:
        return None
    return {
        "per_peer": matched,
        "totals": {
            "wins": total_wins,
            "rewards": total_rewards,
            "peers": len(peers),
            "ranked": ranked,
        },
        "missing_peers": missing or None,
        "last_check": last_check,
    }

def _aggregate_nodes(per_peer: Dict[str, Dict[str, Any]], node_configs: Dict[str, Dict[str, Any]], last_check: str | None):
    aggregated: Dict[str, Dict[str, Any]] = {}
    for node_id, cfg in node_configs.items():
        peers = cfg.get("peer_ids") or []
        if not peers:
            continue
        stats = _build_node_gswarm(per_peer, peers, last_check)
        if stats:
            if cfg.get("eoa"):
                stats["eoa"] = cfg.get("eoa")
            aggregated[node_id] = stats
    return aggregated

async def refresh_gswarm_stats():
    logger.info("[GSWARM] refresh: collecting sources…")
    eoas, node_configs = await _gswarm_sources()
    extra_peer_ids = sorted({pid for cfg in node_configs.values() for pid in cfg.get("peer_ids", [])})
    if not node_configs and not eoas:
        logger.info("[GSWARM] refresh: nothing to do (no node configs / EOAs)")
        return
    loop = asyncio.get_running_loop()
    try:
        result = await loop.run_in_executor(
            None,
            lambda: run_once(
                send_telegram=GSWARM_AUTO_SEND,
                extra_peer_ids=extra_peer_ids,
                extra_eoas=eoas,
            ),
        )
    except Exception as exc:
        logger.exception("[GSWARM] refresh failed: %s", exc)
        return

    per_peer = result.get("per_peer", {})
    last_check = result.get("ts")
    eoa_peer_map = result.get("eoa_peers", {}) or {}
    _apply_auto_peers(node_configs, eoa_peer_map)

    now_ts = int(time.time())
    node_stats = _aggregate_nodes(per_peer, node_configs, last_check)

    async with aiosqlite.connect(DB) as db:
        updated_count = 0
        for node_id, cfg in node_configs.items():
            stats = node_stats.get(node_id)
            payload_dict = stats if stats else None
            if payload_dict and cfg.get("eoa") and not payload_dict.get("eoa"):
                payload_dict = dict(payload_dict)
                payload_dict["eoa"] = cfg["eoa"]
            payload = json.dumps(payload_dict, ensure_ascii=False) if payload_dict else None
            updated_ts = now_ts if stats else None
            peers_blob = peers_to_store(cfg.get("peer_ids"))
            await db.execute(
                """
                UPDATE nodes
                SET gswarm_stats=?, gswarm_updated=?, gswarm_eoa=?, gswarm_peer_ids=?
                WHERE node_id=?
                """,
                (payload, updated_ts, (cfg.get("eoa") or None), peers_blob, node_id),
            )
            if stats:
                updated_count += 1
        await db.commit()

    logger.info("[GSWARM] refresh ok: nodes=%d, peers=%d, wins=%s, rewards=%s, updated=%d",
                len(node_configs), len(per_peer),
                result.get("totals",{}).get("wins"), result.get("totals",{}).get("rewards"),
                updated_count)

async def gswarm_loop():
    await asyncio.sleep(5)
    interval = max(60, GSWARM_REFRESH_INTERVAL)
    logger.info("[GSWARM] loop started, interval=%ss", interval)
    while True:
        try:
            await refresh_gswarm_stats()
        except Exception as exc:
            logger.exception("[GSWARM] loop iteration failed: %s", exc)
        await asyncio.sleep(interval)

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
    raw = await req.body()
    try:
        data = json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError as exc:
        logger.warning("Heartbeat decode error: %s", exc)
        raise HTTPException(400, "Invalid JSON encoding (expected UTF-8)")
    except json.JSONDecodeError as exc:
        logger.warning("Heartbeat JSON error: %s", exc)
        raise HTTPException(400, "Malformed JSON payload")
    node_id = str(data.get("node_id", "")).strip()
    if not node_id:
        raise HTTPException(400, "node_id required")
    ip = str(data.get("ip", "")).strip()
    meta = str(data.get("meta", "")) if data.get("meta") else None
    reported = str(data.get("status", "UP")).strip().upper()
    if reported not in ("UP", "DOWN"):
        reported = "DOWN"

    gswarm_envelope = data.get("gswarm") if isinstance(data.get("gswarm"), dict) else None
    gswarm_eoa = data.get("gswarm_eoa") or (gswarm_envelope.get("eoa") if gswarm_envelope else None)
    if isinstance(gswarm_eoa, str):
        gswarm_eoa = gswarm_eoa.strip() or None
    peer_input = data.get("gswarm_peer_ids")
    if peer_input is None and gswarm_envelope:
        peer_input = gswarm_envelope.get("peer_ids")
    gswarm_peer_ids = parse_peer_ids(peer_input)

    await upsert(node_id, ip, meta, reported, gswarm_eoa, gswarm_peer_ids)
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

@app.post("/api/gswarm/check")
async def gswarm_check(
    send: bool = Query(False, description="Отправить в Telegram"),
    include_nodes: bool = Query(
        False,
        description="Включить peer_ids из зарегистрированных нод"
    )
):
    """
    Разовый сбор G-Swarm метрик.
    send=true — сразу отправить HTML-репорт в Telegram (если TELEGRAM_* заданы).
    """
    extra_eoas: List[str] = []
    node_configs: Dict[str, Dict[str, Any]] = {}
    if include_nodes:
        extra_eoas, node_configs = await _gswarm_sources()
    extra_peer_ids = sorted({pid for cfg in node_configs.values() for pid in cfg.get("peer_ids", [])}) if node_configs else []
    result = await asyncio.to_thread(
        run_once,
        send_telegram=send,
        extra_peer_ids=extra_peer_ids,
        extra_eoas=extra_eoas,
    )
    if include_nodes and node_configs:
        eoa_peer_map = result.get("eoa_peers", {}) or {}
        _apply_auto_peers(node_configs, eoa_peer_map)
        result["nodes"] = _aggregate_nodes(result.get("per_peer", {}), node_configs, result.get("ts"))
    return result

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

@app.post("/api/admin/gswarm/refresh")
async def admin_gswarm_refresh(authorization: Optional[str] = Header(default=None)):
    if not admin_ok(authorization):
        raise HTTPException(401, "Unauthorized")
    await refresh_gswarm_stats()
    return {"ok": True}
