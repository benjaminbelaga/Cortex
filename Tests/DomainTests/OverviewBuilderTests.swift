import Testing
import Foundation
@testable import Domain

/// Overview projection tests: row-per-account flattening, window filtering
/// (Session 5h / Semaine / Tout — R11), and both sort modes.
@Suite
@MainActor
struct OverviewBuilderTests {

    // MARK: - Stubs

    class StubProvider: AIProvider {
        let id: String
        let name: String
        var isEnabled = true
        var isSyncing = false
        var snapshot: UsageSnapshot?
        var lastError: Error?

        init(id: String, name: String, snapshot: UsageSnapshot?) {
            self.id = id
            self.name = name
            self.snapshot = snapshot
        }

        var cliCommand: String { id }
        var dashboardURL: URL? { nil }
        var statusPageURL: URL? { nil }
        var backgroundRefreshFloor: Duration? { nil }
        func isAvailable() async -> Bool { true }
        func refresh() async throws -> UsageSnapshot { snapshot ?? UsageSnapshot(providerId: id, quotas: [], capturedAt: Date()) }
    }

    final class StubMultiProvider: StubProvider, MultiAccountProvider {
        struct Account: ProviderAccountShim {
            let accountId: String
            let label: String
        }

        var shimAccounts: [Account] = []
        var shimSnapshots: [String: UsageSnapshot] = [:]
        var shimRefreshStates: [String: ProviderAccountRefreshState] = [:]

        var accounts: [ProviderAccount] {
            shimAccounts.map {
                ProviderAccount(accountId: $0.accountId, providerId: id, label: $0.label, email: nil, organization: nil)
            }
        }
        var activeAccount: ProviderAccount { accounts.first! }
        var accountSnapshots: [String: UsageSnapshot] { shimSnapshots }
        var accountRefreshStates: [String: ProviderAccountRefreshState] { shimRefreshStates }
        func switchAccount(to accountId: String) -> Bool { true }
        func refreshAccount(_ accountId: String) async throws -> UsageSnapshot { UsageSnapshot(providerId: id, quotas: [], capturedAt: Date()) }
        func refreshAllAccounts(_ kind: RefreshKind) async {}
    }

    /// Minimal protocol so the stub's account list stays value-typed.
    protocol ProviderAccountShim {
        var accountId: String { get }
        var label: String { get }
    }

    // MARK: - Fixtures

    static func quota(_ pct: Double, _ type: QuotaType, resetsIn: TimeInterval? = nil) -> UsageQuota {
        UsageQuota(
            percentRemaining: pct,
            quotaType: type,
            providerId: "stub",
            resetsAt: resetsIn.map { Date().addingTimeInterval($0) }
        )
    }

    static func snapshot(quotas: [UsageQuota]) -> UsageSnapshot {
        UsageSnapshot(providerId: "stub", quotas: quotas, capturedAt: Date())
    }

    // MARK: - Window scope classification

    @Test("window scope maps quota types to buckets")
    func windowScopeMapsQuotaTypesToBuckets() {
        #expect(WindowScope(quotaType: .session) == .session)
        #expect(WindowScope(quotaType: .weekly) == .weekly)
        #expect(WindowScope(quotaType: .modelSpecific("opus")) == .weekly)
    }

    @Test("filter matches scope")
    func filterMatchesScope() {
        #expect(OverviewWindowFilter.all.matches(.session))
        #expect(OverviewWindowFilter.all.matches(.weekly))
        #expect(OverviewWindowFilter.session.matches(.session))
        #expect(!OverviewWindowFilter.session.matches(.weekly))
        #expect(OverviewWindowFilter.weekly.matches(.weekly))
        #expect(!OverviewWindowFilter.weekly.matches(.session))
    }

    // MARK: - Build

    @Test("build emits one row per account for multi-account providers")
    func buildEmitsOneRowPerAccountForMultiAccountProviders() {
        let multi = StubMultiProvider(
            id: "claude",
            name: "Claude",
            snapshot: nil
        )
        multi.shimAccounts = [
            .init(accountId: "default", label: "Default"),
            .init(accountId: "admin", label: "Admin"),
        ]
        multi.shimSnapshots = [
            "default": Self.snapshot(quotas: [
                Self.quota(50, .session, resetsIn: 3600),
                Self.quota(20, .weekly, resetsIn: 200_000),
            ]),
            "admin": Self.snapshot(quotas: [
                Self.quota(80, .session, resetsIn: 3600),
            ]),
        ]

        let single = StubProvider(
            id: "codex",
            name: "Codex",
            snapshot: Self.snapshot(quotas: [Self.quota(10, .weekly, resetsIn: 100_000)])
        )

        let rows = OverviewBuilder.build(providers: [multi, single])

        #expect(rows.count == 3)
        #expect(rows.filter { $0.providerId == "claude" }.count == 2)
        #expect(rows.filter { $0.providerId == "codex" }.count == 1)
        let claudeRows = rows.filter { $0.providerId == "claude" }
        #expect(Set(claudeRows.compactMap(\.accountLabel)) == Set(["Default", "Admin"]))
    }

    @Test("build surfaces provider error as row message")
    func buildSurfacesProviderErrorAsRowMessage() {
        let failing = StubProvider(id: "kimi", name: "Kimi", snapshot: nil)
        failing.lastError = ProbeError.parseFailed("creds expired")

        let rows = OverviewBuilder.build(providers: [failing])
        #expect(rows.count == 1)
        #expect(rows[0].errorMessage != nil)
        #expect(rows[0].windows.isEmpty)
    }

    @Test("multi-account idle row is not a perpetual spinner")
    func multiAccountIdleRowIsNotAPerpetualSpinner() {
        let multi = StubMultiProvider(id: "claude", name: "Claude", snapshot: nil)
        multi.shimAccounts = [.init(accountId: "admin", label: "Admin")]
        multi.shimRefreshStates = ["admin": .idle]

        let row = OverviewBuilder.build(providers: [multi])[0]

        #expect(row.isSyncing == false)
        #expect(row.errorMessage == nil)
        #expect(row.windows.isEmpty)
    }

    @Test("multi-account failed row retains cached windows and exposes error")
    func multiAccountFailedRowRetainsCachedWindowsAndExposesError() {
        let multi = StubMultiProvider(id: "claude", name: "Claude", snapshot: nil)
        multi.shimAccounts = [.init(accountId: "personal", label: "Personal")]
        multi.shimSnapshots = ["personal": Self.snapshot(quotas: [Self.quota(42, .weekly)])]
        multi.shimRefreshStates = ["personal": .failed(message: "credentials expired")]

        let row = OverviewBuilder.build(providers: [multi])[0]

        #expect(row.windows.first?.percentRemaining == 42)
        #expect(row.errorMessage == "credentials expired")
        #expect(row.isSyncing == false)
    }

    // MARK: - Worst window + status per filter

    @Test("worst window honors the filter")
    func worstWindowHonorsTheFilter() {
        let provider = StubProvider(id: "x", name: "X", snapshot: Self.snapshot(quotas: [
            Self.quota(70, .session, resetsIn: 3600),
            Self.quota(5, .weekly, resetsIn: 500_000),
        ]))
        let rows = OverviewBuilder.build(providers: [provider])

        #expect(rows[0].worstWindow(matching: .session)?.percentRemaining == 70)
        #expect(rows[0].worstWindow(matching: .weekly)?.percentRemaining == 5)
        #expect(rows[0].worstWindow(matching: .all)?.percentRemaining == 5)
        #expect(rows[0].status(matching: .session) != .critical)
        #expect(rows[0].status(matching: .weekly) == .critical || rows[0].status(matching: .weekly) == .warning)
    }

    // MARK: - Sorting

    @Test("sort by percent remaining puts worst first and sinks no-match rows")
    func sortByPercentRemainingPutsWorstFirstAndSinksNoMatchRows() {
        let a = ProviderSnapshot(id: "a", providerId: "a", providerName: "A", accountLabel: nil, windows: [
            WindowSnapshot(id: "a1", title: "5h", percentRemaining: 80, resetsAt: nil, compactReset: "1h", scope: .session),
            WindowSnapshot(id: "a2", title: "7d", percentRemaining: 30, resetsAt: nil, compactReset: "3d", scope: .weekly),
        ])
        let b = ProviderSnapshot(id: "b", providerId: "b", providerName: "B", accountLabel: nil, windows: [
            WindowSnapshot(id: "b1", title: "5h", percentRemaining: 10, resetsAt: nil, compactReset: "2h", scope: .session),
        ])
        let noSession = ProviderSnapshot(id: "c", providerId: "c", providerName: "C", accountLabel: nil, windows: [
            WindowSnapshot(id: "c1", title: "7d", percentRemaining: 1, resetsAt: nil, compactReset: "6d", scope: .weekly),
        ])

        // Session filter: b (10%) first, a (80%) second, c sinks (no session window)
        let sessionSorted = OverviewBuilder.sort([a, b, noSession], by: .percentRemaining, filter: .session)
        #expect(sessionSorted.map(\.id) == ["b", "a", "c"])

        // All filter: c (1%) first, b (10%), a (30%)
        let allSorted = OverviewBuilder.sort([a, b, noSession], by: .percentRemaining, filter: .all)
        #expect(allSorted.map(\.id) == ["c", "b", "a"])
    }

    @Test("sort keeps accounts of one provider adjacent while groups stay severity-ordered")
    func sortKeepsAccountsOfOneProviderAdjacent() {
        func row(_ id: String, _ providerId: String, percent: Double) -> ProviderSnapshot {
            ProviderSnapshot(id: id, providerId: providerId, providerName: providerId, accountLabel: nil, windows: [
                WindowSnapshot(id: "\(id)-5h", title: "5h", percentRemaining: percent, resetsAt: nil, compactReset: "1h", scope: .session),
            ])
        }
        let input = [
            row("opencode-go|compte-1", "opencode-go", percent: 65),
            row("kimi", "kimi", percent: 100),
            row("opencode-go|compte-2", "opencode-go", percent: 30),
            row("codex", "codex", percent: 63),
        ]

        let sorted = OverviewBuilder.sort(input, by: .percentRemaining, filter: .session)

        #expect(sorted.map(\.id) == ["opencode-go|compte-1", "opencode-go|compte-2", "codex", "kimi"])
    }

    @Test("sort by time to reset is soonest first with unknowns last")
    func sortByTimeToResetIsSoonestFirstWithUnknownsLast() {
        let soon = ProviderSnapshot(id: "soon", providerId: "soon", providerName: "S", accountLabel: nil, windows: [
            WindowSnapshot(id: "s1", title: "5h", percentRemaining: 50, resetsAt: Date().addingTimeInterval(3600), compactReset: "1h", scope: .session),
        ])
        let later = ProviderSnapshot(id: "later", providerId: "later", providerName: "L", accountLabel: nil, windows: [
            WindowSnapshot(id: "l1", title: "5h", percentRemaining: 50, resetsAt: Date().addingTimeInterval(200_000), compactReset: "2d", scope: .session),
        ])
        let unknown = ProviderSnapshot(id: "unknown", providerId: "unknown", providerName: "U", accountLabel: nil, windows: [
            WindowSnapshot(id: "u1", title: "5h", percentRemaining: 50, resetsAt: nil, compactReset: nil, scope: .session),
        ])

        let sorted = OverviewBuilder.sort([later, unknown, soon], by: .timeToReset, filter: .session)
        #expect(sorted.map(\.id) == ["soon", "later", "unknown"])
    }
}
