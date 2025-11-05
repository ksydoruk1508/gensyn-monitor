#!/usr/bin/env python3
# gswarm_checker.py — mini-логика без ранков, с троттлингом и паузами.

import os
import json
import time
import random
import logging
from datetime import datetime
from typing import Dict, List, Tuple
from concurrent.futures import ThreadPoolExecutor, as_completed
from web3 import Web3

log = logging.getLogger("gensyn-monitor")

# ===== ENV =====
_RPC_URL = os.environ.get("RPC_URL", "https://gensyn-testnet.g.alchemy.com/public").strip()
_RPC_URLS = [u.strip() for u in os.environ.get("RPC_URLS", "").split(",") if u.strip()]

_SWARM_COORDINATOR = os.environ.get(
    "SWARM_COORDINATOR_ADDR", "0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
).strip()

# ограничения и паузы
_MAX_WORKERS = int(os.environ.get("GSWARM_MAX_WORKERS", "2"))  # поменьше, чтобы не ловить 429
_EOA_PAUSE = int(os.environ.get("GSWARM_EOA_PAUSE_SEC", "60"))  # пауза между EOA
_REWARDS_CHUNK = int(os.environ.get("GSWARM_REWARDS_CHUNK", "20"))  # размер чанка для getTotalRewards
_CHUNK_PAUSE = float(os.environ.get("GSWARM_CHUNK_PAUSE_SEC", "20"))  # пауза между чанками rewards
_PER_CALL_JITTER = float(os.environ.get("GSWARM_PER_CALL_JITTER_SEC", "0.05"))  # микропаузка в воркерах

# ретраи на 429/таймауты
_RETRY_MAX = int(os.environ.get("GSWARM_RETRY_MAX", "3"))
_RETRY_BASE = float(os.environ.get("GSWARM_RETRY_BASE_DELAY_SEC", "2.0"))

_ABI = [
    {"inputs":[{"internalType":"address[]","name":"eoas","type":"address[]"}],
     "name":"getPeerId","outputs":[{"internalType":"string[][]","name":"","type":"string[][]"}],
     "stateMutability":"view","type":"function"},
    {"inputs":[{"internalType":"string","name":"peerId","type":"string"}],
     "name":"getTotalWins","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],
     "stateMutability":"view","type":"function"},
    {"inputs":[{"internalType":"string","name":"peerId","type":"string"}],
     "name":"getVoterVoteCount","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],
     "stateMutability":"view","type":"function"},
    {"inputs":[{"internalType":"string[]","name":"peerIds","type":"string[]"}],
     "name":"getTotalRewards","outputs":[{"internalType":"int256[]","name":"","type":"int256[]"}],
     "stateMutability":"view","type":"function"},
]

_W3_CACHED: Web3 | None = None

def _w3() -> Web3:
    global _W3_CACHED
    if _W3_CACHED is not None:
        return _W3_CACHED
    urls = _RPC_URLS if _RPC_URLS else [_RPC_URL]
    last_err = None
    for i, url in enumerate(urls, 1):
        try:
            log.info("[GSWARM-mini] RPC try %d/%d: %s", i, len(urls), url)
            w = Web3(Web3.HTTPProvider(url, request_kwargs={"timeout": 15}))
            if w.is_connected():
                _W3_CACHED = w
                log.info("[GSWARM-mini] RPC connected: %s", url)
                return w
            else:
                log.warning("[GSWARM-mini] RPC is_connected()=False: %s", url)
        except Exception as e:
            last_err = e
            log.error("[GSWARM-mini] RPC error: %s :: %s", url, e)
    raise RuntimeError(f"RPC недоступен: {urls[-1]}") from last_err

def _contract(w3: Web3):
    return w3.eth.contract(address=w3.to_checksum_address(_SWARM_COORDINATOR), abi=_ABI)

# ===== утиль =====
def _is_rate_limited(err: Exception) -> bool:
    s = str(err)
    return "429" in s or "Too Many Requests" in s

def _call_with_retry(fn, desc: str, *args, **kwargs):
    delay = _RETRY_BASE
    for attempt in range(1, _RETRY_MAX + 1):
        try:
            # небольшая джиттерная пауза перед каждым вызовом — разгружаем RPC
            if _PER_CALL_JITTER > 0:
                time.sleep(_PER_CALL_JITTER + random.random() * _PER_CALL_JITTER)
            return fn(*args, **kwargs)
        except Exception as e:
            if attempt < _RETRY_MAX and _is_rate_limited(e):
                log.warning("[GSWARM-mini] %s rate-limited (429), retry %d/%d in %.1fs",
                            desc, attempt, _RETRY_MAX, delay)
                time.sleep(delay)
                delay *= 1.7
                continue
            log.warning("[GSWARM-mini] %s failed (attempt %d/%d): %s", desc, attempt, _RETRY_MAX, e)
            if attempt >= _RETRY_MAX:
                raise
    # сюда не дойдём
    raise RuntimeError(f"{desc} exhausted retries")

# ===== низкоуровневые вызовы =====
def _fetch_peers(c, w3: Web3, eoa: str) -> List[str]:
    eoa_cs = w3.to_checksum_address(eoa)
    try:
        res = _call_with_retry(c.functions.getPeerId([eoa_cs]).call, "getPeerId", )
        peers = res[0] if res and len(res) > 0 else []
        peers = [p.strip() for p in peers if p and p.strip()]
        log.info("[GSWARM-mini] EOA %s -> peers: %d", eoa, len(peers))
        return peers
    except Exception as e:
        log.error("[GSWARM-mini] getPeerId failed for %s: %s", eoa, e)
        return []

def _fetch_rewards_batch(c, peers: List[str]) -> Dict[str, int]:
    if not peers:
        return {}
    out: Dict[str, int] = {}
    # чанкование + паузы между чанками
    for i in range(0, len(peers), _REWARDS_CHUNK):
        chunk = peers[i:i+_REWARDS_CHUNK]
        try:
            vals = _call_with_retry(c.functions.getTotalRewards(chunk).call,
                                    f"getTotalRewards[{i}:{i+len(chunk)}]")
            out.update({p: int(v) for p, v in zip(chunk, vals)})
            log.info("[GSWARM-mini] getTotalRewards chunk ok: %d peers (offset %d)", len(chunk), i)
        except Exception as e:
            log.error("[GSWARM-mini] getTotalRewards chunk failed (%d peers @%d): %s", len(chunk), i, e)
            for p in chunk:
                out[p] = 0
        if i + _REWARDS_CHUNK < len(peers) and _CHUNK_PAUSE > 0:
            log.info("[GSWARM-mini] sleeping %.1fs between rewards chunks", _CHUNK_PAUSE)
            time.sleep(_CHUNK_PAUSE)
    return out

def _wins_votes_one(c, peer: str) -> Tuple[int, int]:
    wins = 0; votes = 0
    try:
        wins = int(_call_with_retry(c.functions.getTotalWins(peer).call, f"getTotalWins({peer})"))
    except Exception as e:
        log.warning("[GSWARM-mini] getTotalWins failed for %s: %s", peer, e)
    try:
        votes = int(_call_with_retry(c.functions.getVoterVoteCount(peer).call, f"getVoterVoteCount({peer})"))
    except Exception as e:
        log.warning("[GSWARM-mini] getVoterVoteCount failed for %s: %s", peer, e)
    return wins, votes

def _fetch_wins_votes_parallel(c, peers: List[str], max_workers: int = _MAX_WORKERS) -> Tuple[Dict[str, int], Dict[str, int]]:
    wins_map, votes_map = {}, {}
    if not peers:
        return wins_map, votes_map
    log.info("[GSWARM-mini] fetching wins/votes in parallel: peers=%d, workers=%d", len(peers), max_workers)
    # маленькая очередь, чтобы не шарашить сразу все вызовы
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs = []
        for p in peers:
            futs.append(ex.submit(_wins_votes_one, c, p))
            # микропаузка между постановкой задач
            if _PER_CALL_JITTER > 0:
                time.sleep(_PER_CALL_JITTER)
        for p, fut in zip(peers, as_completed({f: pid for pid, f in zip(peers, futs)})):
            try:
                w, v = fut.result()
            except Exception as e:
                log.error("[GSWARM-mini] wins/votes future error: %s", e)
                w, v = 0, 0
            wins_map[p] = w
            votes_map[p] = v
    log.info("[GSWARM-mini] wins/votes collected")
    return wins_map, votes_map

# ===== high-level по одному EOA =====
def get_gswarm_basic_for_eoa(eoa: str) -> dict:
    w3 = _w3()
    c = _contract(w3)
    peers = _fetch_peers(c, w3, eoa)
    rewards_map = _fetch_rewards_batch(c, peers)
    # enforce single-thread wins/votes by default (can override via GSWARM_MAX_WORKERS)
    _mw = int(os.environ.get("GSWARM_MAX_WORKERS", "1"))
    wins_map, votes_map = _fetch_wins_votes_parallel(c, peers, max_workers=_mw)
    totals = {"wins": 0, "rewards": 0, "votes": 0}
    items = []
    for pid in peers:
        w = wins_map.get(pid, 0)
        r = rewards_map.get(pid, 0)
        v = votes_map.get(pid, 0)
        totals["wins"] += w
        totals["rewards"] += r
        totals["votes"] += v
        items.append({"peer": pid, "wins": w, "rewards": r, "votes": v})
    log.info("[GSWARM-mini] EOA %s -> totals: wins=%s, rewards=%s, votes=%s, peers=%d",
             eoa, totals["wins"], totals["rewards"], totals["votes"], len(peers))
    return {"peers": items, "totals": totals, "total_nodes": len(peers)}

# ===== совместимость с app.py =====
def run_once(include_nodes: bool = False, send: bool = False, send_telegram: bool = False, **kwargs):
    _ = (include_nodes, send, send_telegram)
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    extra_peer_ids: List[str] = list(dict.fromkeys((kwargs.get("extra_peer_ids") or [])))
    extra_eoas: List[str] = list(dict.fromkeys((kwargs.get("extra_eoas") or [])))
    offchain_peer_map: Dict | None = kwargs.get("offchain_peer_map") or {}

    log.info("[GSWARM-mini] run_once: start ts=%s", ts)
    log.info("[GSWARM-mini] run_once: extra_eoas=%d, extra_peer_ids=%d, groups=%d",
             len(extra_eoas), len(extra_peer_ids), len(offchain_peer_map or {}))

    eoa_peers: Dict[str, List[str]] = {}
    all_peers: List[str] = []

    # обрабатываем EOA последовательно, с паузой между ними
    for idx, eoa in enumerate(extra_eoas, 1):
        try:
            basic = get_gswarm_basic_for_eoa(eoa)
        except Exception as e:
            log.error("[GSWARM-mini] basic build failed for %s: %s", eoa, e)
            basic = {"peers": [], "totals": {"wins": 0, "rewards": 0, "votes": 0}}
        peers = [p["peer"] for p in basic.get("peers", []) if p.get("peer")]
        eoa_norm = (eoa or "").strip().lower()
        if eoa_norm:
            eoa_peers[eoa_norm] = list(dict.fromkeys(peers))
        all_peers.extend(peers)

        # пауза между EOA
        if idx < len(extra_eoas) and _EOA_PAUSE > 0:
            log.info("[GSWARM-mini] pause between EOAs: sleeping %ds (idx=%d/%d)", _EOA_PAUSE, idx, len(extra_eoas))
            time.sleep(_EOA_PAUSE)

    if offchain_peer_map:
        for gkey, plist in offchain_peer_map.items():
            cnt = len(plist or [])
            all_peers.extend(plist or [])
            log.info("[GSWARM-mini] offchain group %r: +%d peers", gkey, cnt)

    if extra_peer_ids:
        all_peers.extend(extra_peer_ids)
        log.info("[GSWARM-mini] extra_peer_ids merged: +%d", len(extra_peer_ids))

    peers_unique: List[str] = []
    seen = set()
    for pid in all_peers:
        p = (pid or "").strip()
        if not p or p in seen:
            continue
        seen.add(p)
        peers_unique.append(p)

    log.info("[GSWARM-mini] total unique peers to query: %d", len(peers_unique))

    if not peers_unique:
        out = {
            "ok": True,
            "ts": ts,
            "per_peer": {},
            "eoa_peers": eoa_peers,
            "totals": {"wins": 0, "rewards": 0, "peers": 0},
        }
        log.info("[GSWARM-mini] run_once: nothing to query, done")
        return out

    # единичный проход по всем уникальным peers: wins/votes + rewards с чанкованием
    w3 = _w3()
    c = _contract(w3)

    _mw = int(os.environ.get("GSWARM_MAX_WORKERS", "1"))
    wins_map, _votes_map = _fetch_wins_votes_parallel(c, peers_unique, max_workers=_mw)
    rewards_map = _fetch_rewards_batch(c, peers_unique)

    per_peer: Dict[str, Dict] = {}
    tot_wins = 0
    tot_rewards = 0
    for pid in peers_unique:
        w = int(wins_map.get(pid, 0) or 0)
        r = int(rewards_map.get(pid, 0) or 0)
        per_peer[pid] = {"wins": w, "rewards": r}
        tot_wins += w
        tot_rewards += r

    out = {
        "ok": True,
        "ts": ts,
        "per_peer": per_peer,
        "eoa_peers": eoa_peers,
        "totals": {"wins": tot_wins, "rewards": tot_rewards, "peers": len(peers_unique)},
    }
    log.info("[GSWARM-mini] run_once: done peers=%d, total_wins=%s, total_rewards=%s",
             len(peers_unique), tot_wins, tot_rewards)
    return out
