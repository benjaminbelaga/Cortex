import Foundation
import Testing
import Mockable
@testable import Domain

@Suite
@MainActor
struct ExtensionProviderTests {
    // MARK: - Identity

    @Test
    func `provider has correct identity from manifest`() {
        let manifest = makeManifest(id: "openrouter", name: "OpenRouter")
        let provider = ExtensionProvider(
            manifest: manifest,
            probes: [:],
            settingsRepository: makeSettingsRepository()
        )

        #expect(provider.id == "ext-openrouter")
        #expect(provider.name == "OpenRouter")
        #expect(provider.cliCommand == "")
        #expect(provider.dashboardURL == URL(string: "https://openrouter.ai/activity"))
    }

    @Test
    func `provider id is prefixed with ext to avoid collisions`() {
        let manifest = makeManifest(id: "claude", name: "Claude Clone")
        let provider = ExtensionProvider(
            manifest: manifest,
            probes: [:],
            settingsRepository: makeSettingsRepository()
        )

        #expect(provider.id == "ext-claude")
    }

    // MARK: - Enabled State

    @Test
    func `provider reads enabled state from settings`() {
        let settings = MockProviderSettingsRepository()
        given(settings).isEnabled(forProvider: .any, defaultValue: .any).willReturn(false)
        given(settings).isEnabled(forProvider: .any).willReturn(false)
        given(settings).setEnabled(.any, forProvider: .any).willReturn()
        given(settings).customCardURL(forProvider: .any).willReturn(nil)
        given(settings).setCustomCardURL(.any, forProvider: .any).willReturn()

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: [:],
            settingsRepository: settings
        )

        #expect(provider.isEnabled == false)
    }

    @Test
    func `provider writes enabled state to settings`() {
        let settings = makeSettingsRepository()
        given(settings).setEnabled(.any, forProvider: .any).willReturn()

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: [:],
            settingsRepository: settings
        )

        provider.isEnabled = false

        verify(settings).setEnabled(.value(false), forProvider: .value("ext-test")).called(1)
    }

    // MARK: - Refresh

    @Test
    func `refresh runs all section probes and merges snapshots`() async throws {
        let quotaProbe = MockUsageProbe()
        let quotaSnapshot = UsageSnapshot(
            providerId: "ext-test",
            quotas: [UsageQuota(percentRemaining: 80, quotaType: .weekly, providerId: "ext-test")],
            capturedAt: Date()
        )
        given(quotaProbe).probe().willReturn(quotaSnapshot)

        let metricsProbe = MockUsageProbe()
        let metricsSnapshot = UsageSnapshot(
            providerId: "ext-test",
            quotas: [],
            capturedAt: Date(),
            extensionMetrics: [ExtensionMetric(label: "Cost", value: "$5", unit: "USD")]
        )
        given(metricsProbe).probe().willReturn(metricsSnapshot)

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["quotas": quotaProbe, "metrics": metricsProbe],
            settingsRepository: makeSettingsRepository()
        )

        let result = try await provider.refresh()

        #expect(result.quotas.count == 1)
        #expect(result.quotas[0].percentRemaining == 80)
        #expect(result.extensionMetrics?.count == 1)
        #expect(result.extensionMetrics?[0].label == "Cost")
        #expect(provider.snapshot != nil)
    }

    @Test
    func `refresh sets isSyncing during probe execution`() async throws {
        let probe = MockUsageProbe()
        given(probe).probe().willReturn(
            UsageSnapshot(providerId: "ext-test", quotas: [], capturedAt: Date())
        )

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["q": probe],
            settingsRepository: makeSettingsRepository()
        )

        #expect(provider.isSyncing == false)

        _ = try await provider.refresh()

        // After refresh completes, isSyncing should be false
        #expect(provider.isSyncing == false)
        #expect(provider.snapshot != nil)
    }

    @Test
    func `refresh stores error on probe failure`() async {
        let probe = MockUsageProbe()
        given(probe).probe().willThrow(ProbeError.executionFailed("script failed"))

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["q": probe],
            settingsRepository: makeSettingsRepository()
        )

        do {
            _ = try await provider.refresh()
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(provider.lastError != nil)
            #expect(provider.isSyncing == false)
        }
    }

    @Test
    func `refresh continues when one probe fails but others succeed`() async throws {
        let goodProbe = MockUsageProbe()
        given(goodProbe).probe().willReturn(
            UsageSnapshot(
                providerId: "ext-test",
                quotas: [UsageQuota(percentRemaining: 50, quotaType: .session, providerId: "ext-test")],
                capturedAt: Date()
            )
        )

        let badProbe = MockUsageProbe()
        given(badProbe).probe().willThrow(ProbeError.timeout)

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["good": goodProbe, "bad": badProbe],
            settingsRepository: makeSettingsRepository()
        )

        let result = try await provider.refresh()

        // Should still have data from the successful probe
        #expect(result.quotas.count == 1)
        // ...and the failed section must NOT be dropped: the provider is not
        // healthy just because part of the card filled in.
        #expect(provider.lastError != nil)
    }

    @Test
    func `a partial failure names the failed section on the merged snapshot`() async throws {
        let goodProbe = MockUsageProbe()
        given(goodProbe).probe().willReturn(
            UsageSnapshot(
                providerId: "ext-test",
                quotas: [UsageQuota(percentRemaining: 50, quotaType: .session, providerId: "ext-test")],
                capturedAt: Date()
            )
        )
        let badProbe = MockUsageProbe()
        given(badProbe).probe().willThrow(ProbeError.timeout)

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["good": goodProbe, "bad": badProbe],
            settingsRepository: makeSettingsRepository()
        )

        let result = try await provider.refresh()

        // The merged card keeps the good section's data...
        #expect(result.quotas.count == 1)
        #expect(provider.snapshot != nil)
        // ...but the failure is observable and names the section it came from.
        let failure = provider.lastError as? ExtensionSectionFailure
        #expect(failure?.sectionId == "bad")
        #expect(failure?.underlying as? ProbeError == .timeout)
    }

    @Test
    func `an all-success refresh leaves lastError nil`() async throws {
        let probe = MockUsageProbe()
        given(probe).probe().willReturn(
            UsageSnapshot(providerId: "ext-test", quotas: [], capturedAt: Date())
        )

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["q": probe],
            settingsRepository: makeSettingsRepository()
        )

        _ = try await provider.refresh()

        #expect(provider.snapshot != nil)
        #expect(provider.lastError == nil)
    }

    @Test
    func `a later all-success refresh clears a previous failure`() async throws {
        let probe = ScriptedProbe([
            .failure(ProbeError.timeout),
            .success(UsageSnapshot(providerId: "ext-test", quotas: [], capturedAt: Date())),
        ])
        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["q": probe],
            settingsRepository: makeSettingsRepository()
        )

        await #expect(throws: ProbeError.timeout) { try await provider.refresh() }
        #expect(provider.lastError != nil)

        _ = try await provider.refresh()
        #expect(provider.lastError == nil)
    }

    @Test
    func `an unconfigured section wins over another section's failure`() async throws {
        let goodProbe = MockUsageProbe()
        given(goodProbe).probe().willReturn(
            UsageSnapshot(providerId: "ext-test", quotas: [], capturedAt: Date())
        )
        let timeoutProbe = MockUsageProbe()
        given(timeoutProbe).probe().willThrow(ProbeError.timeout)
        let unconfiguredProbe = MockUsageProbe()
        given(unconfiguredProbe).probe().willThrow(ExtensionProbeError.unconfigured(fields: ["API Key"]))

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["good": goodProbe, "timeout": timeoutProbe, "unconfigured": unconfiguredProbe],
            settingsRepository: makeSettingsRepository()
        )

        _ = try await provider.refresh()

        // The actionable `.unconfigured` must still beat the anonymous timeout.
        #expect(provider.lastError as? ExtensionProbeError == .unconfigured(fields: ["API Key"]))
    }

    // MARK: - Availability

    @Test
    func `isAvailable returns true when at least one probe is available`() async {
        let probe = MockUsageProbe()
        given(probe).isAvailable().willReturn(true)

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["q": probe],
            settingsRepository: makeSettingsRepository()
        )

        let available = await provider.isAvailable()
        #expect(available == true)
    }

    @Test
    func `isAvailable returns false when no probes are available`() async {
        let probe = MockUsageProbe()
        given(probe).isAvailable().willReturn(false)

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["q": probe],
            settingsRepository: makeSettingsRepository()
        )

        let available = await provider.isAvailable()
        #expect(available == false)
    }

    // MARK: - Actionable failure surfacing

    @Test
    func `an unconfigured required field is surfaced, not collapsed into no-data`() async {
        let probe = MockUsageProbe()
        given(probe).probe().willThrow(ExtensionProbeError.unconfigured(fields: ["API Key"]))

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["q": probe],
            settingsRepository: makeSettingsRepository()
        )

        await #expect(throws: ExtensionProbeError.unconfigured(fields: ["API Key"])) {
            try await provider.refresh()
        }
        #expect(provider.lastError as? ExtensionProbeError == .unconfigured(fields: ["API Key"]))
    }

    @Test
    func `a probe that simply reports nothing still collapses to no-data`() async {
        let probe = MockUsageProbe()
        given(probe).probe().willThrow(ProbeError.noData)

        let provider = ExtensionProvider(
            manifest: makeManifest(id: "test", name: "Test"),
            probes: ["q": probe],
            settingsRepository: makeSettingsRepository()
        )

        await #expect(throws: ProbeError.noData) {
            try await provider.refresh()
        }
        #expect(provider.lastError is ProbeError)
    }

    // MARK: - Helpers

    private func makeManifest(id: String, name: String) -> ExtensionManifest {
        ExtensionManifest(
            id: id,
            name: name,
            version: "1.0.0",
            dashboardURL: URL(string: "https://openrouter.ai/activity"),
            sections: [
                ExtensionSection(id: "q", type: .quotaGrid, probeCommand: "./probe.sh")
            ]
        )
    }

    private func makeSettingsRepository() -> MockProviderSettingsRepository {
        let mock = MockProviderSettingsRepository()
        given(mock).isEnabled(forProvider: .any, defaultValue: .any).willReturn(true)
        given(mock).isEnabled(forProvider: .any).willReturn(true)
        given(mock).setEnabled(.any, forProvider: .any).willReturn()
        given(mock).customCardURL(forProvider: .any).willReturn(nil)
        given(mock).setCustomCardURL(.any, forProvider: .any).willReturn()
        return mock
    }
}

/// A probe whose behaviour is scripted per call, so a test can make one refresh
/// fail and a later one succeed (to observe `lastError` clearing). An actor, not
/// a lock: `NSLock.lock()` is unavailable from an async context under Swift 6
/// strict concurrency, and `Synchronization.Mutex` needs macOS 15 while this app
/// targets 14.0.
private actor ScriptedProbe: UsageProbe {
    private var results: [Result<UsageSnapshot, Error>]

    init(_ results: [Result<UsageSnapshot, Error>]) {
        self.results = results
    }

    func probe() async throws -> UsageSnapshot {
        guard !results.isEmpty else { throw ProbeError.noData }
        return try results.removeFirst().get()
    }

    func isAvailable() async -> Bool { true }
}
