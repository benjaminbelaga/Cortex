# Mission routes — identity of a route

Cortex never decides a route: `llm-router suggest --json` returns ranked
candidates and Cortex displays them (`Sources/Infrastructure/LLMRouter/LLMRouterSuggestionClient.swift`).
This document records what makes two candidates *different routes*, because a
route identity that is too small silently collapses rows in the UI.

## Wire fields Cortex consumes

| Field | Meaning | Used for |
|---|---|---|
| `provider` | provider id (`minimax_max`, `opencode_go`, …) | identity + display |
| `model` | model id on that provider | identity + display |
| `effort` | reasoning effort variant (may be absent) | identity + display |
| `account` | `{id, alias, identity}` — the account the router selected (present on multi-account providers) | identity + display |
| `launch_plan.launcher_id` | the configured launcher | identity |
| `launch_plan.{executable,arguments,environment}` | structured argv, not shell text | `launchCommand(for:)` |
| `launcher_command` | legacy rendered command (fallback when no plan) | launch fallback |

### Provenance of a decision (audit V2 §12)

| Field | Meaning | Displayed as |
|---|---|---|
| `generated_at` | when the engine produced the decision | age, relative style (`.relative`) |
| `privacy` / `context_estimate` | scope the decision was taken under | header caption |
| `status_source` / `status_age_min` | where the quota came from and its age | `source · quota il y a N min`; **absent = unknown, warning after 20 min** |
| `time_multiplier` | tariff multiplier now (`< 1` = discount window) | `DISCOUNT ×N` badge |
| `penalties` | engine penalties on the candidate | inside the existing "Pourquoi" disclosure |
| `ineligible[]` | routes the engine rejected, with reasons | "Écartées" list — never recomputed |
| `suggest_wait_until` | a window the engine says opens later | advice line only; Cortex never waits or launches on it |
| `fallback_chain` | ordered fallbacks after the recommendation | available for the proof detail |

Cortex **displays** all of the above and computes none of it (CORTEX_BIBLE §16). The accepted
contract is R39 in `docs/claudebar-v2-design-requirements.md`.

`account.id` / `account.alias` / `account.identity` are labels, not secrets: the
router prints them in its own CLI and puts them in `launcher_command`
(e.g. `opencode run go-2`). Cortex exposes `alias → identity → id` as the
display label and never shows a token or a key.

## Identity rule

```
id = provider : model [ : effort ] [ : account label ] [ : launcher_id ]
```

Optional parts are skipped when absent, so a single-account route with no
structured plan keeps the short `provider:model` form.

Why this matters: `MissionLauncherView` builds its list with
`ForEach(…, id: \.element.id)`. Two accounts on the same provider and model (a
multi-account provider) — or the same model at two efforts — used to produce two
identical ids. SwiftUI then reuses/drops rows and the user cannot tell the routes
apart; the audit V2 calls this out (`§3 Identité d'une route`, acceptance test
T11).

## Boundaries

- Deduplicating a *shared pool* is the router's job (it selects one account per
  provider); Cortex only mirrors what it is told.
- The display label can be empty (single account, no alias) — the identity then
  falls back to provider + model.
- `launcherCommand` and `launchPlan` stay separate: the plan is the tested,
  quoted argv path, the command is the compatibility fallback.
