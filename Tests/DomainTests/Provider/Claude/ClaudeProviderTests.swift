import Testing
import Foundation
import Mockable
@testable import Domain
import Infrastructure

@Suite("ClaudeProvider Tests")
@MainActor
struct ClaudeProviderTests {

    private func makeSettingsRepository() -> MockProviderSettingsRepository {
        let mock = MockProviderSettingsRepository()
        given(mock).isEnabled(forProvider: .any, defaultValue: .any).willReturn(true)
        given(mock).isEnabled(forProvider: .any).willReturn(true)
        given(mock).setEnabled(.any, forProvider: .any).willReturn()
        return mock
    }

    // MARK: - Identity

    @Test
    func `claude provider has correct id`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.id == "claude")
    }

    @Test
    func `claude provider has correct name`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.name == "Claude")
    }

    @Test
    func `claude provider has correct cliCommand`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.cliCommand == "claude")
    }

    @Test
    func `claude provider has dashboard URL pointing to anthropic`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.dashboardURL != nil)
        #expect(claude.dashboardURL?.host?.contains("anthropic") == true)
    }

    @Test
    func `claude provider is enabled by default`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.isEnabled == true)
    }

    // MARK: - State

    @Test
    func `claude provider starts with no snapshot`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.snapshot == nil)
    }

    @Test
    func `claude provider starts not syncing`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.isSyncing == false)
    }

    @Test
    func `claude provider starts with no error`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.lastError == nil)
    }

    // MARK: - Delegation

    @Test
    func `claude provider delegates isAvailable to probe`() async {
        let settings = makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        given(mockProbe).isAvailable().willReturn(true)
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        let isAvailable = await claude.isAvailable()
        #expect(isAvailable == true)
    }

    @Test
    func `isAvailable returns false in API mode when API unavailable and CLI fallback disabled`() async {
        let settings = FakeClaudeSettings(probeMode: .api, cliFallbackEnabled: false)
        let cliProbe = MockUsageProbe()
        given(cliProbe).isAvailable().willReturn(true)
        let apiProbe = MockUsageProbe()
        given(apiProbe).isAvailable().willReturn(false)
        let claude = ClaudeProvider(cliProbe: cliProbe, apiProbe: apiProbe, settingsRepository: settings)

        #expect(await claude.isAvailable() == false)
    }

    @Test
    func `isAvailable returns true in API mode when API unavailable but CLI fallback enabled`() async {
        let settings = FakeClaudeSettings(probeMode: .api, cliFallbackEnabled: true)
        let cliProbe = MockUsageProbe()
        given(cliProbe).isAvailable().willReturn(true)
        let apiProbe = MockUsageProbe()
        given(apiProbe).isAvailable().willReturn(false)
        let claude = ClaudeProvider(cliProbe: cliProbe, apiProbe: apiProbe, settingsRepository: settings)

        #expect(await claude.isAvailable() == true)
    }

    @Test
    func `claude provider delegates refresh to probe`() async throws {
        let settings = makeSettingsRepository()
        let expectedSnapshot = UsageSnapshot(providerId: "claude", quotas: [], capturedAt: Date())
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willReturn(expectedSnapshot)
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        let snapshot = try await claude.refresh()
        #expect(snapshot.quotas.isEmpty)
    }

    // MARK: - Snapshot Storage

    @Test
    func `claude provider stores snapshot after refresh`() async throws {
        let settings = makeSettingsRepository()
        let expectedSnapshot = UsageSnapshot(
            providerId: "claude",
            quotas: [UsageQuota(percentRemaining: 50, quotaType: .session, providerId: "claude")],
            capturedAt: Date()
        )
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willReturn(expectedSnapshot)
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        #expect(claude.snapshot == nil)
        _ = try await claude.refresh()
        #expect(claude.snapshot != nil)
        #expect(claude.snapshot?.quotas.first?.percentRemaining == 50)
    }

    // MARK: - Error Handling

    @Test
    func `claude provider stores error on refresh failure`() async {
        let settings = makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willThrow(ProbeError.timeout)
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        #expect(claude.lastError == nil)
        do {
            _ = try await claude.refresh()
        } catch {
            // Expected
        }
        #expect(claude.lastError != nil)
    }

    // MARK: - Syncing State

    @Test
    func `claude provider resets isSyncing after refresh completes`() async throws {
        let settings = makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willReturn(UsageSnapshot(providerId: "claude", quotas: [], capturedAt: Date()))
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        #expect(claude.isSyncing == false)
        _ = try await claude.refresh()
        #expect(claude.isSyncing == false)
    }

    // MARK: - Equality via ID

    @Test
    func `two claude providers have same id`() {
        let settings = makeSettingsRepository()
        let provider1 = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        let provider2 = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(provider1.id == provider2.id)
    }

    // MARK: - Error Propagation When Both Probes Fail

    @Test
    func `refresh does not invoke CLI fallback when API returns rateLimited`() async {
        // When the API probe is rate-limited, the CLI probe talks to the
        // same Anthropic backend (subject to the same per-token throttle)
        // AND it's currently broken in the field. The rate-limit error
        // should surface immediately without the CLI probe being touched.
        let settings = FakeClaudeSettings(probeMode: .api, cliFallbackEnabled: true)

        let retryAt = Date().addingTimeInterval(300)
        let apiProbe = MockUsageProbe()
        given(apiProbe).isAvailable().willReturn(true)
        given(apiProbe).probe().willThrow(ProbeError.rateLimited(retryAt: retryAt))

        let cliProbe = MockUsageProbe()
        given(cliProbe).isAvailable().willReturn(true)

        let claude = ClaudeProvider(cliProbe: cliProbe, apiProbe: apiProbe, settingsRepository: settings)

        do {
            _ = try await claude.refresh()
            Issue.record("Expected refresh to throw")
        } catch let error as ProbeError {
            #expect(error == .rateLimited(retryAt: retryAt))
        } catch {
            Issue.record("Expected ProbeError, got \(error)")
        }

        // The CLI probe must never be invoked when the primary error is
        // an upstream rate-limit; fallback would amplify the throttle.
        verify(cliProbe).probe().called(0)
    }

    @Test
    func `refresh surfaces primary API error when CLI fallback also fails`() async {
        // API mode with CLI fallback enabled: API probe throws .rateLimited
        // (the real root cause), CLI fallback throws .parseFailed (a red
        // herring caused by the broken /usage stdout capture). The user
        // should see the rate-limit error, not the parse failure.
        let settings = FakeClaudeSettings(probeMode: .api, cliFallbackEnabled: true)

        let retryAt = Date().addingTimeInterval(300)
        let apiProbe = MockUsageProbe()
        given(apiProbe).isAvailable().willReturn(true)
        given(apiProbe).probe().willThrow(ProbeError.rateLimited(retryAt: retryAt))

        let cliProbe = MockUsageProbe()
        given(cliProbe).isAvailable().willReturn(true)
        given(cliProbe).probe().willThrow(ProbeError.parseFailed("Could not find session usage"))

        let claude = ClaudeProvider(cliProbe: cliProbe, apiProbe: apiProbe, settingsRepository: settings)

        do {
            _ = try await claude.refresh()
            Issue.record("Expected refresh to throw")
        } catch let error as ProbeError {
            #expect(error == .rateLimited(retryAt: retryAt))
            #expect(claude.lastError as? ProbeError == .rateLimited(retryAt: retryAt))
        } catch {
            Issue.record("Expected ProbeError, got \(error)")
        }
    }

    // MARK: - Background Refresh Floor (issue #204)

    @Test
    func `background refresh floor is 15 minutes in API mode`() {
        let settings = FakeClaudeSettings(probeMode: .api)
        let claude = ClaudeProvider(
            cliProbe: MockUsageProbe(),
            apiProbe: MockUsageProbe(),
            settingsRepository: settings
        )

        // API mode floors the background cadence to the API snapshot-cache TTL.
        #expect(claude.backgroundRefreshFloor == .seconds(900))
    }

    @Test
    func `background refresh floor is nil in CLI mode`() {
        let settings = FakeClaudeSettings(probeMode: .cli)
        let claude = ClaudeProvider(
            cliProbe: MockUsageProbe(),
            apiProbe: MockUsageProbe(),
            settingsRepository: settings
        )

        // CLI mode imposes no floor — it keeps the user's chosen interval.
        #expect(claude.backgroundRefreshFloor == nil)
    }

    @Test
    func `all-account refresh isolates failure and retains cached snapshot`() async {
        let settings = FakeMultiClaudeSettings(configs: [
            ProviderAccountConfig(accountId: "admin", label: "Admin", email: "admin@example.com", probeConfig: ["claudeConfigDir": "admin"]),
            ProviderAccountConfig(accountId: "personal", label: "Personal", email: "personal@example.com", probeConfig: ["claudeConfigDir": "personal"]),
        ])
        let adminProbe = ScriptedUsageProbe(results: [
            .success(Self.snapshot(percent: 70, email: "admin@example.com")),
            .success(Self.snapshot(percent: 65, email: "admin@example.com")),
        ])
        let techProbe = ScriptedUsageProbe(results: [
            .success(Self.snapshot(percent: 20, email: "personal@example.com")),
            .failure(ProbeError.executionFailed("personal credentials expired")),
        ])
        let provider = ClaudeProvider(
            cliProbe: adminProbe,
            apiProbe: MockUsageProbe(),
            settingsRepository: settings,
            cliProbeFactory: { $0 == "personal" ? techProbe : adminProbe },
            apiProbeFactory: { _ in nil }
        )

        await provider.refreshAllAccounts(.interactive)
        await provider.refreshAllAccounts(.background)

        #expect(provider.accountSnapshots["admin"]?.lowestQuota?.percentRemaining == 65)
        #expect(provider.accountSnapshots["personal"]?.lowestQuota?.percentRemaining == 20)
        #expect(provider.accountRefreshStates["admin"] == .ready)
        #expect(provider.accountRefreshStates["personal"] == .failed(message: "personal credentials expired"))
    }

    @Test
    func `account switch surfaces cached snapshot before refresh`() async throws {
        let settings = FakeMultiClaudeSettings(configs: [
            ProviderAccountConfig(accountId: "admin", label: "Admin", probeConfig: ["claudeConfigDir": "admin"]),
            ProviderAccountConfig(accountId: "personal", label: "Personal", probeConfig: ["claudeConfigDir": "personal"]),
        ])
        let adminProbe = ScriptedUsageProbe(results: [.success(Self.snapshot(percent: 80))])
        let techProbe = ScriptedUsageProbe(results: [.success(Self.snapshot(percent: 15))])
        let provider = ClaudeProvider(
            cliProbe: adminProbe,
            apiProbe: MockUsageProbe(),
            settingsRepository: settings,
            cliProbeFactory: { $0 == "personal" ? techProbe : adminProbe },
            apiProbeFactory: { _ in nil }
        )
        await provider.refreshAllAccounts()

        #expect(provider.switchAccount(to: "personal"))
        #expect(provider.activeAccount.accountId == "personal")
        #expect(provider.snapshot?.lowestQuota?.percentRemaining == 15)
        #expect(settings.activeId == "personal")
    }

    @Test
    func `menu bar selection uses worst account snapshot and matching identity`() async {
        let settings = FakeMultiClaudeSettings(configs: [
            ProviderAccountConfig(accountId: "admin", label: "Admin", email: "admin@example.com", probeConfig: ["claudeConfigDir": "admin"]),
            ProviderAccountConfig(accountId: "personal", label: "Personal", email: "personal@example.com", probeConfig: ["claudeConfigDir": "personal"]),
        ])
        let adminProbe = ScriptedUsageProbe(results: [.success(Self.snapshot(percent: 75, email: "admin@example.com"))])
        let techProbe = ScriptedUsageProbe(results: [.success(Self.snapshot(percent: 9, email: "personal@example.com"))])
        let provider = ClaudeProvider(
            cliProbe: adminProbe,
            apiProbe: MockUsageProbe(),
            settingsRepository: settings,
            cliProbeFactory: { $0 == "personal" ? techProbe : adminProbe },
            apiProbeFactory: { _ in nil }
        )
        await provider.refreshAllAccounts()
        let monitor = QuotaMonitor(
            providers: AIProviders(providers: [provider]),
            clock: ImmediateTestClock()
        )

        let selection = monitor.menuBarSnapshotSelection(providerId: "claude", quotaKeys: ["session"])
        let label = monitor.menuBarLabel(
            providerId: "claude",
            primaryQuotaKey: "session",
            showPercentage: true,
            showDuration: false,
            mode: .remaining
        )

        #expect(selection?.account?.accountId == "personal")
        #expect(selection?.snapshot.accountEmail == "personal@example.com")
        #expect(label?.text == "9%")
    }

    private static func snapshot(percent: Double, email: String? = nil) -> UsageSnapshot {
        UsageSnapshot(
            providerId: "claude",
            quotas: [UsageQuota(percentRemaining: percent, quotaType: .session, providerId: "claude")],
            capturedAt: Date(),
            accountEmail: email
        )
    }
}

// MARK: - Test Helpers

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

private final class FakeMultiClaudeSettings: ClaudeSettingsRepository, MultiAccountSettingsRepository, @unchecked Sendable {
    var configs: [ProviderAccountConfig]
    var activeId: String?

    init(configs: [ProviderAccountConfig], activeId: String? = nil) {
        self.configs = configs
        self.activeId = activeId
    }

    func isEnabled(forProvider id: String) -> Bool { true }
    func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool { true }
    func setEnabled(_ enabled: Bool, forProvider id: String) {}
    func customCardURL(forProvider id: String) -> String? { nil }
    func setCustomCardURL(_ url: String?, forProvider id: String) {}
    func claudeProbeMode() -> ClaudeProbeMode { .cli }
    func setClaudeProbeMode(_ mode: ClaudeProbeMode) {}
    func claudeCliFallbackEnabled() -> Bool { false }
    func setClaudeCliFallbackEnabled(_ enabled: Bool) {}
    func accounts(forProvider id: String) -> [ProviderAccountConfig] { configs }
    func addAccount(_ config: ProviderAccountConfig, forProvider id: String) { configs.append(config) }
    func removeAccount(accountId: String, forProvider id: String) { configs.removeAll { $0.accountId == accountId } }
    func updateAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        guard let index = configs.firstIndex(where: { $0.accountId == config.accountId }) else { return }
        configs[index] = config
    }
    func activeAccountId(forProvider id: String) -> String? { activeId }
    func setActiveAccountId(_ accountId: String?, forProvider id: String) { activeId = accountId }
}

private actor ScriptedUsageProbe: UsageProbe {
    private var results: [Result<UsageSnapshot, Error>]

    init(results: [Result<UsageSnapshot, Error>]) {
        self.results = results
    }

    func isAvailable() async -> Bool { true }

    func probe() async throws -> UsageSnapshot {
        let result = results.isEmpty
            ? Result<UsageSnapshot, Error>.failure(ProbeError.parseFailed("No scripted result"))
            : results.removeFirst()
        return try result.get()
    }
}

private struct ImmediateTestClock: Clock {
    func sleep(for duration: Duration) async throws {}
    func sleep(nanoseconds: UInt64) async throws {}
}
