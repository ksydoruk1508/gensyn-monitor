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

def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    cleaned = str(raw).split("#", 1)[0].strip()
    if not cleaned:
        return default
    try:
        return int(cleaned)
    except ValueError:
        logger.warning("Invalid integer for %s: %r (using default=%s)", name, raw, default)
        return default

BOT_TOKEN  = os.getenv("TELEGRAM_BOT_TOKEN", "")
CHAT_ID    = os.getenv("TELEGRAM_CHAT_ID", "")
SHARED     = os.getenv("SHARED_SECRET", "")
THRESHOLD  = _env_int("DOWN_THRESHOLD_SEC", 180)  # сек. до статуса DOWN
SITE_TITLE = os.getenv("SITE_TITLE", "Gensyn Nodes")

# Админ-опции
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "")                 # Bearer токен админа
PRUNE_DAYS  = _env_int("PRUNE_DAYS", 0)            # 0 = не чистить

# G-Swarm фоновые обновления
GSWARM_REFRESH_INTERVAL = _env_int("GSWARM_REFRESH_INTERVAL", 600)
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
        tgid_raw = cfg.get("tgid")
        if tgid_raw is None:
            tgid_raw = cfg.get("telegram_id")
        tgid = (str(tgid_raw).strip() or None) if tgid_raw is not None else None
        if not eoa and not peers and not tgid:
            continue
        entry: Dict[str, Any] = {}
        if eoa:
            entry["eoa"] = eoa
        if peers:
            entry["peer_ids"] = peers
        if tgid:
            entry["tgid"] = tgid
        out[node_id] = entry
    return out

ENV_GSWARM_NODE_MAP = _load_env_node_map(GSWARM_NODE_MAP_RAW)

if not (BOT_TOKEN and CHAT_ID and SHARED):
    raise RuntimeError("Set TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SHARED_SECRET in .env")

DB = os.getenv("DB_PATH", "/opt/gensyn-monitor/monitor.db")

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
            "ALTER TABLE nodes ADD COLUMN gswarm_tgid TEXT",
            "ALTER TABLE nodes ADD COLUMN gswarm_peer_ids TEXT",
            "ALTER TABLE nodes ADD COLUMN gswarm_stats TEXT",
            "ALTER TABLE nodes ADD COLUMN gswarm_updated INTEGER",
            "ALTER TABLE nodes ADD COLUMN gswarm_alert INTEGER DEFAULT 1",
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
    gswarm_peer_ids: Optional[List[str]],
    gswarm_tgid: Optional[str]
):
    now = int(time.time())
    gswarm_eoa = (gswarm_eoa or "").strip() or None
    gswarm_tgid = (gswarm_tgid or "").strip() or None
    peers_blob = peers_to_store(gswarm_peer_ids)

    async with aiosqlite.connect(DB) as db:
        await db.execute("""
            INSERT INTO nodes(
                node_id, ip, last_seen, last_state, last_computed, meta,
                last_reported, gswarm_eoa, gswarm_tgid, gswarm_peer_ids
            )
            VALUES(?, ?, ?, 'DOWN','UP', ?, ?, ?, ?, ?)
            ON CONFLICT(node_id) DO UPDATE SET
              ip             = excluded.ip,
              last_seen      = excluded.last_seen,
              meta           = excluded.meta,
              last_reported  = excluded.last_reported,
              -- не перетираем, если агент прислал NULL/пусто
              gswarm_eoa = CASE
                              WHEN excluded.gswarm_eoa IS NULL OR excluded.gswarm_eoa = '' THEN NULL
                              ELSE excluded.gswarm_eoa
                            END,
              gswarm_tgid = CASE
                               WHEN excluded.gswarm_tgid IS NULL OR excluded.gswarm_tgid = '' THEN NULL
                               ELSE excluded.gswarm_tgid
                             END,
              gswarm_peer_ids = CASE
                                   WHEN excluded.gswarm_peer_ids IS NULL OR excluded.gswarm_peer_ids = '' THEN NULL
                                   ELSE excluded.gswarm_peer_ids
                                 END
        """, (node_id, ip, now, meta, reported, gswarm_eoa, gswarm_tgid, peers_blob))
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
            env_tgid = env_cfg.get("tgid") if env_cfg else None
            alert_raw = 1
            if "gswarm_alert" in r.keys():
                try:
                    alert_raw = int(r["gswarm_alert"])
                except Exception:
                    alert_raw = 1
            alert_enabled = bool(alert_raw if alert_raw is not None else 1)

            # итоговые значения для UI
            stats_eoa = gswarm_stats.get("eoa") if isinstance(gswarm_stats, dict) else None
            eoa_value = r["gswarm_eoa"] or env_eoa or stats_eoa
            peers_value = peer_ids or env_peers
            db_tgid = None
            if "gswarm_tgid" in r.keys():
                raw_tgid = r["gswarm_tgid"]
                if isinstance(raw_tgid, str):
                    db_tgid = raw_tgid.strip() or None
                elif raw_tgid is not None:
                    db_tgid = str(raw_tgid).strip() or None
            tgid_value = db_tgid or env_tgid

            updated_val = r["gswarm_updated"] if "gswarm_updated" in r.keys() else None
            gswarm_block = None
            if eoa_value or peers_value or gswarm_stats or tgid_value or alert_enabled:
                gswarm_block = {
                    "eoa": eoa_value,
                    "peer_ids": peers_value,
                    "stats": gswarm_stats,
                    "updated": updated_val,
                    "tgid": tgid_value,
                    "alert": alert_enabled
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
                "gswarm": gswarm_block,
                "gswarm_alert": alert_enabled
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
            """
            SELECT node_id,
                   gswarm_eoa,
                   gswarm_tgid,
                   gswarm_peer_ids,
                   gswarm_alert,
                   gswarm_stats
            FROM nodes
            """
        )
    eoas: List[str] = []
    node_configs: Dict[str, Dict[str, Any]] = {}
    existing_ids = {r["node_id"] for r in rows}
    for r in rows:
        eoa_raw = (r["gswarm_eoa"] or "").strip()
        eoa_norm = _normalize_eoa(eoa_raw)
        peers = parse_peer_ids(r["gswarm_peer_ids"])
        tgid_raw = (r["gswarm_tgid"] or "").strip() if "gswarm_tgid" in r.keys() else ""
        cfg: Dict[str, Any] = {}
        if eoa_raw:
            eoas.append(eoa_raw)
            cfg["eoa"] = eoa_raw
        if eoa_norm:
            cfg["eoa_norm"] = eoa_norm
        if peers:
            cfg["peer_ids"] = peers
        if tgid_raw:
            cfg["tgid"] = tgid_raw
        alert_flag = True
        if "gswarm_alert" in r.keys():
            try:
                alert_flag = bool(int(r["gswarm_alert"]))
            except Exception:
                alert_flag = True
        cfg["alert"] = alert_flag
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
        if cfg.get("tgid") and not stored.get("tgid"):
            stored["tgid"] = cfg["tgid"]
        if stored.get("alert") is None and cfg.get("alert") is not None:
            stored["alert"] = cfg.get("alert")
        if cfg.get("peer_ids"):
            # Overwrite semantics: environment mapping replaces stored peers
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
            if cfg.get("tgid"):
                stats["tgid"] = cfg.get("tgid")
            if cfg.get("alert") is not None:
                stats["alert"] = bool(cfg.get("alert"))
            aggregated[node_id] = stats
    return aggregated

def _collect_peer_groups(node_configs: Dict[str, Dict[str, Any]]) -> Dict[str | None, List[str]]:
    groups: Dict[str | None, List[str]] = {}
    for cfg in node_configs.values():
        peers = cfg.get("peer_ids") or []
        if not peers:
            continue
        raw_key = cfg.get("tgid")
        key: str | None
        if raw_key is None:
            key = None
        else:
            key = str(raw_key).strip()
            if not key:
                key = None
        bucket = groups.setdefault(key, [])
        bucket.extend(peers)
    deduped: Dict[str | None, List[str]] = {}
    for key, values in groups.items():
        seen = set()
        items: List[str] = []
        for pid in values:
            pid_clean = (pid or "").strip()
            if not pid_clean or pid_clean in seen:
                continue
            seen.add(pid_clean)
            items.append(pid_clean)
        if items:
            deduped[key] = items
    return deduped

async def _persist_gswarm_result(result: Dict[str, Any], node_configs: Dict[str, Dict[str, Any]]) -> tuple[Dict[str, Dict[str, Any]], int]:
    if not node_configs:
        return {}, 0

    per_peer = result.get("per_peer", {}) or {}
    last_check = result.get("ts")
    eoa_peer_map = result.get("eoa_peers", {}) or {}
    _apply_auto_peers(node_configs, eoa_peer_map)
    now_ts = int(time.time())
    node_stats = _aggregate_nodes(per_peer, node_configs, last_check)

    def _merge_peer(old: Dict[str, Any] | None, new: Dict[str, Any] | None) -> Dict[str, Any] | None:
        if not new and not old:
            return None
        if not old:
            return new
        if not new:
            return old
        out = dict(new)
        # wins/rewards — никогда не понижаем
        out["per_peer"] = {}
        totals_wins = 0
        totals_rewards = 0
        ranked = 0
        # собрать множество всех peerId
        all_ids = set((old.get("per_peer") or {}).keys()) | set((new.get("per_peer") or {}).keys())
        for pid in all_ids:
            vo = (old.get("per_peer") or {}).get(pid, {}) or {}
            vn = (new.get("per_peer") or {}).get(pid, {}) or {}
            w = max(int(vo.get("wins", 0) or 0), int(vn.get("wins", 0) or 0))
            r = max(int(vo.get("rewards", 0) or 0), int(vn.get("rewards", 0) or 0))
            rk_candidates = [x for x in [vo.get("rank"), vn.get("rank")] if isinstance(x, int) and x > 0]
            rk = min(rk_candidates) if rk_candidates else None
            out["per_peer"][pid] = {"wins": w, "rewards": r, "rank": rk}
            totals_wins += w
            totals_rewards += r
            if w > 0:
                ranked += 1
        peers_cnt = len(all_ids)
        out["totals"] = {
            "wins": totals_wins,
            "rewards": totals_rewards,
            "peers": peers_cnt,
            "ranked": ranked,
        }
        # перенос вспомогательных полей
        for k in ("eoa", "tgid", "alert", "last_check", "missing_peers"):
            if k in new and new[k] is not None:
                out[k] = new[k]
            elif k in old and old[k] is not None:
                out[k] = old[k]
        return out

    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        updated_count = 0

        # прочитать текущие сохранённые статы
        cur = await db.execute("SELECT node_id, gswarm_stats, gswarm_updated FROM nodes")
        rows = await cur.fetchall()
        existing: Dict[str, Dict[str, Any]] = {}
        for r in rows:
            blob = r["gswarm_stats"]
            if blob:
                try:
                    existing[r["node_id"]] = json.loads(blob)
                except Exception:
                    existing[r["node_id"]] = None

        for node_id, cfg in node_configs.items():
            new_stats = node_stats.get(node_id)
            old_stats = existing.get(node_id)

            # если вообще ничего нового — пропускаем
            if not new_stats and not old_stats:
                continue
            if not new_stats and old_stats:
                # нечего обновлять, но и не затираем
                continue

            # защитa от «регресса» (лимиты/пустые ответы)
            if old_stats and new_stats:
                old_tot = old_stats.get("totals") or {}
                new_tot = new_stats.get("totals") or {}
                old_w = int(old_tot.get("wins", 0) or 0)
                old_r = int(old_tot.get("rewards", 0) or 0)
                new_w = int(new_tot.get("wins", 0) or 0)
                new_r = int(new_tot.get("rewards", 0) or 0)
                if False and (new_w < old_w or new_r < old_r or (new_tot.get("peers", 0) or 0) == 0):
                    # не обновляем — оставляем прежние данные
                    continue

            merged = (new_stats if new_stats is not None else old_stats)

            payload = json.dumps(merged, ensure_ascii=False) if merged else None
            peers_blob = peers_to_store(cfg.get("peer_ids"))
            tgid_value = cfg.get("tgid") or None

            await db.execute(
                """
                UPDATE nodes
                SET gswarm_stats=?,
                    gswarm_updated=?,
                    gswarm_eoa=?,
                    gswarm_tgid=?,
                    gswarm_peer_ids=?
                WHERE node_id=?
                """,
                (payload, now_ts, (cfg.get("eoa") or None), tgid_value, peers_blob, node_id),
            )
            updated_count += 1

        await db.commit()

    return node_stats, updated_count


async def _persist_gswarm_result_overwrite(result: Dict[str, Any], node_configs: Dict[str, Dict[str, Any]]) -> tuple[Dict[str, Dict[str, Any]], int]:
    """Persist G‑Swarm stats with overwrite semantics.

    - Always replace previous stats with the newest snapshot.
    - If no data for a node (e.g., empty peers), set gswarm_stats=NULL but update gswarm_updated.
    - Do not touch gswarm_eoa/gswarm_tgid/gswarm_peer_ids here (managed by heartbeat/env).
    """
    if not node_configs:
        return {}, 0

    per_peer = result.get("per_peer", {}) or {}
    last_check = result.get("ts")
    eoa_peer_map = result.get("eoa_peers", {}) or {}
    _apply_auto_peers(node_configs, eoa_peer_map)
    now_ts = int(time.time())
    node_stats = _aggregate_nodes(per_peer, node_configs, last_check)

    async with aiosqlite.connect(DB) as db:
        updated_count = 0

        for node_id, cfg in node_configs.items():
            stats = node_stats.get(node_id)
            if stats is None:
                await db.execute(
                    """
                    UPDATE nodes
                    SET gswarm_stats=NULL,
                        gswarm_updated=?
                    WHERE node_id=?
                    """,
                    (now_ts, node_id),
                )
                logger.info("[GSWARM] update: node=%s cleared=1 peers=0 wins=0 rewards=0", node_id)
                updated_count += 1
                continue

            payload = json.dumps(stats, ensure_ascii=False)
            await db.execute(
                """
                UPDATE nodes
                SET gswarm_stats=?,
                    gswarm_updated=?
                WHERE node_id=?
                """,
                (payload, now_ts, node_id),
            )
            tot = (stats or {}).get("totals") or {}
            wins = int(tot.get("wins", 0) or 0)
            rewards = int(tot.get("rewards", 0) or 0)
            peers_cnt = int(tot.get("peers", 0) or 0)
            logger.info("[GSWARM] update: node=%s cleared=0 peers=%s wins=%s rewards=%s", node_id, peers_cnt, wins, rewards)
            updated_count += 1

        await db.commit()

    return node_stats, updated_count

async def refresh_gswarm_stats():
    logger.info("[GSWARM] refresh: collecting sources…")
    eoas, node_configs = await _gswarm_sources()
    try:
        nodes_cnt = len(node_configs or {})
        peers_sum = sum(len((cfg.get("peer_ids") or [])) for cfg in (node_configs or {}).values())
        eoa_cnt = sum(1 for cfg in (node_configs or {}).values() if cfg.get("eoa"))
        logger.info("[GSWARM] sources: nodes=%d, peers_total=%d, eoa_nodes=%d", nodes_cnt, peers_sum, eoa_cnt)
    except Exception:
        pass
    extra_peer_ids = sorted({pid for cfg in node_configs.values() for pid in cfg.get("peer_ids", [])})
    peer_groups = _collect_peer_groups(node_configs) if node_configs else {}
    any_alert = any(cfg.get("alert", True) for cfg in node_configs.values()) if node_configs else False
    if not node_configs and not eoas:
        logger.info("[GSWARM] refresh: nothing to do (no node configs / EOAs)")
        return
    loop = asyncio.get_running_loop()
    try:
        result = await loop.run_in_executor(
            None,
            lambda: run_once(
                send_telegram=GSWARM_AUTO_SEND and any_alert,
                extra_peer_ids=extra_peer_ids,
                extra_eoas=eoas,
                offchain_peer_map=peer_groups,
            ),
        )
    except Exception as exc:
        logger.exception("[GSWARM] refresh failed: %s", exc)
        return

    _, updated_count = await _persist_gswarm_result_overwrite(result, node_configs)

    logger.info("[GSWARM] refresh ok: nodes=%d, peers=%d, wins=%s, rewards=%s, updated=%d",
                len(node_configs), len(result.get("per_peer", {})),
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
    tgid_input = data.get("gswarm_tgid")
    if tgid_input is None and gswarm_envelope:
        tgid_input = gswarm_envelope.get("tgid") or gswarm_envelope.get("telegram_id")
    if isinstance(tgid_input, int):
        gswarm_tgid = str(tgid_input)
    elif isinstance(tgid_input, str):
        gswarm_tgid = tgid_input.strip() or None
    else:
        gswarm_tgid = None

    await upsert(node_id, ip, meta, reported, gswarm_eoa, gswarm_peer_ids, gswarm_tgid)
    return {"ok": True}

@app.get("/api/nodes")
async def api_nodes():
    return JSONResponse(await list_nodes())

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "site_title": SITE_TITLE,
            "threshold": THRESHOLD,
            "admin_token": ADMIN_TOKEN,
        }
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
    peer_groups = _collect_peer_groups(node_configs) if node_configs else {}
    result = await asyncio.to_thread(
        run_once,
        send_telegram=send,
        extra_peer_ids=extra_peer_ids,
        extra_eoas=extra_eoas,
        offchain_peer_map=peer_groups,
    )
    if include_nodes and node_configs:
        node_stats, _ = await _persist_gswarm_result_overwrite(result, node_configs)
        result["nodes"] = node_stats
    return result

@app.post("/api/nodes/gswarm/alert")
async def set_gswarm_alert(
    payload: Dict[str, Any],
    authorization: Optional[str] = Header(default=None)
):
    if ADMIN_TOKEN and not admin_ok(authorization):
        raise HTTPException(401, "Unauthorized")
    node_id = str(payload.get("node_id", "")).strip()
    if not node_id:
        raise HTTPException(400, "node_id required")
    enabled_raw = payload.get("enabled")
    if isinstance(enabled_raw, str):
        enabled_val = enabled_raw.strip().lower()
        enabled = enabled_val not in {"0", "false", "no", "off"}
    else:
        enabled = bool(enabled_raw)
    async with aiosqlite.connect(DB) as db:
        cur = await db.execute("SELECT 1 FROM nodes WHERE node_id=?", (node_id,))
        exists = await cur.fetchone()
        if not exists:
            raise HTTPException(404, "node not found")
        await db.execute(
            "UPDATE nodes SET gswarm_alert=? WHERE node_id=?",
            (1 if enabled else 0, node_id)
        )
        await db.commit()
    return {"ok": True, "node_id": node_id, "enabled": enabled}

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
