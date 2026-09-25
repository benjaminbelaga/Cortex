import Testing
import Foundation
@testable import Domain

/// Timeline recording for forks and compactions (Ben's ask, 2026-08-18).
@Suite
@MainActor
struct SessionTimelineTests {

    @Test("fork and compaction events land in the timeline, newest first")
    func notableEventsRecorded() {
        let monitor = SessionMonitor()
        let now = Date()

        monitor.processEvent(SessionEvent(
            sessionId: "a", eventName: .sessionStart, cwd: "/Users/tester/repos/x",
            receivedAt: now.addingTimeInterval(-120), source: "fork"
        ))
        monitor.processEvent(SessionEvent(
            sessionId: "a", eventName: .preCompact, cwd: "/Users/tester/repos/x",
            receivedAt: now.addingTimeInterval(-60)
        ))
        monitor.processEvent(SessionEvent(
            sessionId: "a", eventName: .postCompact, cwd: "/Users/tester/repos/x",
            receivedAt: now.addingTimeInterval(-30)
        ))
        // Ordinary events never qualify
        monitor.processEvent(SessionEvent(
            sessionId: "a", eventName: .userPromptSubmit, cwd: "/Users/tester/repos/x",
            receivedAt: now
        ))
        // Normal session starts (no fork source) never qualify
        monitor.processEvent(SessionEvent(
            sessionId: "b", eventName: .sessionStart, cwd: "/Users/tester/repos/y",
            receivedAt: now
        ))

        #expect(monitor.recentNotableEvents.count == 3)
        #expect(monitor.recentNotableEvents.first?.eventName == .postCompact)
        #expect(monitor.recentNotableEvents.last?.eventName == .sessionStart)
        #expect(monitor.recentNotableEvents.last?.source == "fork")
    }

    @Test("probe-origin events never pollute the timeline")
    func probeEventsFiltered() {
        let monitor = SessionMonitor()
        monitor.processEvent(SessionEvent(
            sessionId: "p", eventName: .postCompact,
            cwd: "/Users/tester/Library/Application Support/Cortex/Probe"
        ))
        #expect(monitor.recentNotableEvents.isEmpty)
    }

    @Test("timeline is capped at 20 entries")
    func timelineCapped() {
        let monitor = SessionMonitor()
        for i in 0..<30 {
            monitor.processEvent(SessionEvent(
                sessionId: "s\(i)", eventName: .preCompact,
                cwd: "/Users/tester/repos/x",
                receivedAt: Date().addingTimeInterval(Double(-i))
            ))
        }
        #expect(monitor.recentNotableEvents.count == 20)
    }
}
