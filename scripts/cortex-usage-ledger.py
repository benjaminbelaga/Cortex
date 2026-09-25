#!/usr/bin/env python3
"""Cortex usage ledger — centralise la consommation réelle des sessions locales.

Lit les sources de vérité locales (transcripts Claude, rollouts Codex, base
OpenCode) et écrit un agrégat par jour/outil dans
`~/.claudebar/usage/ledger.json`, requêtable (jq) et réutilisé par l'app.

Pourquoi ce fichier existe (Ben 2026-09-26) : le chiffre « 24h » affiché par
Cortex venait de `usage.24h` du snapshot llm-router, c.-à-d. du **seul trafic
routé** (≈512 M/j), alors que les transcripts Claude locaux montraient ≈1,1 Md
sur la même fenêtre, Codex/OpenCode/cmux non comptés. Ce ledger est la source
locale, jamais une estimation.

Usage :
    python3 scripts/cortex-usage-ledger.py            # met à jour le ledger
    python3 scripts/cortex-usage-ledger.py --print     # + résumé 24h/7j
    python3 scripts/cortex-usage-ledger.py --days 30   # profondeur d'historique
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import time
from collections import defaultdict
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
LEDGER_DIR = os.path.join(HOME, ".claudebar", "usage")
LEDGER_PATH = os.path.join(LEDGER_DIR, "ledger.json")

FIELDS = ("input", "output", "cache_read", "cache_creation", "reasoning")


def _iter_jsonl(path):
    try:
        with open(path, "r", errors="ignore") as handle:
            for line in handle:
                if '"usage"' not in line and '"token' not in line and '"tokens"' not in line:
                    continue
                try:
                    yield json.loads(line)
                except Exception:
                    continue
    except OSError:
        return


def _day(epoch_seconds: float) -> str:
    return datetime.fromtimestamp(epoch_seconds, timezone.utc).astimezone().strftime("%Y-%m-%d")


def _blank() -> dict:
    return {field: 0 for field in FIELDS} | {"messages": 0, "cost_usd": 0.0}


def _parse_iso(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def collect_claude(since: float, out: dict) -> int:
    """Claude Code transcripts: ~/.claude/projects/**/*.jsonl."""
    import glob

    files = 0
    pattern = os.path.join(HOME, ".claude", "projects", "**", "*.jsonl")
    for path in glob.glob(pattern, recursive=True):
        try:
            if os.path.getmtime(path) < since:
                continue
        except OSError:
            continue
        files += 1
        for obj in _iter_jsonl(path):
            message = obj.get("message") or {}
            usage = message.get("usage") if isinstance(message.get("usage"), dict) else None
            if not usage:
                continue
            when = _parse_iso(obj.get("timestamp"))
            if when is None or when < since:
                continue
            bucket = out["claude"][_day(when)]
            bucket["input"] += usage.get("input_tokens", 0) or 0
            bucket["output"] += usage.get("output_tokens", 0) or 0
            bucket["cache_read"] += usage.get("cache_read_input_tokens", 0) or 0
            bucket["cache_creation"] += usage.get("cache_creation_input_tokens", 0) or 0
            bucket["messages"] += 1
    return files


def collect_codex(since: float, out: dict) -> int:
    """Codex rollouts: ~/.codex/sessions/**/*.jsonl, `token_usage_record` events."""
    import glob

    files = 0
    pattern = os.path.join(HOME, ".codex", "sessions", "**", "*.jsonl")
    for path in glob.glob(pattern, recursive=True):
        try:
            if os.path.getmtime(path) < since:
                continue
        except OSError:
            continue
        files += 1
        for obj in _iter_jsonl(path):
            if obj.get("type") != "token_usage_record":
                continue
            usage = (obj.get("payload") or {}).get("usage") or {}
            when = _parse_iso(obj.get("timestamp"))
            if when is None or when < since:
                continue
            bucket = out["codex"][_day(when)]
            bucket["input"] += usage.get("input_tokens", 0) or 0
            bucket["output"] += usage.get("output_tokens", 0) or 0
            bucket["cache_read"] += usage.get("cached_input_tokens", 0) or 0
            bucket["reasoning"] += usage.get("reasoning_output_tokens", 0) or 0
            bucket["messages"] += 1
    return files


def collect_opencode(since: float, out: dict) -> int:
    """OpenCode: ~/.local/share/opencode/opencode.db (read-only, bounded)."""
    db = os.path.join(HOME, ".local", "share", "opencode", "opencode.db")
    if not os.path.exists(db):
        return 0
    rows = 0
    try:
        connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        connection.execute("PRAGMA query_only=ON")
        cursor = connection.execute(
            "SELECT time_created, tokens_input, tokens_output, tokens_cache_read, "
            "tokens_cache_write, tokens_reasoning, cost FROM session WHERE time_created >= ?",
            (int(since * 1000),),
        )
        for created, tin, tout, tread, twrite, treason, cost in cursor:
            bucket = out["opencode"][_day(created / 1000)]
            bucket["input"] += tin or 0
            bucket["output"] += tout or 0
            bucket["cache_read"] += tread or 0
            bucket["cache_creation"] += twrite or 0
            bucket["reasoning"] += treason or 0
            bucket["cost_usd"] += float(cost or 0)
            bucket["messages"] += 1
            rows += 1
        connection.close()
    except sqlite3.Error:
        return rows
    return rows


def collect_sessions(out: dict) -> None:
    """Counts only — no token field exists for tmux/cmux panes."""
    import subprocess

    for tool, argv in (("tmux", ["tmux", "list-sessions"]), ("cmux", ["cmux", "list"])):
        try:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                out["sessions"][tool] = len([line for line in result.stdout.splitlines() if line.strip()])
        except Exception:
            continue


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7, help="history depth (default 7)")
    parser.add_argument("--print", action="store_true", dest="show")
    args = parser.parse_args()

    since = time.time() - args.days * 86400
    out = {"claude": defaultdict(_blank), "codex": defaultdict(_blank),
           "opencode": defaultdict(_blank), "sessions": {}}

    counts = {"claude": collect_claude(since, out), "codex": collect_codex(since, out),
              "opencode": collect_opencode(since, out)}
    collect_sessions(out)

    days = sorted({d for tool in ("claude", "codex", "opencode") for d in out[tool]})
    # Cost is only known where the source publishes it (OpenCode). Emitting 0.00
    # for Claude/Codex would read as "free" — the truth is "not computed here".
    days_out = {}
    for day in days:
        days_out[day] = {}
        for tool in ("claude", "codex", "opencode"):
            if day not in out[tool]:
                continue
            bucket = dict(out[tool][day])
            if tool != "opencode":
                bucket["cost_usd"] = None
            days_out[day][tool] = bucket
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "history_days": args.days,
        "source_files": counts,
        "sessions": out["sessions"],
        "cost_note": "cost_usd is published by OpenCode only; null means not computed by this ledger",
        "days": days_out,
    }
    os.makedirs(LEDGER_DIR, exist_ok=True)
    tmp = LEDGER_PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
    os.replace(tmp, LEDGER_PATH)

    if args.show:
        today = days[-1] if days else None
        for day in (days[-2:] if len(days) > 1 else days):
            print(f"== {day} ==")
            for tool in ("claude", "codex", "opencode"):
                bucket = payload["days"].get(day, {}).get(tool)
                if not bucket:
                    continue
                total = sum(bucket[f] for f in FIELDS)
                print(f"  {tool:9s} {total/1e6:9.1f}M tokens "
                      f"(in {bucket['input']/1e6:.1f}M · cache_read {bucket['cache_read']/1e6:.1f}M · "
                      f"out {bucket['output']/1e6:.1f}M) · {bucket['messages']} msgs · " + ("$%.2f" % bucket['cost_usd'] if bucket['cost_usd'] is not None else "cost n/a"))
        print("sessions:", payload["sessions"], "| files:", counts)
    print(f"ledger: {LEDGER_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
