# Local usage ledger

Cortex shows two different things, and until 2026-09-26 they were easy to
confuse:

| Number | Source | What it actually covers |
|---|---|---|
| "Usage & theoretical spend" (24 h / 7 d) | `llm-router` snapshot (`usage.24h`) | **routed traffic only** — what passed through llm-router |
| Local usage ledger | `~/.claudebar/usage/ledger.json` | **every session on this Mac** (Claude Code, Codex, OpenCode, tmux/cmux) |

The gap is not academic. On 2026-09-25 the router reported ≈512 M tokens for
24 h while the local sources showed **≈6.06 B** (Claude 520 M + Codex 395 M +
OpenCode 5.14 B) — the router never sees sessions that do not go through it.
The first pass at this file reported ≈1.11 B for Claude: that number was itself
wrong, because the collector summed every streamed `usage` block without
de-duplicating them (audit V2-01). The 520 M figure is the de-duplicated one.

## Schema v2 (audit V2, lot A)

`ledger.json` is at schema 2 and carries more than day buckets:

```json
{
  "schema_version": 2,
  "generated_at": "…",
  "sources":  { "claude": {"status": "ok", "files": 1587, "last_observed_at": "…"} },
  "windows":  { "today": {...}, "last24h": {...}, "last7d": {...} },
  "days":     { "2026-09-25": { "claude": {...} } }
}
```

Each tool bucket carries `input / output / cache_read / cache_creation /
reasoning / messages` plus a typed cost:

```json
"cost": {"kind": "declared", "usd": 66.55}   // or {"kind": "unavailable", "usd": null}
```

Four properties matter:

- **De-duplication.** Claude is keyed by `(message.id, requestId)`, last
  occurrence wins — exactly the rule of the in-app `ClaudeDailyUsageAnalyzer`.
  A real transcript repeats the same message once per `apiBlockIndex`; without
  this, usage is counted several times. Codex is keyed by
  `(session_id, turn_id, response_id)`. Entries without the identity fields are
  kept **distinct** rather than merged by guess.
- **Real attribution.** OpenCode is aggregated **per assistant message** from
  the `message` table (indexed by `(session_id, time_created, id)`), so a
  session created three days ago no longer dumps its whole history onto the
  collection day.
- **Measured windows.** `today` is the local civil day; `last24h` and `last7d`
  are rolling and computed from event timestamps. The last stored day is not
  "the last 24 hours".
- **Sources that fail say so.** A source that cannot be read reports
  `status` (`missing`, `partial`, `permission_denied`, `unsupported_schema`) —
  never a reassuring zero. `cost.kind = "unavailable"` means "not computed
  here", never "free".

## What the ledger is

`scripts/cortex-usage-ledger.py` reads the local sources of truth and writes a
per-day, per-tool aggregate to `~/.claudebar/usage/ledger.json`:

```bash
python3 scripts/cortex-usage-ledger.py --days 7 --print
```

Sources:

- **Claude Code** — `~/.claude/projects/**/*.jsonl`, `message.usage`
  (`input_tokens`, `output_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`), de-duplicated by `(message.id, requestId)`.
- **Codex** — `~/.codex/sessions/**/*.jsonl`, `token_usage_record` events.
- **OpenCode** — `~/.local/share/opencode/opencode.db` (read-only), the
  `message` table: `tokens.input/output/reasoning` and
  `tokens.cache.read/write`, with the `cost` field when the row publishes one.
- **tmux / cmux** — session counts only; those tools publish no token field.

## Querying it

```bash
# rolling 24 h per tool, de-duplicated
jq -r '.windows.last24h.tools | to_entries[] |
  "\(.key) \(.value.input + .value.output + .value.cache_read + .value.cache_creation)" \
  ~/.claudebar/usage/ledger.json
```

## Tests

`python3 scripts/tests/test_cortex_usage_ledger.py` (stdlib, temp HOME, no
network) covers the collector's invariants: T01 de-duplication, T02 OpenCode
attribution by message date, T03 unreadable source reports a status, T04 the
last stored day is not the last 24 h, T09 unknown cost is `unavailable` — not
`0`. The launcher side is covered in `Tests/AppTests/MissionSessionLauncherTests.swift`
(launch command executed under the real `/bin/bash` and `/bin/zsh`).

## Honesty rules baked in

- **Cache reads are counted and labelled separately.** They dominate the
  volume (≈97 % of a Claude day), so a bare "tokens" headline without the split
  would be misleading — the card computes the share **on the displayed window**
  instead of printing a hardcoded constant.
- **`cost.kind` distinguishes a declared price from an unavailable one**
  (Claude, Codex publish none). `unavailable` means "not computed here", never
  "free".
- **Per-message attribution** (OpenCode) and per-event attribution
  (Claude, Codex): no session-level history is redistributed onto a
  collection day.
- The ledger is a **local observability artefact**, not a quota source. Quota
  stays owned by each provider's probe (and by llm-router for routing).

## In-app surface

The overview's global panel ("Router usage & theoretical spend") carries a
second section, **"Local usage (this Mac)"**, reading this same JSON when the
popover opens (`LocalUsageLedgerReader` → `LocalUsageLedger`). It offers the
measured windows (`Today` / `24h` / `7d`), the computed cache share, the
per-tool cost when the source declares one (`cost n/a` otherwise), a freshness
label, and a warning line when a source could not be read. The app decodes the
ledger; it never re-parses transcripts.

## Refresh

`com.yoyaku.cortex-usage-ledger` (`~/Library/LaunchAgents/`) runs the collector
every 10 minutes and at load; `ledger-agent.log` sits next to the JSON. The
card still shows the ledger's age honestly ("ledger updated X min ago") so a
stalled agent is visible rather than silent.
