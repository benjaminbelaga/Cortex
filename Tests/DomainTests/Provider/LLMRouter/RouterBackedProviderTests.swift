import Foundation
import Testing
@testable import Domain

@Suite("RouterBackedProvider")
@MainActor
struct RouterBackedProviderTests {
    @Test("fraction is converted to Cortex percent exactly once")
    func convertsFractionExactlyOnce() async throws {
        let provider = makeProvider(snapshot: Self.snapshot())

        let result = try await provider.refresh()

        #expect(result.quotas.first?.percentRemaining == 58)
        #expect(result.quotas.first?.percentRemaining != 0.58)
    }

    @Test("healthy account remains usable beside a missing expected account")
    func preservesHealthyAndMissingAccounts() async throws {
        let provider = makeProvider(snapshot: Self.snapshot())

        _ = try await provider.refresh()

        #expect(provider.accounts.map(\.accountId) == ["WORK", "PERSONAL"])
        #expect(provider.accountSnapshots["WORK"]?.quotas.first?.percentRemaining == 58)
        #expect(provider.accountSnapshots["PERSONAL"] == nil)
        #expect(provider.lastGroupErrors["PERSONAL"]?.contains("absent") == true)
        #expect(provider.activeAccount.accountId == "WORK")
        #expect(provider.snapshot?.quotas.first?.percentRemaining == 58)
    }

    @Test("dead refresh token renders the guided reconnect action, not veille")
    func deadRefreshTokenIsReconnectable() async throws {
        // Broker reality for a seat whose OAuth refresh token died:
        // present in the ledger, inactive, auth_state=error. The row must
        // offer the "Connecter" action instead of claiming a healthy standby.
        let deadSeat = RouterQuotaSnapshot(
            generatedAt: Self.now,
            providers: [
                "claude": RouterProviderQuota(
                    providerId: "claude",
                    windows: [],
                    source: "quota_broker",
                    capturedAt: Self.now,
                    accounts: [
                        RouterAccountQuota(
                            alias: "WORK",
                            present: true,
                            error: "re-login needed — refresh token dead",
                            active: false,
                            authState: "error"
                        ),
                    ]
                )
            ]
        )
        let provider = makeProvider(snapshot: deadSeat)

        _ = try await provider.refresh()

        #expect(
            provider.lastGroupErrors["WORK"]?.contains(
                RouterBackedProvider.reconnectMessage
            ) == true
        )
        #expect(provider.lastGroupErrors["WORK"]?.contains("Standby") == false)
    }

    @Test("overview renders missing account as an error, never healthy syncing data")
    func overviewSurfacesMissingAccount() async throws {
        let provider = makeProvider(snapshot: Self.snapshot())
        _ = try await provider.refresh()

        let rows = OverviewBuilder.build(providers: [provider])
        let missing = rows.first { $0.id == "claude|PERSONAL" }

        #expect(rows.first { $0.id == "claude|WORK" }?.windows.first?.percentRemaining == 58)
        #expect(missing?.windows.isEmpty == true)
        #expect(missing?.isSyncing == false)
        #expect(missing?.errorMessage?.contains("absent") == true)
        #expect(missing?.status(matching: .all) == .depleted)
    }

    @Test("last-good fallback is visible on every otherwise healthy account")
    func exposesStaleFallback() async throws {
        let stale = RouterQuotaSnapshot(
            generatedAt: Self.now,
            providers: Self.snapshot().providers,
            isStale: true,
            fallbackError: "router unavailable"
        )
        let provider = makeProvider(snapshot: stale)

        _ = try await provider.refresh()

        #expect(provider.lastGroupErrors["WORK"]?.contains("last known") == true)
        #expect(provider.lastGroupErrors["WORK"]?.contains("router unavailable") == true)
        #expect(provider.lastGroupErrors["PERSONAL"]?.contains("absent") == true)
    }

    @Test("local email joins only through explicit routerAlias metadata")
    func joinsLocalMetadataOnlyWithExplicitAlias() async throws {
        let settings = FakeMultiAccountSettings(accounts: [
            ProviderAccountConfig(
                accountId: "misleading-WORK",
                label: "WORK",
                email: "wrong@example.com"
            ),
            ProviderAccountConfig(
                accountId: "local-personal",
                label: "Local Personal",
                email: "personal@example.com",
                probeConfig: ["routerAlias": "PERSONAL"]
            ),
        ])
        let provider = makeProvider(snapshot: Self.snapshot(), settings: settings)

        _ = try await provider.refresh()

        #expect(provider.accounts.first { $0.accountId == "WORK" }?.email == nil)
        #expect(provider.accounts.first { $0.accountId == "PERSONAL" }?.email == "personal@example.com")
    }

    @Test("two distinct Claude identities remain distinct across refresh")
    func preservesBothClaudeIdentities() async throws {
        let settings = FakeMultiAccountSettings(accounts: [
            ProviderAccountConfig(
                accountId: "local-work",
                label: "Work",
                email: "work@example.com",
                probeConfig: ["routerAlias": "WORK"]
            ),
            ProviderAccountConfig(
                accountId: "local-personal",
                label: "Personal",
                email: "personal@example.com",
                probeConfig: ["routerAlias": "PERSONAL"]
            ),
        ])
        let measured = RouterQuotaWindow(kind: "five_hour", remainingFraction: 0.58)
        let snapshot = RouterQuotaSnapshot(
            generatedAt: Self.now,
            providers: [
                "claude": RouterProviderQuota(
                    providerId: "claude",
                    windows: [measured],
                    source: "quota_broker",
                    capturedAt: Self.now,
                    accounts: [
                        RouterAccountQuota(alias: "WORK", windows: [measured]),
                        RouterAccountQuota(alias: "PERSONAL", windows: [measured]),
                    ]
                )
            ]
        )
        let provider = makeProvider(snapshot: snapshot, settings: settings)

        _ = try await provider.refresh()

        #expect(provider.accounts.map(\.accountId) == ["WORK", "PERSONAL"])
        #expect(provider.accounts.map(\.email) == ["work@example.com", "personal@example.com"])
        #expect(provider.accountSnapshots.keys.sorted() == ["PERSONAL", "WORK"])
    }

    @Test("manual-only router windows are detected so the live fallback can take over")
    func detectsManualOnlyWindows() {
        // llm-router published Alibaba as a single `manual` window at grade C
        // (stale console sync) while `bl console` answered live — the row froze
        // at 100 % until this detection let the native probe override it.
        let manual = RouterQuotaWindow(kind: "manual", remainingFraction: 0.999997)
        let measured = RouterQuotaWindow(kind: "five_hour", remainingFraction: 0.58)
        #expect(RouterBackedProvider.isManualOnly([manual]))
        #expect(!RouterBackedProvider.isManualOnly([manual, measured]))
        #expect(!RouterBackedProvider.isManualOnly([measured]))
        #expect(!RouterBackedProvider.isManualOnly([]))
    }

    @Test("a failed live fallback surfaces its actionable hint instead of a blank row")
    func failedFallbackIsVisible() async throws {
        // Ben 2026-09-28: "alibaba n'est pas visible". Root cause — the manual-only
        // placeholder stayed on screen and the native `bl console` fallback failed
        // (expired console session) while `try?` swallowed the probe's own
        // actionable message. The reason must reach the row.
        let provider = RouterBackedProvider(
            id: "qwen",
            name: "Alibaba Token Plan",
            routerProviderId: "bailian_token_plan",
            cliCommand: "qwen",
            source: StaticRouterSource(value: Self.manualOnlySnapshot()),
            settingsRepository: FakeMultiAccountSettings(),
            nativeFallbackProbe: { FailingProbe() }
        )

        _ = try await provider.refresh()

        let message = provider.lastGroupErrors[provider.activeAccount.accountId]
        #expect(message?.contains("Session expired") == true)
        #expect(message?.contains("bl auth login --console") == true)
    }

    @Test("a successful live fallback clears any previous failure message")
    func successfulFallbackClearsMessage() async throws {
        let provider = RouterBackedProvider(
            id: "qwen",
            name: "Alibaba Token Plan",
            routerProviderId: "bailian_token_plan",
            cliCommand: "qwen",
            source: StaticRouterSource(value: Self.manualOnlySnapshot()),
            settingsRepository: FakeMultiAccountSettings(),
            nativeFallbackProbe: { LiveProbe() }
        )

        let refreshed = try await provider.refresh()

        #expect(refreshed.quotas.first?.percentRemaining == 42)
        #expect(provider.lastGroupErrors[provider.activeAccount.accountId] == nil)
    }

    @Test("the fallback message never comes back empty")
    func fallbackMessageIsNeverEmpty() {
        struct Opaque: Error {}
        #expect(RouterBackedProvider.fallbackMessage(for: ProbeError.sessionExpired(hint: "h"))
            == "Session expired. h")
        #expect(!RouterBackedProvider.fallbackMessage(for: Opaque()).isEmpty)
    }

    private func makeProvider(
        snapshot: RouterQuotaSnapshot,
        settings: FakeMultiAccountSettings = FakeMultiAccountSettings()
    ) -> RouterBackedProvider {
        RouterBackedProvider(
            id: "claude",
            name: "Claude",
            routerProviderId: "claude",
            cliCommand: "claude",
            source: StaticRouterSource(value: snapshot),
            settingsRepository: settings
        )
    }

    private static let now = Date(timeIntervalSince1970: 1_787_263_200)

    /// Alibaba's real shape: one `manual` window (stale grade-C console sync),
    /// which is exactly what unlocks the native fallback.
    private static func manualOnlySnapshot() -> RouterQuotaSnapshot {
        RouterQuotaSnapshot(
            generatedAt: now,
            providers: [
                "bailian_token_plan": RouterProviderQuota(
                    providerId: "bailian_token_plan",
                    windows: [RouterQuotaWindow(kind: "manual", remainingFraction: 0.999997)],
                    source: "console-tokenplan-personal",
                    capturedAt: now
                )
            ]
        )
    }

    private static func snapshot() -> RouterQuotaSnapshot {
        let measured = RouterQuotaWindow(kind: "five_hour", remainingFraction: 0.58)
        return RouterQuotaSnapshot(
            generatedAt: now,
            providers: [
                "claude": RouterProviderQuota(
                    providerId: "claude",
                    windows: [measured],
                    source: "quota_broker",
                    capturedAt: now,
                    accounts: [
                        RouterAccountQuota(alias: "WORK", windows: [measured]),
                        RouterAccountQuota(
                            alias: "PERSONAL",
                            present: false,
                            error: "compte attendu absent du relevé",
                            active: false
                        ),
                    ],
                    warnings: ["PERSONAL: compte attendu absent du relevé"]
                )
            ]
        )
    }
}

private struct StaticRouterSource: RouterQuotaSnapshotProviding {
    let value: RouterQuotaSnapshot

    func isAvailable() async -> Bool { true }
    func snapshot(
        forceRefresh: Bool,
        usageMaxAgeSeconds: TimeInterval
    ) async throws -> RouterQuotaSnapshot { value }
}

/// Mimics `QwenPlanUsageProbe` against an expired console session.
private struct FailingProbe: UsageProbe {
    func isAvailable() async -> Bool { true }
    func probe() async throws -> UsageSnapshot {
        throw ProbeError.sessionExpired(
            hint: "Connect the Alibaba console with bl auth login --console, then refresh.")
    }
}

/// Publishes a real window so the fallback is proven to win over the placeholder.
private struct LiveProbe: UsageProbe {
    func isAvailable() async -> Bool { true }
    func probe() async throws -> UsageSnapshot {
        UsageSnapshot(
            providerId: "qwen",
            quotas: [UsageQuota(percentRemaining: 42, quotaType: .session, providerId: "qwen")],
            capturedAt: Date(timeIntervalSince1970: 1_787_263_200)
        )
    }
}

private final class FakeMultiAccountSettings: MultiAccountSettingsRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var configuredAccounts: [ProviderAccountConfig]
    private var activeId: String?
    private var enabled = true

    init(accounts: [ProviderAccountConfig] = []) {
        configuredAccounts = accounts
    }

    func isEnabled(forProvider id: String) -> Bool { lock.withLock { enabled } }
    func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool { lock.withLock { enabled } }
    func setEnabled(_ enabled: Bool, forProvider id: String) { lock.withLock { self.enabled = enabled } }
    func customCardURL(forProvider id: String) -> String? { nil }
    func setCustomCardURL(_ url: String?, forProvider id: String) {}

    func accounts(forProvider id: String) -> [ProviderAccountConfig] {
        lock.withLock { configuredAccounts }
    }

    func addAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        lock.withLock { configuredAccounts.append(config) }
    }

    func removeAccount(accountId: String, forProvider id: String) {
        lock.withLock { configuredAccounts.removeAll { $0.accountId == accountId } }
    }

    func updateAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        lock.withLock {
            guard let index = configuredAccounts.firstIndex(where: { $0.accountId == config.accountId }) else { return }
            configuredAccounts[index] = config
        }
    }

    func activeAccountId(forProvider id: String) -> String? { lock.withLock { activeId } }
    func setActiveAccountId(_ accountId: String?, forProvider id: String) { lock.withLock { activeId = accountId } }
}
