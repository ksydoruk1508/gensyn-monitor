#!/usr/bin/env python3
# gswarm_checker.py — упрощённая логика получения данных (Wins / Rewards / Peers),
# совместимая с app.py gensyn-monitor

import os
import json
from datetime import datetime
from typing import Dict, List, Tuple
from concurrent.futures import ThreadPoolExecutor, as_completed
from web3 import Web3


# === Настройки и ABI ===
_RPC_URL = os.environ.get("RPC_URL", "https://gensyn-testnet.g.alchemy.com/public")
_SWARM_COORDINATOR = os.environ.get(
    "SWARM_COORDINATOR_ADDR",
    "0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
)

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


# === Базовые утилиты ===
def _w3() -> Web3:
    w = Web3(Web3.HTTPProvider(_RPC_URL))
    if not w.is_connected():
        raise RuntimeError(f"RPC недоступен: {_RPC_URL}")
    return w


def _contract(w3: Web3):
    return w3.eth.contract(address=w3.to_checksum_address(_SWARM_COORDINATOR), abi=_ABI)


# === Простая логика получения Peers / Wins / Rewards ===
def _fetch_peers(c, w3: Web3, eoa: str) -> List[str]:
    try:
        res = c.functions.getPeerId([w3.to_checksum_address(eoa)]).call()
        peers = res[0] if res and len(res) > 0 else []
        return [p for p in peers if p and p.strip()]
    except Exception:
        return []


def _fetch_rewards_batch(c, peers: List[str]) -> Dict[str, int]:
    if not peers:
        return {}
    try:
        vals = c.functions.getTotalRewards(peers).call()
        return {p: int(v) for p, v in zip(peers, vals)}
    except Exception:
        return {p: 0 for p in peers}


def _wins_votes_one(c, peer: str) -> Tuple[int, int]:
    try:
        wins = int(c.functions.getTotalWins(peer).call())
    except Exception:
        wins = 0
    try:
        votes = int(c.functions.getVoterVoteCount(peer).call())
    except Exception:
        votes = 0
    return wins, votes


def _fetch_wins_votes_parallel(c, peers: List[str], max_workers: int = 16) -> Tuple[Dict[str, int], Dict[str, int]]:
    wins_map, votes_map = {}, {}
    if not peers:
        return wins_map, votes_map
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs = {ex.submit(_wins_votes_one, c, p): p for p in peers}
        for fut in as_completed(futs):
            p = futs[fut]
            try:
                w, v = fut.result()
            except Exception:
                w, v = 0, 0
            wins_map[p] = w
            votes_map[p] = v
    return wins_map, votes_map


def get_gswarm_basic_for_eoa(eoa: str) -> dict:
    """Возвращает простую структуру без ранга."""
    w3 = _w3()
    c = _contract(w3)

    peers = _fetch_peers(c, w3, eoa)
    rewards_map = _fetch_rewards_batch(c, peers)
    wins_map, votes_map = _fetch_wins_votes_parallel(c, peers)

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

    return {"peers": items, "totals": totals, "total_nodes": len(peers)}


# === Ранги ===
_LEADERBOARD_ABI = [{
    "inputs": [
        {"internalType": "uint256", "name": "start", "type": "uint256"},
        {"internalType": "uint256", "name": "end", "type": "uint256"}
    ],
    "name": "winnerLeaderboard",
    "outputs": [
        {"internalType": "string[]", "name": "peerIds", "type": "string[]"},
        {"internalType": "uint256[]", "name": "wins", "type": "uint256[]"}
    ],
    "stateMutability": "view",
    "type": "function"
}]


def _contract_lb(w3: Web3):
    return w3.eth.contract(address=w3.to_checksum_address(_SWARM_COORDINATOR),
                           abi=_LEADERBOARD_ABI + _ABI)


def _find_ranks_for_peers(peer_ids, limit=50000, step=100):
    if not peer_ids:
        return {}
    w3 = _w3()
    c = _contract_lb(w3)
    target = set(peer_ids)
    ranks = {p: None for p in peer_ids}
    cur_rank = 1

    for start in range(0, limit, step):
        end = start + step
        try:
            ids, _wins = c.functions.winnerLeaderboard(start, end).call()
        except Exception:
            break
        if not ids:
            break
        for pid in ids:
            if pid in target:
                ranks[pid] = cur_rank
                target.remove(pid)
            cur_rank += 1
        if not target:
            break
    return ranks


# === Вспомогательные функции ===
def _load_eoas_from_node_map():
    raw = os.environ.get("GSWARM_NODE_MAP", "") or ""
    eoas = []
    try:
        if raw.strip():
            data = json.loads(raw)
            for _name, entry in (data or {}).items():
                eoa = (entry or {}).get("eoa", "")
                if eoa:
                    eoas.append(eoa)
    except Exception:
        pass

    seen = set()
    uniq = []
    for e in eoas:
        ee = e.lower()
        if ee not in seen:
            seen.add(ee)
            uniq.append(e)
    return uniq


# === Главная функция для app.py ===
def run_once(include_nodes: bool = False, send: bool = False, send_telegram: bool = False, **kwargs):
    """
    Совместимый с app.py формат результата:
      {
        "ok": True,
        "ts": "YYYY-mm-dd HH:MM:SS",
        "per_peer": { "<peerId>": {"wins": int, "rewards": int, "rank": int|None }, ... },
        "eoa_peers": { "<eoa_lower>": ["peerId", ...], ... },
        "totals": {"wins": int, "rewards": int, "peers": int}
      }
    """
    _ = (include_nodes, send, send_telegram)  # для совместимости

    # входы, которые app.py прокидывает в run_once()
    extra_peer_ids: list[str] = list(dict.fromkeys((kwargs.get("extra_peer_ids") or [])))
    extra_eoas: list[str] = list(dict.fromkeys((kwargs.get("extra_eoas") or [])))
    # offchain_peer_map: {tgid(str|None): [peerId,...]}
    offchain_peer_map: dict | None = kwargs.get("offchain_peer_map") or {}

    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")

    # 1) соберём peers по EOA напрямую из контракта
    eoa_peers: dict[str, list[str]] = {}
    all_peers: list[str] = []

    for eoa in extra_eoas:
        try:
            basic = get_gswarm_basic_for_eoa(eoa)
        except Exception:
            basic = {"peers": []}
        peers = [p["peer"] for p in basic.get("peers", []) if p.get("peer")]
        eoa_norm = (eoa or "").strip().lower()
        if eoa_norm:
            eoa_peers[eoa_norm] = list(dict.fromkeys(peers))
        all_peers.extend(peers)

    # 2) добавим оффчейн-группы (например, сгруппированные по tgid)
    if offchain_peer_map:
        for _k, plist in offchain_peer_map.items():
            if plist:
                all_peers.extend(plist)

    # 3) добавим явные extra_peer_ids
    if extra_peer_ids:
        all_peers.extend(extra_peer_ids)

    # нормализуем общее множество peerId
    peers_unique: list[str] = []
    seen = set()
    for pid in all_peers:
        p = (pid or "").strip()
        if not p or p in seen:
            continue
        seen.add(p)
        peers_unique.append(p)

    # если совсем нечего — вернём пустой результат
    if not peers_unique:
        return {
            "ok": True,
            "ts": ts,
            "per_peer": {},
            "eoa_peers": eoa_peers,
            "totals": {"wins": 0, "rewards": 0, "peers": 0},
        }

    # 4) одним махом вытащим wins/votes и rewards для всех peerId
    w3 = _w3()
    c = _contract(w3)
    wins_map, _votes_map = _fetch_wins_votes_parallel(c, peers_unique)
    rewards_map = _fetch_rewards_batch(c, peers_unique)

    # 5) посчитаем ранги через лидерборд
    ranks_map = _find_ranks_for_peers(peers_unique)

    # 6) соберём "per_peer" и агрегаты
    per_peer: dict[str, dict] = {}
    tot_wins = 0
    tot_rewards = 0
    for pid in peers_unique:
        w = int(wins_map.get(pid, 0) or 0)
        r = int(rewards_map.get(pid, 0) or 0)
        rk = ranks_map.get(pid)
        per_peer[pid] = {"wins": w, "rewards": r, "rank": rk}
        tot_wins += w
        tot_rewards += r

    return {
        "ok": True,
        "ts": ts,
        "per_peer": per_peer,
        "eoa_peers": eoa_peers,
        "totals": {"wins": tot_wins, "rewards": tot_rewards, "peers": len(peers_unique)},
        # поля ниже app.py не нужны, но оставим чтобы не путаться
        "include_nodes": bool(include_nodes),
        "sent": bool(send),
    }

    return {
        "ok": True,
        "timestamp": ts,
        "wallets": results,
        "summary": total_summary,
        "include_nodes": bool(include_nodes),
        "sent": bool(send)
    }
