import Foundation
import Testing
@testable import Infrastructure

@Suite("Guardian state reader")
struct GuardianStateReaderTests {
    @Test("decodes the live counters including live_opencode")
    func decodesLiveCounters() {
        let payload = #"""
        {"ts":1774532241.13,"status":"yellow",
         "metrics":{"live_claude":2,"live_codex":28,"live_opencode":32,
                    "swap_used_pct":61.2,"load1":12.4},
         "findings":[]}
        """#
        let snapshot = GuardianStateReader.decode(
            Data(payload.utf8), now: Date(timeIntervalSince1970: 1774532241.13))

        #expect(snapshot?.status == "yellow")
        #expect(snapshot?.metrics.liveClaude == 2)
        #expect(snapshot?.metrics.liveCodex == 28)
        #expect(snapshot?.metrics.liveOpencode == 32)
        #expect(snapshot?.metrics.swapUsedPct == 61.2)
        #expect(snapshot?.isStale == false)
    }

    @Test("a snapshot past the staleness gate is flagged, never silently fresh")
    func staleSnapshotIsFlagged() {
        let payload = #"{"ts":1000,"status":"green","metrics":{},"findings":[]}"#
        let snapshot = GuardianStateReader.decode(
            Data(payload.utf8), now: Date(timeIntervalSince1970: 1000 + 200))

        #expect(snapshot?.isStale == true)
        #expect(snapshot?.metrics.liveOpencode == nil)
    }

    @Test("an unreadable payload yields nil rather than a healthy default")
    func unreadablePayloadIsNil() {
        #expect(GuardianStateReader.decode(Data("{ not json".utf8)) == nil)
    }
}
