import Testing
import Foundation
@testable import Cortex
@testable import Domain

/// The resets sheet must not print a stale reading as a live percentage: a
/// window the row list marked "stale" reads "stale" (muted), a truly empty one
/// reads "exhausted" — the same vocabulary as `WindowBarView`.
@Suite("Resets calendar value — stale/exhausted vocabulary")
struct ResetsCalendarValueTests {

    private func window(percent: Double, stale: Bool = false) -> WindowSnapshot {
        WindowSnapshot(
            id: "w", title: "5h", percentRemaining: percent,
            resetsAt: nil, compactReset: nil, scope: .session, isStale: stale
        )
    }

    @Test("a stale reading reads 'stale' and stays muted, never a red 0 %")
    func staleReadsStale() {
        let value = ResetsCalendarValue.from(window(percent: 0, stale: true))
        #expect(value.label == "stale")
        #expect(value.status == nil)
    }

    @Test("an empty window reads 'exhausted', never a bare 0 %")
    func emptyReadsExhausted() {
        let value = ResetsCalendarValue.from(window(percent: 0))
        #expect(value.label == "exhausted")
        #expect(value.status == .depleted)
    }

    @Test("a live reading keeps its percentage and its status colour")
    func liveKeepsPercent() {
        let value = ResetsCalendarValue.from(window(percent: 42))
        #expect(value.label == "42%")
        #expect(value.status == .warning)
    }
}
