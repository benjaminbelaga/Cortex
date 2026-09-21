import Testing
import Foundation
@testable import Domain

/// D tranche — honest states: typed auth verdicts, data liveness, identity
/// masking and the fleet summary must never fabricate a status (no invented
/// 0 %, no borrowed green, no text heuristics on provider names).
@Suite("Honest states — masking, data state, fleet summary")
struct HonestStatesTests {

    // MARK: - IdentityMasking

    @Test("Email masking keeps one character per side plus the TLD")
    func maskingBasicShapes() {
        #expect(IdentityMasking.mask("personal@example.com") == "p***@e***.com")
        #expect(IdentityMasking.mask("benjaminbelaga@gmail.com") == "b***@g***.com")
        // Multi-label domains keep only the last label (the registry TLD) —
        // masking MORE is always the safe direction, never less.
        #expect(IdentityMasking.mask("a.b@sub.domain.co.uk") == "a***@s***.uk")
    }

    @Test("Non-identities surface unchanged — masking never corrupts a path")
    func maskingPassthrough() {
        #expect(IdentityMasking.mask("/Users/ben/.claude-accounts/web")
            == "/Users/ben/.claude-accounts/web")
        #expect(IdentityMasking.mask("WORK") == "WORK")
        #expect(IdentityMasking.mask(nil) == nil)
        #expect(IdentityMasking.mask("no-at-sign") == "no-at-sign")
        #expect(IdentityMasking.mask("@domain.fr") == "@domain.fr")
        #expect(IdentityMasking.mask("local@") == "local@")
        #expect(IdentityMasking.mask("a@localhost") == "a***@l***")
    }

    // MARK: - RowDataState

    private func window(
        id: String = "w",
        percent: Double = 50,
        stale: Bool = false,
        scope: WindowScope = .session
    ) -> WindowSnapshot {
        WindowSnapshot(
            id: id, title: "5h", percentRemaining: percent,
            resetsAt: nil, compactReset: nil, scope: scope, isStale: stale
        )
    }

    private func row(
        windows: [WindowSnapshot],
        error: String? = nil,
        capturedAt: Date? = nil,
        authState: AccountAuthState = .unknown
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "p|a", providerId: "p", providerName: "P",
            accountLabel: "A", windows: windows,
            errorMessage: error, authState: authState, capturedAt: capturedAt
        )
    }

    @Test("dataState: no windows, no error → neverReceived")
    func dataStateNeverReceived() {
        #expect(row(windows: []).dataState == .neverReceived)
    }

    @Test("dataState: no windows + error → failed carrying the reason")
    func dataStateFailed() {
        guard case let .failed(reason) = row(windows: [], error: "boom").dataState else {
            Issue.record("expected failed"); return
        }
        #expect(reason == "boom")
    }

    @Test("dataState: all-stale windows → stale with the original capturedAt preserved")
    func dataStateStale() {
        let at = Date(timeIntervalSince1970: 1000)
        guard case let .stale(observedAt) =
            row(windows: [window(stale: true)], capturedAt: at).dataState else {
            Issue.record("expected stale"); return
        }
        #expect(observedAt == at)
    }

    @Test("dataState: one fresh window is enough to be fresh")
    func dataStateFresh() {
        let state = row(windows: [window(stale: true), window(id: "w2")]).dataState
        guard case .fresh = state else {
            Issue.record("expected fresh, got \(state)"); return
        }
    }

    @Test("needsReconnect follows the typed auth state only")
    func needsReconnectTyped() {
        #expect(row(windows: [], authState: .reconnectRequired).needsReconnect)
        #expect(!row(windows: [], error: "Reconnexion requise").needsReconnect,
                "an error string that merely looks reconnect-ish must NOT arm the button")
        #expect(!row(windows: [], authState: .connected).needsReconnect)
    }

    // MARK: - FleetAvailabilitySummary

    @Test("fleetSummary: empty rows → unknown")
    func fleetUnknownOnEmpty() {
        #expect(OverviewBuilder.fleetSummary(rows: [], filter: .all) == .unknown)
    }

    @Test("fleetSummary: a failed collection is a known problem (warning), not silence")
    func fleetFailedIsKnownWarning() {
        let rows = [
            row(windows: []),
            row(windows: [], error: "probe down"),
        ]
        guard case let .known(status, usable, needsAction, unknownCount) =
            OverviewBuilder.fleetSummary(rows: rows, filter: .all) else {
            Issue.record("expected known"); return
        }
        #expect(status == .warning)
        #expect(usable == 0)
        #expect(needsAction == 1)
        #expect(unknownCount == 1)
    }

    @Test("fleetSummary: purely never-received rows (no failure) → unknown")
    func fleetUnknownWhenNothingKnown() {
        #expect(OverviewBuilder.fleetSummary(rows: [row(windows: [])], filter: .all) == .unknown)
    }

    @Test("fleetSummary: fresh rows drive status, usable and unknown counts")
    func fleetKnownCounts() {
        let rows = [
            row(windows: [window(id: "a", percent: 80)]),            // usable, healthy
            row(windows: [window(id: "b", percent: 5)]),             // usable, critical
            row(windows: [window(id: "c", percent: 0)]),             // depleted → not usable
            row(windows: []),                                        // never received
        ]
        guard case let .known(status, usable, needsAction, unknownCount) =
            OverviewBuilder.fleetSummary(rows: rows, filter: .session) else {
            Issue.record("expected known"); return
        }
        #expect(status == .depleted)
        #expect(usable == 2)
        #expect(needsAction == 0)
        #expect(unknownCount == 1)
    }

    @Test("fleetSummary: a stale 0 % never paints the fleet red")
    func fleetStaleZeroIgnored() {
        let rows = [
            row(windows: [window(id: "fresh", percent: 70)]),
            row(windows: [window(id: "old", percent: 0, stale: true)]),
        ]
        guard case let .known(status, _, _, _) =
            OverviewBuilder.fleetSummary(rows: rows, filter: .session) else {
            Issue.record("expected known"); return
        }
        #expect(status == .healthy)
    }

    @Test("fleetSummary: stale-only row with broken credentials counts as needsAction")
    func fleetStaleReconnectCounts() {
        let rows = [
            row(windows: [window(stale: true)], authState: .reconnectRequired),
            row(windows: [window(id: "ok", percent: 40)]),
        ]
        guard case let .known(status, usable, needsAction, unknownCount) =
            OverviewBuilder.fleetSummary(rows: rows, filter: .session) else {
            Issue.record("expected known"); return
        }
        #expect(status == .warning)
        #expect(usable == 1)
        #expect(needsAction == 1)
        #expect(unknownCount == 0)
    }

    @Test("fleetSummary: windows outside the filter feed neither glyph nor counts")
    func fleetFilterMismatchIgnored() {
        // Weekly-only windows under a session filter: data exists but says
        // nothing about the asked window — not usable, not unknown, no color.
        let rows = [row(windows: [window(id: "w", percent: 0, scope: .weekly)])]
        #expect(OverviewBuilder.fleetSummary(rows: rows, filter: .session) == .unknown)
    }
}
