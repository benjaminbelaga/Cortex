# Provider removal

Cortex watches a roster of providers it did not create and cannot own: the CLIs, the credentials, the settings files all belong to the tools. Removal therefore means one narrow thing — **stop tracking this row in Cortex** — and the feature is shaped entirely by that boundary.

---

## What removal does and does not do

| Action | Effect |
|---|---|
| Removes | The provider (or one account of a multi-account provider) from Cortex's roster and every panel that lists it. |
| Removes | Nothing else. No CLI config, no keychain credential, no settings file, no shell profile, no token. |
| Keeps | The credential in the macOS Keychain (Cortex only deletes the account it created and owns). |
| Keeps | The tool's own login. Re-adding the provider in Cortex picks the session back up untouched. |

The confirmation copy says exactly this, because the fear it answers — *"will this log me out of Claude?"* — is the reason people hesitate on a destructive button.

## Where it lives

The action is on the **detail sheet** of a provider or account: tap a row in the dashboard, and the footer carries `Remove from Cortex` next to `Close`. The sheet is the only place with enough context to name what is being removed and to explain the consequence.

`OverviewDashboardView` owns the two removal paths and routes by row identity:

| Row kind | Predicate | Effect |
|---|---|---|
| Account row of a multi-account provider | `snapshot.id` contains `\|` → `accountId` suffix | `AccountCatalogModel.removeAccount(providerId:accountId:)` |
| Whole provider | no `\|` | `QuotaMonitor.setProviderEnabled(id, enabled: false)` + `removeProvider(id:)` |

Both paths persist a single flag: `providers.<id>.isEnabled = false`.

## The confirmation is inline, never a system dialog

`ResetsCalendarSheet` confirms removal **in place**: the footer swaps to a one-line explanation plus `Remove` / `Keep`. There is deliberately no `.confirmationDialog`.

Cortex's dashboard lives inside an `NSPopover`-backed `MenuBarExtra`. A system modal presented from that context is a known failure class here — the same reason the resets detail is an in-popover swap rather than a `.sheet`:

- the popover greys out while the modal is up and does not always come back;
- a tap on the modal's destructive button can fail to land, leaving the row in place;
- dismissing the modal (even via `Cancel`) resets the popover's content, so the detail block vanishes and the whole menu has to be reopened.

An inline strip has none of those transitions: `Keep` restores the normal footer and the sheet stays exactly where it was; `Remove` runs the removal path directly.

## Removal is sticky

Composition honours `providers.<id>.isEnabled` for **every** provider, not only the optional connectors:

```swift
// ProviderComposition.instantiateIfFollowed
if !isEnabled(id: descriptor.id) { return nil }
```

Before this, a removed *first-class* provider (Claude, Codex, …) was skipped nowhere: the roster was rebuilt from the catalog on the next recomposition and the row reappeared minutes later. The flag was written but never read for those ids. Now the same write both hides the row and keeps it hidden across refreshes, roster reloads and relaunches — `ProviderCompositionExhaustiveTests.disabledNonOptionalProviderIsSkipped` locks it.

## Re-enabling

Nothing is lost and nothing is one-way. A removed provider is re-added the ordinary way:

- **Settings → Connections**, toggle the provider back on; or
- the dashboard's `+` catalog (**Add an account / enable a connection**), which lists it and re-follows it.

The `defaultEnabled` value seeded on first launch (`CortexApp.seedCuratedProviderDefaultsIfNeeded`) uses the same key, so the "not shown unprompted" roster and the user's removals share one mechanism instead of two that could disagree.
