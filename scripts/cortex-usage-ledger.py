#!/usr/bin/env python3
"""Cortex usage ledger v2 — comptage normalisé des sessions locales.

Lit les sources de vérité locales et écrit un agrégat requêtable dans
`~/.claudebar/usage/ledger.json`.

Contrat de normalisation (audit V2, lot A) :
- **Claude** : déduplication par `(message.id, requestId)`, dernière
  occurrence gagnante — c'est la règle de `ClaudeDailyUsageAnalyzer`. Un
  transcript réel répète le même message une fois par `apiBlockIndex` ; sans
  dédup la consommation est comptée plusieurs fois. Les entrées sans les deux
  identifiants sont conservées distinctes (jamais fusionnées au hasard).
- **Codex** : événements `token_usage_record`, dédupliqués par
  `(session_id, turn_id, response_id)`.
- **OpenCode** : agrégation **par message** (et non par session) pour dater
  l'usage réel ; `time_created` par message, tokens/cost dans la colonne JSON.
  Une source illisible produit un **statut**, jamais un zéro rassurant.
- **Fenêtres** : `today` (jour civil local), `last24h` (glissante sur les
  horodatages), `last7d` (glissante). Le dernier jour stocké n'est pas « les
  24 dernières heures ».
- **Coût** : `cost.kind` vaut `declared` (publié par la source) ou
  `unavailable` — un coût inconnu n'est pas 0.
- **Compteur remis à zéro = événement, jamais delta négatif** (T07). Une baisse
  de compteur cumulatif est bloquée à zéro et journalisée : au pire une reprise
  est manquée, jamais une consommation fictive produite.
- **Horloges** : les horodatages sont conservés en UTC et convertis une seule
  fois, à la sortie ; un changement d'heure locale ne doit pas créer d'heure
  inexistante ou répétée mal attribuée.

Usage :
    python3 scripts/cortex-usage-ledger.py [--days 7] [--print]
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sqlite3
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone

HOME = os.path.expanduser("~")
LEDGER_DIR = os.path.join(HOME, ".claudebar", "usage")
LEDGER_PATH = os.path.join(LEDGER_DIR, "ledger.json")
SCHEMA_VERSION = 2

TOOLS = ("claude", "codex", "opencode")
FIELDS = ("input", "output", "cache_read", "cache_creation", "reasoning")

OK, MISSING, PARTIAL = "ok", "missing", "partial"
PERMISSION_DENIED, UNSUPPORTED_SCHEMA, STALE = "permission_denied", "unsupported_schema", "stale"


# --------------------------------------------------------------------------- #
# Buckets
# --------------------------------------------------------------------------- #

def blank_bucket() -> dict:
    return {field: 0 for field in FIELDS} | {"messages": 0, "cost_usd": 0.0, "cost_declared": False}


def add_tokens(bucket: dict, tokens: dict, cost: float | None) -> None:
    for field in FIELDS:
        bucket[field] += int(tokens.get(field, 0) or 0)
    bucket["messages"] += 1
    if cost is not None:
        bucket["cost_usd"] += float(cost)
        bucket["cost_declared"] = True


def blank_windows(now: float, days: int) -> dict:
    local_now = datetime.fromtimestamp(now)
    midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    return {
        "today": {"start": midnight.timestamp(), "end": (midnight + timedelta(days=1)).timestamp()},
        "last24h": {"start": now - 86400, "end": now},
        "last7d": {"start": now - 7 * 86400, "end": now},
    }


class Ledger:
    """Accumulates deduplicated events into day buckets and time windows."""

    def __init__(self, now: float, days: int):
        self.now = now
        self.days: dict[str, dict[str, dict]] = defaultdict(lambda: defaultdict(blank_bucket))
        self.windows: dict[str, dict[str, dict]] = {
            name: defaultdict(blank_bucket) for name in ("today", "last24h", "last7d")
        }
        self.bounds = blank_windows(now, days)
        # Anomalies worth surfacing, never silently swallowed: negative deltas
        # in cumulative counters (T07) — one entry per (tool, field).
        self.anomalies: list[dict] = []

    def add(self, tool: str, when: float, tokens: dict, cost: float | None) -> None:
        day = datetime.fromtimestamp(when).strftime("%Y-%m-%d")
        add_tokens(self.days[day][tool], tokens, cost)
        for name, window in self.bounds.items():
            if window["start"] <= when < window["end"]:
                add_tokens(self.windows[name][tool], tokens, cost)
                self._guard_negative(name, tool, tokens, when)

    def _guard_negative(self, window: str, tool: str, tokens: dict, when: float) -> None:
        """A counter reset is an event, never negative consumption (T07).

        When a source hands back a smaller value than the one already counted,
        the alternative readings are "the counter wrapped/reset" (a start event
        for a new tally) or "the source re-reported". Subtracting would invent
        negative consumption, which is worse than the small clamp: at worst a
        little usage is missed, never a fictional total produced. The value is
        clamped to zero and the anomaly is recorded so it stays visible.
        """
        bucket = self.windows[window][tool]
        for field in FIELDS:
            raw = int(tokens.get(field, 0) or 0)
            if raw < 0:
                bucket[field] -= raw  # undo the negative that add_tokens applied
                self.anomalies.append({
                    "window": window,
                    "tool": tool,
                    "kind": "counter_reset",
                    "field": field,
                    "value": raw,
                    "when": when,
                })


def status(state: str, **extra) -> dict:
    return {"status": state, **extra}


# --------------------------------------------------------------------------- #
# Sources
# --------------------------------------------------------------------------- #

def iter_jsonl(path: str):
    try:
        with open(path, "r", errors="ignore") as handle:
            for line in handle:
                if '"usage"' not in line and '"token' not in line:
                    continue
                try:
                    yield json.loads(line)
                except Exception:
                    continue
    except PermissionError:
        raise
    except OSError:
        return


def parse_iso(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def collect_claude(ledger: Ledger, since: float) -> dict:
    """~/.claude/projects/**/*.jsonl — dedup (message.id, requestId) last-wins."""
    files = 0
    try:
        paths = glob.glob(os.path.join(HOME, ".claude", "projects", "**", "*.jsonl"), recursive=True)
    except OSError as exc:  # pragma: no cover - filesystem level
        return status(PARTIAL, error=str(exc))
    last_seen = None
    for path in paths:
        try:
            if os.path.getmtime(path) < since - 86400:
                continue
        except OSError:
            continue
        files += 1
        # Last-wins per (message.id, requestId); unkeyed records stay distinct.
        order: list = []
        last: dict = {}
        unkeyed = 0
        for obj in _claude_records(path):
            message = obj.get("message") or {}
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue
            when = parse_iso(obj.get("timestamp"))
            if when is None:
                continue
            message_id, request_id = message.get("id"), obj.get("requestId")
            if message_id and request_id:
                key = ("k", message_id, request_id)
            else:
                unkeyed += 1
                key = ("u", path, unkeyed)
            if key not in last:
                order.append(key)
            last[key] = (when, usage)
        for key in order:
            when, usage = last[key]
            if when < since:
                continue
            last_seen = max(last_seen or when, when)
            ledger.add("claude", when, {
                "input": usage.get("input_tokens", 0),
                "output": usage.get("output_tokens", 0),
                "cache_read": usage.get("cache_read_input_tokens", 0),
                "cache_creation": usage.get("cache_creation_input_tokens", 0),
            }, None)
    return status(OK if files else MISSING, files=files,
                  last_observed_at=_iso(last_seen))


def _claude_records(path: str):
    try:
        yield from iter_jsonl(path)
    except PermissionError:
        return


def collect_codex(ledger: Ledger, since: float) -> dict:
    """~/.codex/sessions/**/*.jsonl — dedup (session_id, turn_id, response_id)."""
    files = 0
    paths = glob.glob(os.path.join(HOME, ".codex", "sessions", "**", "*.jsonl"), recursive=True)
    last_seen = None
    for path in paths:
        try:
            if os.path.getmtime(path) < since - 86400:
                continue
        except OSError:
            continue
        files += 1
        seen: set = set()
        for obj in iter_jsonl(path):
            if obj.get("type") != "token_usage_record":
                continue
            payload = obj.get("payload") or {}
            usage = payload.get("usage") or {}
            when = parse_iso(obj.get("timestamp"))
            if when is None or when < since:
                continue
            key = (payload.get("session_id"), payload.get("turn_id"), payload.get("response_id"))
            if any(key) and key in seen:
                continue
            seen.add(key)
            last_seen = max(last_seen or when, when)
            ledger.add("codex", when, {
                "input": usage.get("input_tokens", 0),
                "output": usage.get("output_tokens", 0),
                "cache_read": usage.get("cached_input_tokens", 0),
                "reasoning": usage.get("reasoning_output_tokens", 0),
            }, None)
    return status(OK if files else MISSING, files=files,
                  last_observed_at=_iso(last_seen))


def collect_opencode(ledger: Ledger, since: float) -> dict:
    """opencode.db — per-message rows (usage-dated), read-only and bounded."""
    db = os.path.join(HOME, ".local", "share", "opencode", "opencode.db")
    if not os.path.exists(db):
        return status(MISSING, detail="opencode.db not found")
    rows = 0
    last_seen = None
    try:
        connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        connection.execute("PRAGMA query_only=ON")
        try:
            # Filter in SQL, not in Python: a bare `SELECT time_created, data`
            # materializes the whole 28 GB table before the first row is
            # discarded. On 2026-09-27 that fetch was observed collapsing with
            # `unable to open database file` on a DB whose free pages alone
            # exceed the process's materialization headroom, and it re-read
            # ~4.5k assistant rows per run to keep ~2.4k. The role lives under
            # `data.role` (JSON), so `json_extract` is the contract-visible
            # filter. `LIKE '%"tokens"%'` is only a cheap pre-narrow (guarded:
            # tokens values are JSON objects, never strings).
            cursor = connection.execute(
                "SELECT time_created, data FROM message "
                "WHERE time_created >= ? "
                "AND json_extract(data, '$.role') = 'assistant' "
                "AND data LIKE '%\"tokens\"%'",
                (int((since - 86400) * 1000),),
            )
        except sqlite3.OperationalError as exc:
            return status(UNSUPPORTED_SCHEMA, error=str(exc))
        for created_ms, raw in cursor:
            try:
                payload = json.loads(raw) if isinstance(raw, str) else (raw or {})
            except (TypeError, ValueError):
                continue
            tokens = payload.get("tokens") or {}
            cache = tokens.get("cache") or {}
            role = payload.get("role")
            if role != "assistant" or not tokens:
                continue
            when = (created_ms or 0) / 1000
            if when < since:
                continue
            rows += 1
            last_seen = max(last_seen or when, when)
            ledger.add("opencode", when, {
                "input": tokens.get("input", 0),
                "output": tokens.get("output", 0),
                "reasoning": tokens.get("reasoning", 0),
                "cache_read": cache.get("read", 0),
                "cache_creation": cache.get("write", 0),
            }, payload.get("cost"))
        connection.close()
    except sqlite3.OperationalError as exc:
        return status(UNSUPPORTED_SCHEMA, error=str(exc))
    except sqlite3.Error as exc:
        return status(PARTIAL, error=str(exc))
    return status(OK if rows else MISSING, messages=rows, last_observed_at=_iso(last_seen))


def _iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, timezone.utc).astimezone().isoformat()


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

def serialize_bucket(bucket: dict) -> dict:
    out = {field: bucket[field] for field in FIELDS}
    out["messages"] = bucket["messages"]
    out["cost"] = {
        "kind": "declared" if bucket["cost_declared"] else "unavailable",
        "usd": round(bucket["cost_usd"], 6) if bucket["cost_declared"] else None,
    }
    return out


def serialize(bucket_map: dict) -> dict:
    return {tool: serialize_bucket(bucket_map[tool]) for tool in bucket_map if bucket_map[tool]["messages"]}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--print", action="store_true", dest="show")
    args = parser.parse_args()

    now = time.time()
    since = now - args.days * 86400
    ledger = Ledger(now, args.days)

    sources = {
        "claude": collect_claude(ledger, since),
        "codex": collect_codex(ledger, since),
        "opencode": collect_opencode(ledger, since),
    }

    payload = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.fromtimestamp(now, timezone.utc).isoformat(),
        "history_days": args.days,
        "dedup": {
            "claude": "(message.id, requestId) last-wins",
            "codex": "(session_id, turn_id, response_id)",
            "opencode": "per assistant message row",
        },
        "sources": sources,
        "windows": {
            name: {
                "start": datetime.fromtimestamp(bounds["start"], timezone.utc).astimezone().isoformat(),
                "end": datetime.fromtimestamp(bounds["end"], timezone.utc).astimezone().isoformat(),
                "tools": serialize(ledger.windows[name]),
            }
            for name, bounds in ledger.bounds.items()
        },
        "days": {day: serialize(tools) for day, tools in sorted(ledger.days.items())},
        "anomalies": ledger.anomalies,
    }

    os.makedirs(LEDGER_DIR, exist_ok=True)
    tmp = LEDGER_PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
    os.replace(tmp, LEDGER_PATH)

    if args.show:
        for name in ("today", "last24h", "last7d"):
            window = payload["windows"][name]
            print(f"== {name}  [{window['start'][:19]} → {window['end'][:19]}]")
            for tool, bucket in window["tools"].items():
                total = sum(bucket[field] for field in FIELDS)
                cost = bucket["cost"]
                cost_label = f"${cost['usd']:.2f}" if cost["kind"] == "declared" else "cost n/a"
                print(f"   {tool:9s} {total/1e6:10.1f}M  cache_read {bucket['cache_read']/1e6:9.1f}M"
                      f"  {bucket['messages']:>6} msgs  {cost_label}")
        print("sources:", {k: v["status"] for k, v in sources.items()})
    print(f"ledger: {LEDGER_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
