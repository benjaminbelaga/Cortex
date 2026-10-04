import Testing
import Foundation
@testable import Cortex
@testable import Domain

/// A session source that failed to read must not surface as a fabricated zero:
/// its counters render "—" (unknown), while a source that read fine keeps its
/// real count — including a legitimate 0 ("jamais un faux zéro").
@Suite("Sessions activity counters — honest zero")
@MainActor
struct SessionsCounterPresentationTests {

    @Test("a failed source renders unknown, never a zero")
    func failedSourceIsUnknown() async {
        let model = SessionsActivityModel(sources: [
            StubSource(toolId: "cmux", observations: [], failure: "cmux state unreadable"),
        ])
        await model.refresh()

        #expect(SessionsCounterPresentation.count(model, toolId: "cmux") == nil)
        #expect(SessionsCounterPresentation.headline(model, toolId: "cmux") == "—")
        // The reason stays reachable, exactly as the section renders it.
        #expect(model.failure(for: "cmux") == "cmux state unreadable")
    }

    @Test("a source that read fine keeps its legitimate zero")
    func healthySourceKeepsZero() async {
        let model = SessionsActivityModel(sources: [
            StubSource(toolId: "cmux", observations: [], failure: nil),
        ])
        await model.refresh()

        #expect(SessionsCounterPresentation.count(model, toolId: "cmux") == 0)
        #expect(SessionsCounterPresentation.headline(model, toolId: "cmux") == "0 open · 0 working · 0 over 24 h")
    }

    @Test("a healthy source counts its observations")
    func healthySourceCounts() async {
        let model = SessionsActivityModel(sources: [
            StubSource(toolId: "cmux", observations: [
                SessionObservation(id: "a", toolId: "cmux", activity: .open),
                SessionObservation(id: "b", toolId: "cmux", activity: .working),
                SessionObservation(id: "c", toolId: "cmux", activity: .recent),
            ]),
        ])
        await model.refresh()

        #expect(SessionsCounterPresentation.count(model, toolId: "cmux") == 3)
        #expect(SessionsCounterPresentation.headline(model, toolId: "cmux") == "1 open · 1 working · 1 over 24 h")
    }

    @Test("a source that never reported is unknown, not zero")
    func neverReportedIsUnknown() {
        let model = SessionsActivityModel(sources: [])
        #expect(SessionsCounterPresentation.count(model, toolId: "cmux") == nil)
        #expect(SessionsCounterPresentation.headline(model, toolId: "cmux") == "—")
    }
}

/// A fixed session source: reports the given observations and optional failure.
private struct StubSource: SessionSource {
    let toolId: String
    var observations: [SessionObservation] = []
    var failure: String?

    func isDetected() async -> Bool { true }

    func collect(limit: Int, now: Date) async -> SessionSourceReport {
        SessionSourceReport(toolId: toolId, observations: observations, failure: failure)
    }
}
