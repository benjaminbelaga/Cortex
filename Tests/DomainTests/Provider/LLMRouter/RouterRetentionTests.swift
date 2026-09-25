import Foundation
import Testing
@testable import Domain

/// D tranche — retention & typed auth states on `RouterBackedProvider`.
///
/// The regression class these tests pin: "un compte encore listé sans nouvelle
/// lecture perd ses derniers quotas" — a roster account whose collection
/// failed must KEEP its previous reading (flagged stale, original capture
/// date), a standby account keeps its reading instead of dropping to
/// "Standby" alone, and the reconnect affordance reads a typed
/// `AccountAuthState`, never a message-string heuristic.
@Suite("RouterBackedProvider retention & auth states")
@MainActor
struct RouterRetentionTests {

    private static let firstReading = Date(timeIntervalSince1970: 1_787_263_200)
    private static let secondReading = Date(timeIntervalSince1970: 1_787_263_200 + 3_600)

    private func measured(_ fraction: Double) -> RouterQuotaWindow {
        RouterQuotaWindow(kind: "five_hour", remainingFraction: fraction)
    }

    private func snapshot(
        at date: Date,
        accounts: [RouterAccountQuota]
    ) -> RouterQuotaSnapshot {
        RouterQuotaSnapshot(
            generatedAt: date,
            providers: [
                "claude": RouterProviderQuota(
                    providerId: "claude",
                    windows: [],
                    source: "quota_broker",
                    capturedAt: date,
                    accounts: accounts
                )
            ]
        )
    }

    @Test("an account whose collection failed keeps its last reading, stale, original age")
    func retainsLastReadingWhenAccountDropsOut() async throws {
        let source = ScriptedRouterSource()
        let provider = RouterBackedProvider(
            id: "claude", name: "Claude", routerProviderId: "claude",
            cliCommand: "claude", source: source,
            settingsRepository: RetentionFakeSettings()
        )
        // Cycle 1: WORK reports a fresh 58% window.
        source.update(snapshot(at: Self.firstReading, accounts: [
            RouterAccountQuota(alias: "WORK", windows: [measured(0.58)]),
        ]))
        _ = try await provider.refresh()
        #expect(provider.accountSnapshots["WORK"]?.quotas.first?.isStale == false)

        // Cycle 2: still on the roster, but its reading failed (no window).
        source.update(snapshot(at: Self.secondReading, accounts: [
            RouterAccountQuota(alias: "WORK", windows: []),
        ]))
        _ = try await provider.refresh()

        let retained = provider.accountSnapshots["WORK"]
        #expect(retained != nil, "the account must not lose its last quotas on a failed cycle")
        #expect(retained?.quotas.first?.percentRemaining == 58)
        #expect(retained?.quotas.first?.isStale == true)
        #expect(retained?.capturedAt == Self.firstReading,
                "the age badge must show the ORIGINAL capture date, not the failed refresh")
    }

    @Test("a standby account keeps its reading instead of dropping to a bare veille message")
    func veilleKeepsReading() async throws {
        let provider = RouterBackedProvider(
            id: "claude", name: "Claude", routerProviderId: "claude",
            cliCommand: "claude",
            source: ScriptedRouterSource(snapshot(at: Self.firstReading, accounts: [
                RouterAccountQuota(alias: "PERSONAL", windows: [measured(0.40)], active: false),
                RouterAccountQuota(alias: "WORK", windows: [measured(0.58)]),
            ])),
            settingsRepository: RetentionFakeSettings()
        )

        _ = try await provider.refresh()

        let standby = provider.accountSnapshots["PERSONAL"]
        #expect(standby?.quotas.isEmpty == false,
                "veille must keep the reading, not drop it")
        #expect(standby?.quotas.first?.isStale == true,
                "the router only refreshes the active seat — the standby reading is old")
        #expect(provider.lastGroupErrors["PERSONAL"]?.contains("Standby") == true)
    }

    @Test("typed auth states map the router's own present/auth_state fields")
    func authStatesMapping() async throws {
        let provider = RouterBackedProvider(
            id: "claude", name: "Claude", routerProviderId: "claude",
            cliCommand: "claude",
            source: ScriptedRouterSource(snapshot(at: Self.firstReading, accounts: [
                RouterAccountQuota(alias: "HEALTHY", windows: [measured(0.5)]),
                RouterAccountQuota(alias: "VEILLE", windows: [measured(0.5)]),
                RouterAccountQuota(
                    alias: "ABSENT", present: false,
                    error: "compte attendu absent du relevé",
                    active: false
                ),
                RouterAccountQuota(
                    alias: "DEADTOKEN", present: true,
                    error: "re-login needed — refresh token dead",
                    active: false,
                    authState: "error"
                ),
            ])),
            settingsRepository: RetentionFakeSettings()
        )

        _ = try await provider.refresh()

        #expect(provider.accountAuthStates["HEALTHY"] == AccountAuthState.connected)
        #expect(provider.accountAuthStates["VEILLE"] == AccountAuthState.connected,
                "standby is the normal single-active model, not a disconnection")
        #expect(provider.accountAuthStates["ABSENT"] == .reconnectRequired)
        #expect(provider.accountAuthStates["DEADTOKEN"] == .reconnectRequired)
    }

    @Test("the overview row carries the typed auth state for a disconnected account")
    func overviewThreadsAuthState() async throws {
        let provider = RouterBackedProvider(
            id: "claude", name: "Claude", routerProviderId: "claude",
            cliCommand: "claude",
            source: ScriptedRouterSource(snapshot(at: Self.firstReading, accounts: [
                RouterAccountQuota(
                    alias: "ABSENT", present: false,
                    error: "compte attendu absent du relevé",
                    active: false
                ),
            ])),
            settingsRepository: RetentionFakeSettings()
        )

        _ = try await provider.refresh()

        let row = OverviewBuilder.build(providers: [provider])
            .first { $0.accountLabel == "ABSENT" }
        #expect(row?.authState == AccountAuthState.reconnectRequired)
        #expect(row?.needsReconnect == true)
    }
}

private final class ScriptedRouterSource: RouterQuotaSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: RouterQuotaSnapshot

    init(_ value: RouterQuotaSnapshot? = nil) {
        self.value = value ?? RouterQuotaSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            providers: [:]
        )
    }

    func update(_ value: RouterQuotaSnapshot) {
        lock.withLock { self.value = value }
    }

    func isAvailable() async -> Bool { true }

    func snapshot(
        forceRefresh: Bool,
        usageMaxAgeSeconds: TimeInterval
    ) async throws -> RouterQuotaSnapshot {
        lock.withLock { value }
    }

    func lastKnownSnapshot() async -> RouterQuotaSnapshot? { nil }
}

/// Minimal in-memory multi-account settings for the retention suite (the
/// sibling suite's fake is file-private).
private final class RetentionFakeSettings: MultiAccountSettingsRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var configuredAccounts: [ProviderAccountConfig] = []
    private var activeId: String?
    private var enabled = true

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
            if let index = configuredAccounts.firstIndex(where: { $0.accountId == config.accountId }) {
                configuredAccounts[index] = config
            } else {
                configuredAccounts.append(config)
            }
        }
    }
    func activeAccountId(forProvider id: String) -> String? { lock.withLock { activeId } }
    func setActiveAccountId(_ accountId: String?, forProvider id: String) {
        lock.withLock { activeId = accountId }
    }
}
