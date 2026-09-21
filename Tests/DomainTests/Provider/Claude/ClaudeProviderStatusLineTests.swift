import Testing
import Foundation
import Mockable
@testable import Domain
@testable import Infrastructure

/// Status-line tier of `ClaudeProvider` (D2 wiring).
///
/// The passive probe is consulted LAST, after the CLI/API chain, and only
/// when it reports itself available (adapter enabled + fresh observation —
/// the probe gates that itself). These tests pin the ordering contract:
/// existing CLI/API behaviour is unchanged when no factory is provided,
/// and a disabled or stale status-line tier is invisible (never fabricated).
@Suite("ClaudeProvider status-line fallback")
@MainActor
struct ClaudeProviderStatusLineTests {

    /// Canned-result probe: the status-line tier in these tests is a stub
    /// standing in for `ClaudeStatusLineProbe` (whose own gating is covered
    /// by its dedicated suite). Local because `ScriptedUsageProbe` in
    /// `ClaudeProviderTests.swift` is file-private.
    private actor StubStatusLineProbe: UsageProbe {
        private var results: [Result<UsageSnapshot, Error>]

        init(results: [Result<UsageSnapshot, Error>]) {
            self.results = results
        }

        func isAvailable() async -> Bool { true }

        func probe() async throws -> UsageSnapshot {
            guard !results.isEmpty else {
                throw ProbeError.parseFailed("No scripted result")
            }
            return try results.removeFirst().get()
        }
    }

    private final class FakeClaudeSettings: ClaudeSettingsRepository, @unchecked Sendable {
        var probeMode: ClaudeProbeMode
        var cliFallbackEnabled: Bool

        init(probeMode: ClaudeProbeMode = .cli, cliFallbackEnabled: Bool = true) {
            self.probeMode = probeMode
            self.cliFallbackEnabled = cliFallbackEnabled
        }

        func isEnabled(forProvider id: String) -> Bool { true }
        func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool { true }
        func setEnabled(_ enabled: Bool, forProvider id: String) {}
        func customCardURL(forProvider id: String) -> String? { nil }
        func setCustomCardURL(_ url: String?, forProvider id: String) {}
        func claudeProbeMode() -> ClaudeProbeMode { probeMode }
        func setClaudeProbeMode(_ mode: ClaudeProbeMode) { probeMode = mode }
        func claudeCliFallbackEnabled() -> Bool { cliFallbackEnabled }
        func setClaudeCliFallbackEnabled(_ enabled: Bool) { cliFallbackEnabled = enabled }
    }

    private func statusLineSnapshot(capturedAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            providerId: "claude",
            quotas: [UsageQuota(percentRemaining: 70, quotaType: .session, providerId: "claude")],
            capturedAt: capturedAt
        )
    }

    private func failingCli() -> MockUsageProbe {
        let cli = MockUsageProbe()
        given(cli).isAvailable().willReturn(true)
        given(cli).probe().willThrow(ProbeError.executionFailed("claude not on PATH"))
        return cli
    }

    /// Unavailable API probe: reports itself unavailable *and* fails when
    /// probed. API mode consults its active tier directly, so a probe that is
    /// merely unavailable must still answer deterministically here — an
    /// unstubbed Mockable call reports a test issue instead (and crashes the
    /// host while formatting it).
    private func unavailableApi() -> MockUsageProbe {
        let api = MockUsageProbe()
        given(api).isAvailable().willReturn(false)
        given(api).probe().willThrow(ProbeError.executionFailed("API probe unavailable"))
        return api
    }

    @Test("no factory preserves legacy behavior — primary error surfaces")
    func noFactoryPreservesLegacyBehavior() async {
        let settings = FakeClaudeSettings()
        let claude = ClaudeProvider(
            cliProbe: failingCli(),
            apiProbe: unavailableApi(),
            settingsRepository: settings
        )
        await #expect(throws: ProbeError.self) {
            _ = try await claude.refresh()
        }
    }

    @Test("CLI fails then status-line serves the fresh observation")
    func cliFailsThenStatusLineServes() async throws {
        let settings = FakeClaudeSettings()
        let expected = statusLineSnapshot()
        let claude = ClaudeProvider(
            cliProbe: failingCli(),
            apiProbe: unavailableApi(),
            settingsRepository: settings,
            statusLineProbeFactory: { _ in StubStatusLineProbe(results: [.success(expected)]) }
        )
        let snapshot = try await claude.refresh()
        #expect(snapshot.capturedAt == expected.capturedAt)
        #expect(snapshot.quotas.first?.percentRemaining == 70)
    }

    @Test("disabled status-line tier is invisible — primary error surfaces")
    func disabledStatusLineIsInvisible() async {
        let settings = FakeClaudeSettings()
        // Probe reports unavailable (adapter off / stale observation):
        // the chain must behave exactly as if no factory existed.
        let dark = MockUsageProbe()
        given(dark).isAvailable().willReturn(false)
        let claude = ClaudeProvider(
            cliProbe: failingCli(),
            apiProbe: unavailableApi(),
            settingsRepository: settings,
            statusLineProbeFactory: { _ in dark }
        )
        await #expect(throws: ProbeError.self) {
            _ = try await claude.refresh()
        }
        // Availability is unchanged by the dark tier: nothing available
        // anywhere means unavailable, with or without the factory.
        let quiet = ClaudeProvider(
            cliProbe: unavailableApi(),
            apiProbe: unavailableApi(),
            settingsRepository: settings,
            statusLineProbeFactory: { _ in dark }
        )
        #expect(await quiet.isAvailable() == false)
    }

    @Test("API mode falls back to CLI then status-line")
    func apiModeFallsBackToCliThenStatusLine() async throws {
        let settings = FakeClaudeSettings(probeMode: .api)
        let expected = statusLineSnapshot()
        let claude = ClaudeProvider(
            cliProbe: failingCli(),
            apiProbe: unavailableApi(),
            settingsRepository: settings,
            statusLineProbeFactory: { _ in StubStatusLineProbe(results: [.success(expected)]) }
        )
        let snapshot = try await claude.refresh()
        #expect(snapshot.capturedAt == expected.capturedAt)
    }

    @Test("rate-limited primary never consults the status-line tier")
    func rateLimitedPrimarySkipsStatusLine() async {
        let settings = FakeClaudeSettings()
        let cli = MockUsageProbe()
        given(cli).isAvailable().willReturn(true)
        given(cli).probe().willThrow(ProbeError.rateLimited(retryAt: Date().addingTimeInterval(60)))
        // A serving status-line probe that must NOT be touched: rate limiting
        // is a backend throttle, the passive tier cannot help.
        let claude = ClaudeProvider(
            cliProbe: cli,
            apiProbe: unavailableApi(),
            settingsRepository: settings,
            statusLineProbeFactory: { _ in StubStatusLineProbe(results: [.success(self.statusLineSnapshot())]) }
        )
        do {
            _ = try await claude.refresh()
            Issue.record("expected rateLimited to propagate")
        } catch let error as ProbeError {
            guard case .rateLimited = error else {
                Issue.record("expected rateLimited, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ProbeError, got \(error)")
        }
    }

    @Test("isAvailable is true on status-line-only availability")
    func isAvailableOnStatusLineOnly() async {
        let settings = FakeClaudeSettings()
        let statusLine = MockUsageProbe()
        given(statusLine).isAvailable().willReturn(true)
        let claude = ClaudeProvider(
            cliProbe: unavailableApi(),
            apiProbe: unavailableApi(),
            settingsRepository: settings,
            statusLineProbeFactory: { _ in statusLine }
        )
        #expect(await claude.isAvailable() == true)
    }
}
