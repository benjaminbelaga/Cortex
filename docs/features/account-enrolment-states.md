# Account enrolment states

Adding an account runs a verified enrolment: the tool is authenticated in a
terminal, its identity is read back, the account is persisted, and its first
usage reading is collected. Those steps can fail **independently**, and the UI
must say which one did — a saved account must never be presented as a failed
login.

---

## Two stages, three outcomes

`AccountEnrolmentService` splits the post-identity handshake into two injected
stages:

| Stage | Callback | On failure |
|---|---|---|
| 1. Persist the verified account | `onRegistered(descriptor) -> accountId` | `.failed` — nothing was saved, replaying the login is safe |
| 2. Collect the first reading | `onQuotaObserved(descriptor, accountId) -> Date?` | `.quotaUnavailable(descriptor, reason:)` — the account IS saved |

The stream after `.identityConfirmed` is therefore:

```
identityConfirmed → quotaPending → quotaReceived
                                  └→ quotaUnavailable   (stage 2 threw)
       └→ failed                                          (stage 1 threw)
```

`quotaUnavailable` is a **recoverable** state ("Connected · quota unavailable",
retry usage). It never re-runs the login and never re-creates the account. This
is the fix for the observed defect where a parse failure/timeout/429 after a
successful save surfaced as `Enrolment failed`, inviting a duplicate attempt.

## Reading a repainted `claude /usage`

The Claude CLI paints its Usage tab incrementally and can redraw over it (the
plugin skill-footprint panel, the "what's contributing" report). SwiftTerm's
replay returns only the terminal's **final** composed screen, which then no
longer contains the labelled quota sections — even though every emitted line is
present in the capture. `parseClaudeOutput` detects this (rendered screen has no
"Current session") and re-parses the **ANSI-stripped stream**, which still
carries them. It never grabs an arbitrary first percentage; extraction stays
label-anchored. A regression test replays the real failing capture (anonymized)
through the probe.

## Where it lives

| File | Role |
|---|---|
| `Sources/Domain/Provider/Account/AccountEnrolment.swift` | `EnrolmentState.quotaUnavailable` |
| `Sources/App/Accounts/AccountEnrolmentService.swift` | the two-stage handshake |
| `Sources/App/CortexApp.swift` | `registerVerifiedAccount` + `refreshAccount` wiring |
| `Sources/Infrastructure/Claude/ClaudeUsageProbe.swift` | rendered-screen → stripped-stream fallback |
| `Sources/App/Views/Overview/AccountCatalog/CatalogStrings.swift` | labels per typed state |
