# Mission progress (control-plane projection)

Cortex shows where an active mission stands, but it does not track missions.
The `missiond` control plane owns them (`~/.yoyaku/brain/brain.db`), so Cortex
builds a **read-only materialized view** of that plane and displays it —
yoyaku-brain-os' rule is "each record has one owner, other systems build
materialized views" (`docs/ARCHITECTURE.md`). No new store, no daemon, no write
into the plane.

## Sources

| Fact | Authority | Where Cortex reads it |
|---|---|---|
| The mission exists | `missiond` | `missions` row (`mission_id`, `objective`, `repo_root`, `status`, `phase`, `updated_at`) |
| A resource is held | `missiond` | `leases` rows whose `holder_mission_id` is that mission |
| A session is attached | `missiond` | latest `session_bindings` row (`runtime`, `last_seen_at`) |
| A terminal was opened | `yy` receipt | `~/.yoyaku/brain/receipts/<mission_id>.json` (`{mission_id, session_id, worktree, harness, ts}`) |

## Proven chain

`MissionProgress.Step` is ordered and only ever contains steps the plane (or a
receipt file) can prove:

```
registered → leased → bound → terminalOpened
```

- `registered` — the `missions` row exists.
- `leased` — at least one lease still on that mission.
- `bound` — a session binding names it (the harness label comes from there).
- `terminalOpened` — a receipt file exists for that mission.

Two consequences are deliberate:

- **A creation row is not progress.** A mission with no lease, no binding and no
  receipt shows `enregistrée` and stops. "Terminal opened" is also not "work
  started": the receipt proves a terminal was launched, nothing more.
- **A missing measurement stays visible.** A receipt whose `ts` cannot be parsed
  still proves `terminalOpened` with no date — the card shows no age rather than
  a reassuring zero.

A fifth step, `REQUEST_OBSERVED` ("the first routed request was seen for this
mission"), is **not** implemented: it needs a usage-trace ↔ mission correlation
that does not exist yet. Until then the chain stops at `terminalOpened`.

A lease is not a budget: the plane's lease (a monotonic epoch) and any spend
register are two separate things, and Cortex never derives one from the other.

## Reading mechanism

`MissionPlaneReader` reuses `SQLiteReadOnly` — the same read-only, `LIMIT`-bounded
helper the OpenCode session source uses:

- `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`, `busy_timeout` 500 ms, a bound
  `LIMIT` (default 20) and `status = 'active' ORDER BY updated_at DESC`.
- Any failure (missing file, locked plane, schema drift) returns an empty
  projection. An unreadable plane never fabricates missions.
- The receipt directory is read with `contentsOfDirectory`; only `*.json` files
  whose name starts with `msn_` are considered, and a malformed receipt keys its
  mission without a date.

The projection itself (`MissionPlaneReader.project(rows:receipts:)`) is pure, so
the proven-chain rule is unit-testable without a database.

**Gotcha (2026-09-27).** A receipt must key its mission even when its timestamp
is unreadable, so the reader writes `found[id] = .some(date?)`. The obvious
`found[id] = optionalDate` silently does *not* insert when the value is `nil`
(`Date?` → `Date??` coercion removes the entry), which dropped a broken receipt
entirely. `Tests/InfrastructureTests/LocalState/LLMRuntimeInspectorTests.swift`
now guards this case.

## Display

`SessionsCardView` lists up to three missions under the runtime metrics row,
one line each: worktree name (fallback: mission id) and the proven steps joined
by `→`, plus the receipt age when it is known. `LLMRuntimeSnapshot.missions`
carries the projection; its `help` text states that only proven steps are shown.

Nothing on this card is computed by Cortex (CORTEX_BIBLE §16) — the steps are
facts read from the plane.
