# Alibaba Token Plan

There is exactly **one** Alibaba subscription in the roster: the **Token Plan Personal**. Everything else that once looked like a second Alibaba connection was a manual sync that had stopped — the naming across the four surfaces never quite agreed, and this page is the one place where they are pinned together.

---

## One subscription, four names

| Surface | Identifier | Note |
|---|---|---|
| Cortex provider descriptor | `qwen` | Stable id; the row's internal key. |
| Cortex display name | `Alibaba Token Plan` | What the user reads. |
| llm-router roster id | `bailian_token_plan` | What the router reports and routes on. |
| OpenCode provider key | `bailian-token-plan` | `~/.config/opencode` provider name, base `token-plan.ap-southeast-1.maas.aliyuncs.com`. |
| Console (source of truth for quota) | [Token Plan Personal](https://modelstudio.console.alibabacloud.com/ap-southeast-1/subscription/token-plan/personal) | Where the numbers live. |

`RouterProviderIdMap` maps `qwen → bailian_token_plan` on purpose. The old `qwen_personal_pro` id was a dead manual sync (2026-08-17); the mapping is asserted by `RouterProviderIdMapTests` and must not be "corrected" back.

## How Cortex gets the quota

`ProviderDescriptor.qwenPlan` declares a dual runtime — `.routerOrNative(RouterBacking(routerProviderId: "bailian_token_plan"))` — so the row reads from whichever lane is live:

1. **Router snapshot (preferred, when llm-router is up).** The router owns quota truth for a routed lane; Cortex displays it and never recomputes it locally.
2. **Native probe — `AlibabaUsageProbe`** — used when the router is absent:
   - **API key** (`alibaba-api-key` in the Keychain) → `fetchWithApiKey`, or
   - **console cookie** (manual paste, or extracted from a browser) → `fetchWithCookie`.

`isAvailable()` returns true only when one of those credentials exists. The region comes from `AlibabaRegion` (default international; `---ap-southeast-1` for the Token Plan console).

### What is deliberately not a source

`bl usage token-plan` (the Bailian CLI) prints **no numeric quota** for a Token Plan Personal account — it answers *"may be unlimited; verify in the console"*. It is therefore not wired as a probe: a source that cannot produce a number would only add a probe that always "succeeds" with nothing to show. The number, when it exists, comes from the console (cookie/API-key path above) or from the router.

## Connecting the console

When no credential is present the row has no windows, and the detail sheet says so and offers the two ways in:

- **Open console** — the sheet's footer button opens the Token Plan console so the user can sign in; per-provider web consoles live here, not on the dashboard's `Dashboard` button (which opens Cortex's own window).
- **Settings → Alibaba** (`AlibabaConfigCard`) — paste the console cookie (or an API key) once; it is stored in the Keychain, never in `settings.json`.

Auto browser-cookie extraction is best-effort and depends on the browser cookie store being readable; the manual paste is the reliable path and the reason the card exists.

## Failure modes

| Symptom | Cause | Handling |
|---|---|---|
| Row present, no quota windows | No credential enrolled (no key, no cookie) | Sheet header: *"No quota data yet — open the console to connect this provider."* + `Open console` |
| Cookie expired | Console session ended | Re-paste in `AlibabaConfigCard` |
| Router mode unavailable | llm-router down | Falls back to the native probe; degradation is carried by the row, not an exception in composition |
