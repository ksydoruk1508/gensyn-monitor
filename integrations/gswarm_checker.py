# integrations/gswarm_checker.py
import os, json, datetime, time, urllib.parse, urllib.request, urllib.error
from pathlib import Path
from urllib.error import HTTPError, URLError
from typing import List, Dict, Any, Tuple, Set, Iterator
from web3 import Web3
from dotenv import load_dotenv

# Ensure local .env is loaded even when this module is imported before the main app calls load_dotenv().
load_dotenv()

# === Конфиг из env (с дефолтами для dev) ======================================
ETH_RPC_URL = os.getenv("GSWARM_ETH_RPC_URL", "https://gensyn-testnet.g.alchemy.com/public")
EOA_ADDRESSES = [a.strip() for a in os.getenv("GSWARM_EOAS", "").split(",") if a.strip()]
PROXIES = [p.strip() for p in os.getenv("GSWARM_PROXIES", "").split(",") if p.strip()] or [
    "0xFaD7C5e93f28257429569B854151A1B8DCD404c2",
    "0x7745a8FE4b8D2D2c3BB103F8dCae822746F35Da0",
    "0x69C6e1D608ec64885E7b185d39b04B491a71768C",
]

# off-chain (gswarm.dev) — нужен Telegram ID пользователя
GSWARM_TGID = os.getenv("GSWARM_TGID", "")  # пусто = выключено

# Telegram
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID   = os.getenv("TELEGRAM_CHAT_ID", "")

# Состояние дельт (куда сохраняем последние показанные wins/rewards)
STATE_FILE = Path(os.getenv("GSWARM_STATE_FILE", "data/gswarm_state.json"))
STATE_FILE.parent.mkdir(parents=True, exist_ok=True)

# Сухой прогон (не слать в Telegram)
DRY_RUN = os.getenv("GSWARM_DRY_RUN", "0") == "1"

# Управление отображением "Problems" и подписи источников
_SHOW_PROBLEMS_RAW = os.getenv("GSWARM_SHOW_PROBLEMS", "0")
_SHOW_SRC_MODE_RAW = os.getenv("GSWARM_SHOW_SRC", "auto").strip().lower()  # auto|always|never

ABI = [
  {"inputs":[{"internalType":"address[]","name":"eoas","type":"address[]"}],
   "name":"getPeerId","outputs":[{"internalType":"string[][]","name":"","type":"string[][]"}],
   "stateMutability":"view","type":"function"},
  {"inputs":[{"internalType":"string","name":"peerId","type":"string"}],
   "name":"getTotalWins","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],
   "stateMutability":"view","type":"function"},
  {"inputs":[{"internalType":"string","name":"peerId","type":"string"}],
   "name":"getTotalRewards","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],
   "stateMutability":"view","type":"function"},
]

def _short(pid: str) -> str:
    return f"{pid[:3]}...{pid[-3:]}" if len(pid) > 8 else pid

def _truthy(val: str | None, default: bool = False) -> bool:
    if val is None:
        return default
    return val.strip().lower() not in {"", "0", "false", "no", "off"}

SHOW_PROBLEMS = _truthy(_SHOW_PROBLEMS_RAW, False)
SHOW_SRC_MODE = _SHOW_SRC_MODE_RAW if _SHOW_SRC_MODE_RAW in {"auto", "always", "never"} else "auto"

def _chunks(seq: List[str], size: int) -> Iterator[List[str]]:
    for i in range(0, len(seq), size):
        yield seq[i:i + size]

def _dmark(delta: int | None) -> str:
    if delta is None: return ""
    return f" 📈 (+{delta})" if delta > 0 else (f" 📉 ({delta})" if delta < 0 else " ➡️ (0)")

def _load_prev() -> Dict[str, Dict[str, int]]:
    if not STATE_FILE.exists(): return {}
    try: return json.loads(STATE_FILE.read_text())
    except Exception: return {}

def _save_state(per_peer: Dict[str, Dict[str, int]]) -> None:
    STATE_FILE.write_text(json.dumps(per_peer, indent=2))

def _send_html(html: str) -> bytes:
    if DRY_RUN or not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return b"DRY_RUN"
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": TELEGRAM_CHAT_ID, "text": html, "parse_mode": "HTML"}).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=15) as r:
        return r.read()

def _fetch_offchain(peer_ids: List[str], tgid: str | None = None) -> Tuple[Dict[str, Dict[str, int]], Dict[str, int]]:
    """Стабильный сбор оффчейна: батчи, ретраи, частичные успехи."""
    per: Dict[str, Dict[str, int]] = {}
    totals = {"wins": 0, "rewards": 0}
    if not peer_ids:
        return per, totals

    normalized: List[str] = []
    seen = set()
    for raw in peer_ids:
        pid = str(raw).strip() if raw is not None else ""
        if not pid or pid in seen:
            continue
        seen.add(pid)
        normalized.append(pid)
    if not normalized:
        return per, totals

    target_tgid = tgid
    if target_tgid is not None and not isinstance(target_tgid, str):
        target_tgid = str(target_tgid)
    if target_tgid:
        target_tgid = target_tgid.strip()
    if not target_tgid:
        target_tgid = GSWARM_TGID
    if not target_tgid:
        return per, totals

    BATCH_SIZE = 100
    RETRIES = 2  # доп. повторы помимо основной попытки
    BACKOFF = 0.4

    for chunk in _chunks(normalized, BATCH_SIZE):
        attempt = 0
        while True:
            req = urllib.request.Request(
                "https://gswarm.dev/api/user/data",
                data=json.dumps({"peerIds": chunk}).encode(),
                headers={"Content-Type": "application/json", "X-Telegram-ID": target_tgid},
            )
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    payload = json.loads(r.read().decode())
                for item in payload.get("ranks", []) or []:
                    pid = item.get("peerId")
                    if not pid:
                        continue
                    wins = int(item.get("totalWins") or 0)
                    rewards = int(item.get("totalRewards") or 0)
                    rank = int(item.get("rank") or 0)
                    entry = per.setdefault(pid, {"wins": 0, "rewards": 0, "rank": 0})
                    entry["wins"] += wins
                    entry["rewards"] += rewards
                    if not entry["rank"] and rank:
                        entry["rank"] = rank
                    totals["wins"] += wins
                    totals["rewards"] += rewards
                break
            except HTTPError as exc:
                code = getattr(exc, "code", None)
                if code in {429, 500, 502, 503, 504} and attempt < RETRIES:
                    time.sleep(BACKOFF * (attempt + 1))
                    attempt += 1
                    continue
                break
            except (URLError, TimeoutError, json.JSONDecodeError, ValueError):
                if attempt < RETRIES:
                    time.sleep(BACKOFF * (attempt + 1))
                    attempt += 1
                    continue
                break

    return per, totals

def run_once(
    send_telegram: bool = False,
    extra_peer_ids: List[str] | None = None,
    extra_eoas: List[str] | None = None,
    offchain_peer_map: Dict[str | None, List[str]] | None = None,
) -> Dict[str, Any]:
    """Основной запуск: собирает peers (включая переданные явно) → on-chain → off-chain → HTML.
    Возвращает словарь с данными и HTML. При send_telegram=True отправляет в Telegram."""
    w3 = Web3(Web3.HTTPProvider(ETH_RPC_URL))

    extra_peer_ids = [p.strip() for p in (extra_peer_ids or []) if p.strip()]
    extra_eoas = [e.strip() for e in (extra_eoas or []) if e.strip()]
    eoas = list(dict.fromkeys([*EOA_ADDRESSES, *extra_eoas]))

    # peers из всех прокси и всех EOA, плюс карта EOA -> peerIds
    peers: list[str] = []
    eoa_map: Dict[str, List[str]] = {}
    for px in PROXIES:
        c = w3.eth.contract(address=Web3.to_checksum_address(px), abi=ABI)
        for eoa in eoas or []:
            try:
                e = Web3.to_checksum_address(eoa)
                got = c.functions.getPeerId([e]).call()
                fetched = [p for p in (got[0] if got else []) if p]
                if fetched:
                    peers += fetched
                    key = e.lower()
                    eoa_map.setdefault(key, [])
                    eoa_map[key].extend(fetched)
            except Exception:
                pass
    peers = list(dict.fromkeys(peers))
    for eoa_key, plist in list(eoa_map.items()):
        eoa_map[eoa_key] = list(dict.fromkeys(plist))
    if extra_peer_ids:
        peers = list(dict.fromkeys([*peers, *extra_peer_ids]))
    peer_groups: Dict[str | None, List[str]] = {}
    if offchain_peer_map:
        grouped_set: Set[str] = set()
        for raw_key, values in offchain_peer_map.items():
            local_seen: Set[str] = set()
            deduped: List[str] = []
            for pid in values or []:
                pid_clean = (pid or "").strip()
                if not pid_clean or pid_clean in local_seen:
                    continue
                local_seen.add(pid_clean)
                deduped.append(pid_clean)
            if not deduped:
                continue
            key_norm: str | None
            if raw_key is None or (isinstance(raw_key, str) and not raw_key.strip()):
                key_norm = None
            else:
                key_norm = str(raw_key).strip()
                if not key_norm:
                    key_norm = None
            peer_groups[key_norm] = deduped
            grouped_set.update(deduped)
        if grouped_set:
            peers = list(dict.fromkeys([*peers, *grouped_set]))
        if peers:
            remaining = [pid for pid in peers if pid not in grouped_set]
            if remaining:
                base_default = peer_groups.get(None, [])
                merged_default = list(dict.fromkeys([*base_default, *remaining]))
                peer_groups[None] = merged_default
    else:
        peer_groups = {}

    # on-chain wins/rewards (rewards может отсутствовать)
    on_wins = {pid: 0 for pid in peers}
    on_rew  = {pid: None for pid in peers}  # None = нет метода/ошибка
    for px in PROXIES:
        c = w3.eth.contract(address=Web3.to_checksum_address(px), abi=ABI)
        for pid in peers:
            try:
                on_wins[pid] += int(c.functions.getTotalWins(pid).call())
            except Exception:
                pass
            try:
                r = int(c.functions.getTotalRewards(pid).call())
                on_rew[pid] = (on_rew[pid] or 0) + r
            except Exception:
                pass

    # off-chain
    off_per: Dict[str, Dict[str, Any]] = {}
    off_totals = {"wins": 0, "rewards": 0}
    if peer_groups:
        is_verified = False
        for tgid_key, ids in peer_groups.items():
            chunk_per, chunk_totals = _fetch_offchain(ids, tgid_key)
            if chunk_per:
                is_verified = True
            off_per.update(chunk_per)
            off_totals["wins"] += int(chunk_totals.get("wins", 0) or 0)
            off_totals["rewards"] += int(chunk_totals.get("rewards", 0) or 0)
    else:
        off_per, off_totals = _fetch_offchain(peers)
        is_verified = bool(off_per)

    # финальные значения
    per_peer: Dict[str, Dict[str, Any]] = {}
    for pid in peers:
        w_on = int(on_wins.get(pid, 0))
        w_off = int(off_per.get(pid, {}).get("wins", 0))
        wins_final = w_on if w_on > 0 else w_off

        r_on = on_rew.get(pid, None)
        if r_on is None:
            rewards_final = int(off_per.get(pid, {}).get("rewards", 0))
            rewards_src = "off"
        else:
            rewards_final = int(r_on)
            rewards_src = "on"

        per_peer[pid] = {
            "wins": wins_final,
            "wins_src": "on" if w_on > 0 else ("off" if w_off>0 else "none"),
            "rewards": rewards_final,
            "rewards_src": rewards_src,
            "rank": int(off_per.get(pid, {}).get("rank", 0)) or None
        }

    prev = _load_prev()
    total_wins = sum(v["wins"] for v in per_peer.values())
    total_rew  = sum(v["rewards"] for v in per_peer.values())
    prev_total_wins = sum(int(prev.get(pid, {}).get("wins", 0)) for pid in peers)
    prev_total_rew  = sum(int(prev.get(pid, {}).get("rewards", 0)) for pid in peers)
    d_total_wins = total_wins - prev_total_wins
    d_total_rew  = total_rew  - prev_total_rew

    ts = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    html = []
    html.append("<b>🚀 G-Swarm Update</b>\n\n")
    html.append("✅ Verified User\n" if is_verified else "❌ Not Verified (no off-chain)\n")
    html.append(f"📊 Total Nodes: <b>{len(peers)}</b>\n")
    ranked_nodes = sum(1 for p in per_peer.values() if p["wins"]>0)
    html.append(f"🏆 Ranked Nodes: <b>{ranked_nodes}</b>\n\n")
    html.append("<b>📊 Blockchain Data Update</b>\n")

    display_eoas: List[str] = []
    seen_eoas: Set[str] = set()

    def _push_eoa(candidate: str | None) -> None:
        if not candidate:
            return
        value = candidate.strip()
        if not value:
            return
        try:
            chk = Web3.to_checksum_address(value)
        except Exception:
            chk = value
        key = chk.lower()
        if key not in seen_eoas:
            seen_eoas.add(key)
            display_eoas.append(chk)

    for e in EOA_ADDRESSES:
        _push_eoa(e)
    for e in extra_eoas:
        _push_eoa(e)
    for e in eoa_map.keys():
        _push_eoa(e)

    if display_eoas:
        if len(display_eoas) == 1:
            html.append(f"👤 EOA Address: <code>{display_eoas[0]}</code>\n")
        else:
            html.append("👤 EOA Addresses:\n")
            for addr in display_eoas:
                html.append(f"• <code>{addr}</code>\n")
    else:
        html.append("👤 EOA Address: —\n")

    html.append(f"🔍 Peer IDs Monitored: <b>{len(peers)}</b>\n\n")
    html.append(f"📈 Total Votes: <b>{total_wins}</b>{_dmark(d_total_wins)}\n")
    html.append(f"💰 Total Rewards: <b>{total_rew}</b>{_dmark(d_total_rew)}\n")
    html.append(f"🎯 Total Wins: <b>{total_wins}</b>{_dmark(d_total_wins)}\n\n")

    if peers:
        html.append("<b>📋 Per-Peer Breakdown:</b>\n")
        ordered = sorted(per_peer.items(), key=lambda kv: kv[1]["wins"], reverse=True)
        total_peers = len(ordered)
        for idx, (pid, v) in enumerate(ordered, 1):
            pprev = prev.get(pid, {})
            dw = v["wins"] - int(pprev.get("wins", 0))
            dr = v["rewards"] - int(pprev.get("rewards", 0))
            html.append(f"🔹 Peer {idx}: <code>{_short(pid)}</code>\n")
            html.append(f"   📈 Votes: <b>{v['wins']}</b>{_dmark(dw)}\n")
            html.append(f"   💰 Rewards: <b>{v['rewards']}</b>{_dmark(dr)}\n")
            html.append(f"   🎯 Wins: <b>{v['wins']}</b>{_dmark(dw)}\n")
            if v.get("rank"):
                html.append(f"   🏆 Rank: #{v['rank']}\n")

            # аккуратный вывод src: с пустой строкой и только когда это полезно
            src_bits = []
            if v["wins_src"] != "none":
                src_bits.append(f"wins:{v['wins_src']}")
            src_bits.append(f"rewards:{v['rewards_src']}")
            src_bits_str = ", ".join(src_bits)

            needs_src = (SHOW_SRC_MODE == "always") or (
                SHOW_SRC_MODE == "auto"
                and (v["wins_src"] in ("off", "none") or v["rewards_src"] != "on")
            )
            if needs_src and SHOW_SRC_MODE != "never":
                html.append(f"   <i>src: {src_bits_str}</i>\n")
            if idx < total_peers:
                html.append("\n")
    else:
        html.append("📋 Per-Peer Breakdown: —\n")

    # Блок проблем: по флагу и "умнее" критерий
    if SHOW_PROBLEMS:
        zero_peers_list = []
        for pid, v in per_peer.items():
            if v["wins"] == 0 and v.get("rewards", 0) == 0 and not v.get("rank"):
                zero_peers_list.append(_short(pid))
        if zero_peers_list:
            html.append("\n<b>⚠️ Problems:</b>\n")
            html.append(
                "• Peers с нулевыми победами: " +
                ", ".join(f"<code>{p}</code>" for p in zero_peers_list) + "\n"
            )

    html.append(f"\n⏰ Last Check: <code>{ts}</code>")
    html_text = "".join(html)

    # отправка и сохранение состояния
    sent = False
    send_error = None
    if send_telegram:
        try:
            _send_html(html_text)
            sent = True
        except HTTPError as e:
            send_error = f"HTTP {e.code}: {e.read().decode(errors='ignore')}"
        except Exception as e:
            send_error = str(e)

    _save_state({pid: {"wins": v["wins"], "rewards": v["rewards"]} for pid, v in per_peer.items()})

    return {
        "peers": peers,
        "per_peer": per_peer,
        "totals": {"wins": total_wins, "rewards": total_rew, "dwins": d_total_wins, "drewards": d_total_rew},
        "verified": is_verified,
        "offchain_totals": off_totals,
        "offchain_groups": {key: ids for key, ids in peer_groups.items()},
        "html": html_text,
        "sent": sent,
        "send_error": send_error,
        "ts": ts,
        "eoa_peers": eoa_map,
    }

if __name__ == "__main__":
    # локальный прогон: GSWARM_DRY_RUN=1 python -m integrations.gswarm_checker
    res = run_once(send_telegram=True)
    print(json.dumps({k:v for k,v in res.items() if k!="html"}, indent=2, ensure_ascii=False))
    print("\n=== PREVIEW (HTML) ===\n" + res["html"])
