#!/usr/bin/env python3
"""Tests for the Cortex usage ledger collector (audit V2 lot A).

Stdlib only, no network, no writes outside a temp HOME:

    python3 scripts/tests/test_cortex_usage_ledger.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import tempfile
import time
import unittest
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "cortex_usage_ledger", os.path.join(ROOT, "cortex-usage-ledger.py")
)
ledger = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ledger)


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).astimezone().isoformat()


class CollectorTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved_home = ledger.HOME
        ledger.HOME = self.home

    def tearDown(self) -> None:
        ledger.HOME = self._saved_home
        self._tmp.cleanup()

    # -- helpers ---------------------------------------------------------- #

    def _write_claude(self, records: list[dict]) -> None:
        directory = os.path.join(self.home, ".claude", "projects", "project")
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, "session.jsonl"), "w") as handle:
            for record in records:
                handle.write(json.dumps(record) + "\n")

    def _write_opencode(self, rows: list[tuple[float, str]], schema: str = "message") -> None:
        directory = os.path.join(self.home, ".local", "share", "opencode")
        os.makedirs(directory, exist_ok=True)
        connection = sqlite3.connect(os.path.join(directory, "opencode.db"))
        if schema == "message":
            connection.execute(
                "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT,"
                " time_created INTEGER, time_updated INTEGER, data TEXT)"
            )
            for index, (when, data) in enumerate(rows):
                connection.execute(
                    "INSERT INTO message VALUES (?,?,?,?,?)",
                    (f"msg_{index}", "ses_1", int(when * 1000), int(when * 1000), json.dumps(data)),
                )
        else:
            connection.execute("CREATE TABLE session (id TEXT PRIMARY KEY)")
        connection.commit()
        connection.close()

    @staticmethod
    def _claude(timestamp: float, message_id: str | None, request_id: str | None, **usage) -> dict:
        message: dict = {"usage": usage}
        if message_id:
            message["id"] = message_id
        return {
            "type": "assistant",
            "timestamp": iso(timestamp),
            "requestId": request_id,
            "message": message,
        }

    # -- T01 ----------------------------------------------------------------- #

    def test_claude_dedup_keeps_one_record_per_message_and_request(self) -> None:
        now = time.time()
        self._write_claude([
            # Same (message.id, requestId) twice: the streaming transcript emits one
            # line per apiBlockIndex — the LAST one carries the complete totals.
            self._claude(now - 600, "msg_1", "req_1", input_tokens=10, output_tokens=5,
                         cache_read_input_tokens=100),
            self._claude(now - 599, "msg_1", "req_1", input_tokens=10, output_tokens=50,
                         cache_read_input_tokens=100),
            self._claude(now - 590, "msg_2", "req_2", input_tokens=1, output_tokens=2),
            # Unkeyed records are never merged together.
            self._claude(now - 580, None, None, input_tokens=7, output_tokens=0),
            self._claude(now - 579, None, None, input_tokens=7, output_tokens=0),
        ])
        state = ledger.Ledger(now, 7)
        status = ledger.collect_claude(state, now - 7 * 86400)
        self.assertEqual(status["status"], "ok")
        bucket = state.windows["last24h"]["claude"]
        self.assertEqual(bucket["messages"], 4)
        # 50 (last occurrence wins) + 2 + 0 + 0. Counting every line would give 57.
        self.assertEqual(bucket["output"], 52)
        self.assertEqual(bucket["input"], 10 + 1 + 7 + 7)

    # -- T02 ----------------------------------------------------------------- #

    def test_opencode_attribution_uses_the_message_date(self) -> None:
        now = time.time()
        self._write_opencode([
            (now - 20 * 3600, {"role": "assistant", "tokens": {"input": 150, "output": 50}}),
            (now - 3 * 86400, {"role": "assistant", "tokens": {"input": 900, "output": 900}}),
            (now - 3600, {"role": "user", "tokens": {}}),
        ])
        state = ledger.Ledger(now, 7)
        status = ledger.collect_opencode(state, now - 7 * 86400)
        self.assertEqual(status["status"], "ok")
        window = state.windows["last24h"]["opencode"]
        self.assertEqual(window["messages"], 1)
        self.assertEqual(window["input"], 150)
        # The three-day-old session is kept in its real day, never redistributed.
        self.assertNotIn("opencode", {
            tool: bucket for tool, bucket in state.windows["last24h"].items() if bucket["input"] == 900
        })

    # -- T03 ----------------------------------------------------------------- #

    def test_unreadable_source_reports_a_status_not_a_zero(self) -> None:
        self._write_opencode([], schema="session")
        state = ledger.Ledger(time.time(), 7)
        status = ledger.collect_opencode(state, time.time() - 7 * 86400)
        self.assertEqual(status["status"], ledger.UNSUPPORTED_SCHEMA)
        self.assertIn("error", status)
        self.assertEqual(state.windows["last24h"], {})

    # -- T04 ----------------------------------------------------------------- #

    def test_last_stored_day_is_not_the_last_24_hours(self) -> None:
        now = time.time()
        self._write_claude([self._claude(now - 40 * 3600, "msg_old", "req_old",
                                         input_tokens=999, output_tokens=1)])
        state = ledger.Ledger(now, 7)
        ledger.collect_claude(state, now - 7 * 86400)
        self.assertEqual(state.windows["today"], {})
        self.assertEqual(state.windows["last24h"], {})
        total = sum(
            bucket["input"]
            for day in state.days.values() for bucket in day.values()
        )
        self.assertEqual(total, 999)

    # -- T09 ----------------------------------------------------------------- #

    def test_unknown_cost_is_unavailable_never_zero(self) -> None:
        now = time.time()
        self._write_opencode([(now - 3600, {"role": "assistant", "tokens": {"input": 5, "output": 5}})])
        state = ledger.Ledger(now, 7)
        ledger.collect_opencode(state, now - 7 * 86400)
        serialized = ledger.serialize(state.windows["last24h"])
        self.assertEqual(serialized["opencode"]["cost"], {"kind": "unavailable", "usd": None})

        self._write_claude([self._claude(now - 60, "msg_c", "req_c", input_tokens=1, output_tokens=1)])
        claude_state = ledger.Ledger(now, 7)
        ledger.collect_claude(claude_state, now - 7 * 86400)
        claude_serialized = ledger.serialize(claude_state.windows["last24h"])
        self.assertEqual(claude_serialized["claude"]["cost"]["kind"], "unavailable")


if __name__ == "__main__":
    unittest.main(verbosity=2)
