# Priority ordering

The dashboard lists providers (and each account of a multi-account provider) as
rows. The default ordering is **Priority**: the list answers "what do I use
first", not "what is closest to empty". The order is the router's, never a local
invention.

---

## The router decides, Cortex displays

Cortex is never a second router (see `~/repos/llm-router/docs/CORTEX_BIBLE.md`).
llm-router publishes a `route_now` block in its json-v2 snapshot, keyed by
profile (`plan`, `execute`, `flexible`). For the active profile it carries:

- the chosen recommendation (`provider`, `account`, `model`, `score`);
- `alternatives` — runner-ups in score order, each with its quota headroom;
- `excluded` — providers the router considered and ruled out, with the reason.

`PriorityRanking` turns that single decision into a rank per Cortex provider id:

| Router verdict | Rank |
|---|---|
| recommendation | `0` |
| alternatives (in order) | `1, 2, …` |
| not mentioned | `PriorityRanking.unmentionedRank` (100) |
| excluded | `PriorityRanking.excludedRank` (200) |

Router ids map to Cortex ids through the one `RouterProviderIdMap` table, so the
Priority card and the list can never disagree about who "claude" is.

## Ordering is independent of the window filter

`Session 5h / Week / All` chooses which window is *measured*. It no longer moves
rows: `sortKey` evaluates the Priority rank **before** the filter, so a
recommended provider with a missing short window still leads. The other sort
modes (`% left`, `Reset`) keep their filter-driven behaviour, and an explicitly
stored choice still wins over the new default.

When `route_now` is absent (router down, older snapshot), `isAvailable` is
`false` and Priority falls back to the worst-percentage sort — an honest
degradation, never a fabricated order.

## Preferred model family

Each provider can carry a preferred **family** (not an exact model id — the
served model behind an alias is unknown, bible §6). The seed sets DeepSeek on
OpenCode Go, Command Code and Ollama Cloud when the key is absent
(`CortexApp.seedPreferredModelsIfNeeded`), so the family logo shows on every
provider that runs it. An explicit choice is never overwritten; the preference
is also exported to the router (Contract A) so it reaches the brain, and the UI
states that it influences routing rather than being a merely cosmetic pin.

## Price coverage is not a bill

The usage panel used to print `43 % billed`. That figure is the share of tokens
Cortex could price from the tariff SSOT — it has nothing to do with payments. It
now reads `% priced`, with a tooltip spelling out that subscription usage is not
billed per token. A $10 subscription is never rendered as its API-equivalent
bill.

## Where it lives

| File | Role |
|---|---|
| `Sources/Domain/Overview/OverviewModels.swift` | `OverviewSort.priority`, `PriorityRanking` |
| `Sources/Domain/Overview/OverviewBuilder.swift` | `sort(… priority:)` and the rank-aware `sortKey` |
| `Sources/App/Views/Overview/OverviewDashboardView.swift` | passes `routeNow` + `settings.routeProfile` |
| `Sources/Infrastructure/Storage/JSONSettingsRepository.swift` | default sort is now `.priority` |
| `Sources/Domain/Provider/LLMRouter/RouterProviderIdMap.swift` | the one router ⇄ Cortex id table |
