# Attention feed and mission inspector

Two surfaces answer the same question — "what needs a human, and what really
happened?" — and both are materialized views of llm-router's own state. The
**« À traiter »** feed lists the items the router has flagged; the **Mission
Inspector** opens one mission and shows the chain from recommendation to result.
Cortex owns neither the mission nor the decision: it reads what the router
persisted and shows it without probing a provider (CORTEX_BIBLE §16).

---

## The feed is read-only and deterministic

The attention feed aggregates state the router has already persisted; it never
probes a provider, never launches anything, and never writes back. The same
input always produces the same list, so a refresh cannot invent a row or reorder
one between reads.

Two entry points expose the same data:

| Command | Shape | When to use |
|---|---|---|
| `llm-router attention --json` | `{"count": N, "items": [...]}` | the feed on its own |
| `llm-router status --format json-v2 --with-attention` | the snapshot envelope, plus `attention` / `attention_count` | the cheap path — one snapshot, no second subprocess |

When the feed is already needed, the snapshot carries it: `--with-attention`
embeds `attention` (the items) and `attention_count` (the router's own count) in
the json-v2 document Cortex decodes anyway, so the UI does not pay for a second
`llm-router` invocation.

## The four item kinds

Each kind carries only the keys that identify it — there is no shared grab-bag.

| Kind | Severity | Keys | What it reports |
|---|---|---|---|
| `launch_divergence` | high | `mission_id`, `detail`, `requested`, `observed` | what was requested ≠ what was observed |
| `account_reconnect` | high | `account_id`, `provider`, `detail` | an account is no longer routable; **no `mission_id`** |
| `result_to_validate` | medium | `mission_id`, `provider`, `model` | a mission closed without an evaluation |
| `receipt_awaited` | low | `mission_id`, `provider` | an open mission whose execution confirmation was not observed |

The split is deliberate:

- **`requested` vs `observed` is the router's own honesty boundary.** Cortex
  keeps both maps and shows the divergence; it never folds them into a single
  "what ran" value.
- **`account_reconnect` is about an account, not a mission**, so it has no
  `mission_id`. It comes from `cortex-accounts.json` where `auth_state ∈
  {expired, error}` or `status == reconnect`. Deriving a mission id for it would
  invent a correlation that does not exist.
- **`result_to_validate` exists because a clean exit is not a verdict.** A
  mission closed with `success IS NULL` is flagged precisely because `rc=0`
  validates nothing — someone still has to say whether the result is good.
- **`receipt_awaited` is the weakest signal** (low). A requested binding is not
  an observed one, so an open mission with no confirmation is surfaced, never
  assumed to be running.

The feed is ordered by severity — high → medium → low — and then by a stable
item id, so two reads of the same state list the rows identically.

## Unknown kinds are preserved, never dropped

A newer router can add a kind Cortex does not know. `RouterAttentionKind` keeps
it as `.unknown(raw)` and the raw string is displayed verbatim, so an item can
never silently disappear from the feed. The same rule holds at the decoding
edge: `RouterJSONValue` decodes any leaf leniently (an exotic shape becomes a
blank leaf, not a decode failure), and an item that still carries a `kind` and a
`detail` survives even when its other fields are malformed. An unrecognized
severity ranks last rather than inventing an alarm, and the item itself is still
shown. Nothing is ever lost to a schema the router grew ahead of this release.

## The mission inspector

`llm-router mission inspect <id>` reads `telemetry.mission_view` and returns the
whole chain for one mission:

```
recommended → requested / observed / receipt_state / divergence → result / metrics
```

Cortex renders each stage as its own row; it never composes two stages into a
claim the router did not make. The recommended provider is mapped to a Cortex id
through the single `RouterProviderIdMap` table, so the inspector, the Priority
card and the feed agree on who "claude" is.

## The result is a tri-state, never a tick

`result.success` is the load-bearing value and it has **three** states, not two:

| `success` | Meaning | Shown as |
|---|---|---|
| `true` | verified | passed |
| `false` | failed | failed |
| `null` | **never evaluated** | the honest gap, not a pass |

A process that exited cleanly (`rc=0`) is not a verdict: it says the command
ran, not that the work is correct. The gap is explicit — `closed == true`
together with `success == null` is the "**unverified close**" the UI must show
as an open question rather than a green tick.

Metrics follow the same rule: a value the router did not report renders as
`—`, **never `0`**. A missing duration, token count or test count means "not
measured here", and a fabricated zero would read as a real measurement.

An unknown mission id is not an empty page: `mission inspect` exits `1`, and the
inspector surfaces that failure instead of drawing an empty chain.

## Where it lives

| File | Role |
|---|---|
| `Sources/Domain/Provider/LLMRouter/RouterAttention.swift` | `RouterAttentionFeed`, `RouterAttentionItem`, `RouterAttentionKind`, `RouterAttentionSeverity`, `MissionInspection` |
| `Sources/Infrastructure/LLMRouter/LLMRouterAttentionClient.swift` | `LLMRouterAttentionClient`, `LLMRouterMissionInspector` |
| `Sources/App/Views/Attention/AttentionFeedView.swift` | the « À traiter » feed list |
| `Sources/App/Views/Attention/MissionInspectorView.swift` | the per-mission chain |

The domain types decode both shapes (`attention --json` and the embedded
`attention` block) and stay total for anything the router adds later.

## A failed read is an error, never "nothing to do"

If `llm-router` is missing, times out, exits non-zero or returns malformed JSON,
the read **throws** and the surface shows an error. It never falls back to an
empty feed — an empty list means the router looked and found nothing to flag,
which is a much stronger statement than "the read failed". `count` is the
router's own value when present and `items.count` otherwise; it is never a
reassuring `0` for a failed call.
