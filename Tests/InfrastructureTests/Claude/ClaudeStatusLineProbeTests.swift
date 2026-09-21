import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// D2 tranche — the passive probe behind the Claude status-line adapter.
/// Gating: the probe refuses to do anything when the adapter setting is
/// off (the kill-switch principle). When the setting is on, it consumes
/// the latest observation from `StatusLineObserver` and projects it to
/// a `UsageSnapshot` whose `capturedAt` carries the **payload** time
/// (not the receiver clock), so an offline Claude session still ages
/// the row correctly.
@Suite("ClaudeStatusLineProbe")
struct ClaudeStatusLineProbeTests {

    /// The observer drops observations older than its `maxAge` window, so
    /// fixtures must carry a recent payload time. One minute in the past is
    /// fresh, stable, and still proves `capturedAt` comes from the payload.
    private static let ts: Date = Date().addingTimeInterval(-60)

    private func observation(
        configDir: String = "/Users/ben/.claude",
        windows: [ClaudeRateLimitObservation.Window] = [
            .init(id: .fiveHour, percentRemaining: 70,
                  resetsAt: ISO8601DateFormatter.cortex.parse("2026-09-16T22:00:00Z"),
                  resetText: "2026-09-16T22:00:00Z")
        ]
    ) -> ClaudeRateLimitObservation {
        ClaudeRateLimitObservation(
            configDir: configDir,
            capturedAt: Self.ts,
            modelId: "claude-opus-4-5",
            sessionId: "sess-abc",
            windows: windows
        )
    }

    @Test("isAvailable is false when the adapter setting is off, regardless of observations")
    func disabledSettingBlocksAvailability() async {
        let observer = StatusLineObserver()
        observer.recordForTesting(observation())
        let probe = ClaudeStatusLineProbe(
            configDir: "/Users/ben/.claude",
            observer: observer,
            settingsProvider: { false }
        )
        let available = await probe.isAvailable()
        #expect(available == false,
                "the kill-switch must override the observer even when a recent observation exists")
    }

    @Test("isAvailable is false when the setting is on but no observation exists for the configDir")
    func missingObservationForConfigDir() async {
        let observer = StatusLineObserver()
        // Record for a different configDir — must not satisfy this probe.
        observer.recordForTesting(observation(configDir: "/Users/other/.claude"))
        let probe = ClaudeStatusLineProbe(
            configDir: "/Users/ben/.claude",
            observer: observer,
            settingsProvider: { true }
        )
        let available = await probe.isAvailable()
        #expect(available == false,
                "an observation for another configDir must not satisfy this probe")
    }

    @Test("isAvailable is true when setting is on AND a fresh observation exists for the bound configDir")
    func enabledAndFresh() async {
        let observer = StatusLineObserver()
        observer.recordForTesting(observation())
        let probe = ClaudeStatusLineProbe(
            configDir: "/Users/ben/.claude",
            observer: observer,
            settingsProvider: { true }
        )
        let available = await probe.isAvailable()
        #expect(available == true)
    }

    @Test("probe() throws when the adapter is disabled")
    func probeThrowsWhenDisabled() async {
        let observer = StatusLineObserver()
        observer.recordForTesting(observation())
        let probe = ClaudeStatusLineProbe(
            configDir: "/Users/ben/.claude",
            observer: observer,
            settingsProvider: { false }
        )
        await #expect(throws: ProbeError.self) {
            _ = try await probe.probe()
        }
    }

    @Test("probe() throws when the observer has no observation yet")
    func probeThrowsWhenNoObservation() async {
        let observer = StatusLineObserver()
        let probe = ClaudeStatusLineProbe(
            configDir: "/Users/ben/.claude",
            observer: observer,
            settingsProvider: { true }
        )
        await #expect(throws: ProbeError.self) {
            _ = try await probe.probe()
        }
    }

    @Test("probe() maps an observation to a UsageSnapshot with the payload's capturedAt")
    func probeMapsObservationToSnapshot() async throws {
        let observer = StatusLineObserver()
        observer.recordForTesting(observation())
        let probe = ClaudeStatusLineProbe(
            configDir: "/Users/ben/.claude",
            observer: observer,
            settingsProvider: { true }
        )
        let snapshot = try await probe.probe()
        #expect(snapshot.providerId == "claude")
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas.first?.quotaType == .session)
        #expect(snapshot.quotas.first?.percentRemaining == 70)
        #expect(snapshot.quotas.first?.resetsAt != nil)
        #expect(snapshot.capturedAt == Self.ts,
                "capturedAt must come from the payload, not from the probe run time")
    }

    @Test("probe() drops windows whose percentRemaining is nil — never fabricates 0/100")
    func probeDropsUnknownWindows() async throws {
        let observer = StatusLineObserver()
        observer.recordForTesting(observation(windows: [
            .init(id: .fiveHour, percentRemaining: 70, resetsAt: nil, resetText: nil),
            // seven_day with no used_percentage — must drop, not become 0% or 100%.
            .init(id: .sevenDay, percentRemaining: nil, resetsAt: nil, resetText: nil),
        ]))
        let probe = ClaudeStatusLineProbe(
            configDir: "/Users/ben/.claude",
            observer: observer,
            settingsProvider: { true }
        )
        let snapshot = try await probe.probe()
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas.first?.quotaType == .session)
    }

    @Test("probe() maps unknown window names to modelSpecific quota types")
    func probeMapsUnknownWindowName() async throws {
        let observer = StatusLineObserver()
        observer.recordForTesting(observation(windows: [
            .init(id: .raw("experimental_rollout"), percentRemaining: 42,
                  resetsAt: nil, resetText: nil)
        ]))
        let probe = ClaudeStatusLineProbe(
            configDir: "/Users/ben/.claude",
            observer: observer,
            settingsProvider: { true }
        )
        let snapshot = try await probe.probe()
        #expect(snapshot.quotas.count == 1)
        if case .modelSpecific(let name) = snapshot.quotas.first?.quotaType {
            #expect(name == "experimental_rollout")
        } else {
            Issue.record("expected modelSpecific(\"experimental_rollout\") quota type")
        }
    }
}
