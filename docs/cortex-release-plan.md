# Cortex account reliability and public release

Status: implementation in progress. No production or publication claim until verified.

## Acceptance checklist

- [ ] Persistent independent OpenCode Go and Command Code accounts; secrets in Keychain only.
- [ ] One add-account flow from catalogue, provider settings and row menu; test before saving.
- [ ] Persist verified CLI enrolment, refresh first quota, resolve reconnect to actual profile.
- [ ] Codex initialization, profile isolation, current rate-limit pools and missing-window semantics.
- [ ] Qwen official Token Plan usage integration; stale manual values remain explicitly stale.
- [ ] Disabled providers disappear and stop polling; provider errors remain actionable.
- [ ] Cortex icon, About links, truthful build/update metadata, coherent release tooling.
- [ ] Isolated tests, full canonical build gate, real-account read-only validation, installed app smoke.
- [ ] Clean-history public export with attribution, no private docs, logs, credentials or machine paths.
- [ ] Scan source and release artifact before publishing benjaminbelaga/Cortex; retain private history.
- [ ] Commit, push, review, deployment evidence and intervention log.

## Architecture

Each account has a stable ID, label, source and credential/profile reference. Per-account
readings and errors are independent. Authentication success and quota availability are
different states. Unknown balances or missing windows must not become fabricated percentages.
Native collectors work without the private router. Router mode is optional and explicit.

## Later roadmap

Enterprise organizations, scoped credential sharing, enrolled computers, per-device usage,
fleet inventory, role-based access, audit logs, retention controls and a self-hosted control
plane are deferred. Never distribute an administrator's raw API keys to fleet clients.

## Verification record

Pre-implementation: both Command Code keys returned HTTP 200 and distinct identities;
both OpenCode Go keys returned HTTP 200 with separate usage. Old private repository's
reachable history contained none of these four exact keys. Public export still needs its
own scan. Installed app has stale build metadata and the old identity/link configuration.
