# Local usage ledger

Cortex shows two different things, and until 2026-09-26 they were easy to
confuse:

| Number | Source | What it actually covers |
|---|---|---|
| "Usage & theoretical spend" (24 h / 7 d) | `llm-router` snapshot (`usage.24h`) | **routed traffic only** — what passed through llm-router |
| Local usage ledger | `~/.claudebar/usage/ledger.json` | **every session on this Mac** (Claude Code, Codex, OpenCode, tmux/cmux) |

The gap is not academic. On 2026-09-25 the router reported ≈512 M tokens for
24 h while the local sources showed **≈3.05 B** (Claude 1.11 B + OpenCode
1.95 B) — the router never sees sessions that do not go through it.

## What the ledger is

`scripts/cortex-usage-ledger.py` reads the local sources of truth and writes a
per-day, per-tool aggregate to `~/.claudebar/usage/ledger.json`:

```bash
python3 scripts/cortex-usage-ledger.py --days 7 --print
```

Sources:

- **Claude Code** — `~/.claude/projects/**/*.jsonl`, `message.usage`
  (`input_tokens`, `output_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`). This is the same reader the in-app
  `ClaudeDailyUsageAnalyzer` uses, which de-duplicates the repeated
  `message.usage` blocks of a streamed turn.
- **Codex** — `~/.codex/sessions/**/*.jsonl`, `token_usage_record` events.
- **OpenCode** — `~/.local/share/opencode/opencode.db` (read-only, `session`
  table: `tokens_input`, `tokens_output`, `tokens_cache_read`,
  `tokens_cache_write`, `tokens_reasoning`, `cost`).
- **tmux / cmux** — session counts only; those tools publish no token field.

## Querying it

```bash
# today's totals per tool
jq -r '.days | to_entries | last | .value | to_entries[] |
  "\(.key) \(.value.input + .value.output + .value.cache_read + .value.cache_creation) tokens" ' \
  ~/.claudebar/usage/ledger.json
```

## Honesty rules baked in

- **Cache reads are counted and labelled separately.** They are ~97 % of the
  volume (a 1.1 B day is ~1.07 B cache reads), so a bare "tokens" headline
  without the split would be misleading.
- **`cost_usd` is `null` where the source does not publish a cost** (Claude,
  Codex). `null` means "not computed here", never "free".
- **Per-session attribution.** OpenCode sessions are bucketed by
  `time_created`; a session spanning midnight counts on its start day.
- The ledger is a **local observability artefact**, not a quota source. Quota
  stays owned by each provider's probe (and by llm-router for routing).

## In-app surface

The overview's global panel ("Router usage & theoretical spend") carries a
second section, **"Local usage (this Mac)"**, reading this same JSON when the
popover opens (`LocalUsageLedgerReader` → `LocalUsageLedger`). It shows the
per-tool token totals for the selected window (24 h / 7 d) with the ledger's
own freshness label, so the router figure and the local truth are never
confused again. The app decodes the ledger; it never re-parses transcripts.

## Roadmap

A scheduled refresh (LaunchAgent or an in-app background run) keeps the JSON
fresh without a manual invocation; until then the card shows the ledger's age
honestly ("ledger updated X min ago").
