# Alibaba Token Plan

There is exactly **one** Alibaba subscription in the roster: the **Token Plan Personal**. Everything else that once looked like a second Alibaba connection was a manual sync that had stopped — the naming across the surfaces never quite agreed, and this page is the one place where they are pinned together.

---

## One subscription, four names

| Surface | Identifier | Note |
|---|---|---|
| Cortex provider descriptor | `qwen` | Stable id; the row's internal key. |
| Cortex display name | `Alibaba Token Plan` | What the user reads. |
| llm-router roster id | `bailian_token_plan` | What the router reports and routes on. |
| `bl` config profile | `cortex-monitor` (this Mac) | Top-level key in `~/.bailian/config.json`. |
| Console (source of truth for quota) | [Token Plan Personal](https://modelstudio.console.alibabacloud.com/ap-southeast-1/subscription/token-plan/personal) | Where the numbers live. |

`RouterProviderIdMap` maps `qwen → bailian_token_plan` on purpose. The old `qwen_personal_pro` id was a dead manual sync (2026-08-17); the mapping is asserted by `RouterProviderIdMapTests` and must not be "corrected" back. The old `alibaba` provider id is likewise dead — `AlibabaProvider` is never constructed in production, and any code that refreshed `providerId: "alibaba"` was refreshing a row that does not exist (fixed 2026-09-28).

## How Cortex gets the quota

`ProviderDescriptor.qwenPlan` declares a dual runtime — `.routerOrNative(RouterBacking(routerProviderId: "bailian_token_plan"))` — so the row reads from whichever lane is live:

1. **Router snapshot (preferred, when llm-router is up).** The router owns quota truth for a routed lane; Cortex displays it and never recomputes it locally. The router entry is refreshed hourly by the llm-router rail (`scripts/refresh-alibaba-token-plan.py` + LaunchAgent `com.yoyaku.llm-router.alibaba-token-plan`), which reads the console **read-only** and pushes the number.
2. **Native probe — `QwenPlanUsageProbe`** — used when the router only publishes a stale `manual` placeholder. It runs the official console command:
   ```
   bl console call --api "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage" \
     --data '{}' --output json
   ```
   The console session token (`~/.bailian/config.json`) is used — **never the inference key**. A dead console session surfaces as `ProbeError.sessionExpired` with an actionable hint on the row (it was silently swallowed before 2026-09-28; see C13).

## Connecting the console — in-app (the durable path)

Alibaba is the first provider with a **CLI-auth adapter** (`AlibabaAccountAdapter`) rather than a config card alone. Settings → the `qwen` provider → **Connect console**:

1. saves the console profile/site/region,
2. launches `bl auth login --console --console-site <site> [--config <profile>]` in the terminal,
3. polls `bl auth status --output json` until the login is observed,
4. reads back the **workspace principal** (`ws-…` from the API key's base-URL host, else the masked console token) as the verified identity,
5. refreshes the row.

The identity is a real read-back, never a typed email: `bl` exposes no email, so the account-scoped workspace id is the honest principal. A mismatch against a previously verified principal fails closed.

### The permanent fix for the recurring browser login

The console token is a **browser session token**; `bl` can renew it itself (`refreshAccessToken` → `POST /modelstudio/cli/generateAccessToken`) **only when an Alibaba Cloud OpenAPI AK/SK is configured**. Without it, every expiry means a manual browser login. The settings pane therefore surfaces the one-time gesture:

- Create an AccessKey: <https://ram.console.aliyun.com/manage/ak>
- `bl auth login --open-api --access-key-id … --access-key-secret …`

After that, the CLI renews its own console session indefinitely and the hourly rail never needs a human.

## Failure modes

| Symptom | Cause | Handling |
|---|---|---|
| Row present, no quota windows + `stale` | Console session dead | Row shows the `sessionExpired` hint; **Connect console** re-authenticates; the llm-router rail alerts within the hour |
| "Connecter" does nothing | (was) no adapter for `qwen` | Fixed: `AlibabaAccountAdapter` registered for `qwen` (2026-09-28) |
| Settings changes had no effect | (was) refreshed the dead `alibaba` id | Fixed: card refreshes `qwen` |
| Router mode unavailable | llm-router down | Falls back to the native `bl console` probe; degradation is carried by the row |
| Browser login keeps returning | No OpenAPI AK/SK | Configure AK/SK once (link above) → CLI self-renews |
