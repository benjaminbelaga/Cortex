import Foundation
import Testing
@testable import Domain

/// D2 tranche — the typed projection from a Claude statusline JSON payload
/// to a `ClaudeRateLimitObservation`. The pinned regression class is
/// "fabricated 0% from a missing field": a payload that omits
/// `used_percentage` for a window must surface as `percentRemaining: nil`,
/// never as 0. Likewise `seven_day` absent ⇒ the observation carries only
/// one window; `timestamp` absent ⇒ parse returns nil rather than throwing.
@Suite("ClaudeRateLimitObservation parsing")
struct ClaudeRateLimitObservationTests {

    private static let ts: String = "2026-09-16T18:00:00.123Z"

    private func payload(
        includeFiveHour: Bool = true,
        fiveHourUsed: Double? = 30,
        fiveHourResetsAt: String? = "2026-09-16T22:00:00Z",
        includeSevenDay: Bool = true,
        sevenDayUsed: Double? = 12,
        includeTimestamp: Bool = true,
        timestamp: String? = nil,
        modelId: String? = "claude-opus-4-5",
        sessionId: String? = "sess-abc"
    ) -> Data {
        var root: [String: Any] = [:]
        if includeTimestamp {
            root["timestamp"] = timestamp ?? Self.ts
        }
        if let modelId {
            root["model"] = ["id": modelId]
        }
        if let sessionId {
            root["session_id"] = sessionId
        }
        var rateLimits: [String: Any] = [:]
        if includeFiveHour {
            var entry: [String: Any] = [:]
            if let fiveHourUsed {
                entry["used_percentage"] = fiveHourUsed
            }
            if let fiveHourResetsAt {
                entry["resets_at"] = fiveHourResetsAt
            }
            rateLimits["five_hour"] = entry
        }
        if includeSevenDay {
            var entry: [String: Any] = [:]
            if let sevenDayUsed {
                entry["used_percentage"] = sevenDayUsed
            }
            rateLimits["seven_day"] = entry
        }
        root["rate_limits"] = rateLimits
        return try! JSONSerialization.data(withJSONObject: root, options: [.fragmentsAllowed])
    }

    @Test("used 30 in five_hour projects to percentRemaining 70")
    func fiveHourThirtyUsed() throws {
        let observation = try ClaudeRateLimitObservation.parse(
            payload(fiveHourUsed: 30),
            configDir: "/Users/ben/.claude"
        )
        #expect(observation != nil)
        let fiveHour = observation?.windows.first { $0.id == .fiveHour }
        #expect(fiveHour?.percentRemaining == 70)
    }

    @Test("seven_day absent produces a single-window observation")
    func sevenDayAbsent() throws {
        let observation = try ClaudeRateLimitObservation.parse(
            payload(includeSevenDay: false),
            configDir: "/Users/ben/.claude"
        )
        #expect(observation?.windows.count == 1)
        #expect(observation?.windows.first?.id == .fiveHour)
    }

    @Test("missing used_percentage in a window surfaces as nil — never as 0/100")
    func missingUsedPercentageYieldsNil() throws {
        let observation = try ClaudeRateLimitObservation.parse(
            payload(fiveHourUsed: nil),
            configDir: "/Users/ben/.claude"
        )
        let fiveHour = observation?.windows.first { $0.id == .fiveHour }
        #expect(fiveHour?.percentRemaining == nil,
                "absent used_percentage must read unknown, not 0% or 100%")
    }

    @Test("capturedAt comes from the payload's timestamp, not from the receiver clock")
    func capturedAtFromPayload() throws {
        let observation = try ClaudeRateLimitObservation.parse(
            payload(),
            configDir: "/Users/ben/.claude"
        )
        let parsed = ISO8601DateFormatter.cortex.parse(Self.ts)!
        #expect(observation?.capturedAt == parsed)
    }

    @Test("payload without timestamp returns nil (legacy shape, not an error)")
    func missingTimestampReturnsNil() throws {
        let observation = try ClaudeRateLimitObservation.parse(
            payload(includeTimestamp: false),
            configDir: "/Users/ben/.claude"
        )
        #expect(observation == nil)
    }

    @Test("payload with malformed timestamp throws")
    func malformedTimestampThrows() {
        #expect(throws: ClaudeRateLimitObservation.ParseError.self) {
            _ = try ClaudeRateLimitObservation.parse(
                payload(timestamp: "not-a-date"),
                configDir: "/Users/ben/.claude"
            )
        }
    }

    @Test("payload with no rate_limits parses successfully to a zero-window observation")
    func noRateLimitsYieldsEmptyWindows() throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["timestamp": Self.ts, "model": ["id": "x"], "session_id": "s"],
            options: [.fragmentsAllowed]
        )
        let observation = try ClaudeRateLimitObservation.parse(data, configDir: "/Users/ben/.claude")
        #expect(observation?.windows.isEmpty == true)
        #expect(observation?.modelId == "x")
        #expect(observation?.sessionId == "s")
    }

    @Test("non-object root returns nil (not a statusline payload)")
    func nonObjectRootReturnsNil() throws {
        let data = try JSONSerialization.data(withJSONObject: ["a", "b"], options: [])
        let observation = try ClaudeRateLimitObservation.parse(data, configDir: "/Users/ben/.claude")
        #expect(observation == nil)
    }

    @Test("malformed rate_limit entry throws invalidWindowShape")
    func malformedWindowShapeThrows() throws {
        var root: [String: Any] = [
            "timestamp": Self.ts,
            "rate_limits": ["five_hour": "this should be an object"]
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.fragmentsAllowed])
        #expect(throws: ClaudeRateLimitObservation.ParseError.self) {
            _ = try ClaudeRateLimitObservation.parse(data, configDir: "/Users/ben/.claude")
        }
    }

    @Test("WindowID.rawValue round-trips for known and unknown window names")
    func windowIDRoundTrip() {
        #expect(ClaudeRateLimitObservation.WindowID(rawValue: "five_hour") == .fiveHour)
        #expect(ClaudeRateLimitObservation.WindowID(rawValue: "seven_day") == .sevenDay)
        #expect(ClaudeRateLimitObservation.WindowID(rawValue: "experimental_rollout") == .raw("experimental_rollout"))
        #expect(ClaudeRateLimitObservation.WindowID.fiveHour.rawValue == "five_hour")
        #expect(ClaudeRateLimitObservation.WindowID(rawValue: "experimental_rollout").rawValue == "experimental_rollout")
    }
}
