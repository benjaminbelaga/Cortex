import Testing
import Foundation
@testable import Domain

/// Honest aggregation for multi-account providers.
///
/// An EMPTY snapshot map is a MISSING measurement (fresh enable, first refresh
/// still running, or every account failing with no cached data). `aggregateStatus`
/// must then read `.unknown`, never a fabricated `.healthy` — which is what the
/// settings card's green "HEALTHY" badge used to show while the per-account dots
/// correctly showed nothing.
@Suite
@MainActor
struct MultiAccountSupportTests {

    /// Minimal multi-account provider. Only `accountSnapshots` matters for the
    /// default `aggregateStatus` implementation under test.
    final class StubMultiProvider: AIProvider, MultiAccountProvider {
        let id: String
        let name: String
        var isEnabled = true
        var isSyncing = false
        var snapshot: UsageSnapshot?
        var lastError: Error?

        var shimAccounts: [(id: String, label: String)] = []
        var shimSnapshots: [String: UsageSnapshot] = [:]

        init(id: String = "stub", name: String = "Stub", snapshot: UsageSnapshot? = nil) {
            self.id = id
            self.name = name
            self.snapshot = snapshot
        }

        var cliCommand: String { id }
        var dashboardURL: URL? { nil }
        func isAvailable() async -> Bool { true }
        func refresh() async throws -> UsageSnapshot {
            snapshot ?? UsageSnapshot(providerId: id, quotas: [], capturedAt: Date())
        }

        var accounts: [ProviderAccount] {
            shimAccounts.map {
                ProviderAccount(
                    accountId: $0.id, providerId: id, label: $0.label,
                    email: nil, organization: nil
                )
            }
        }
        var activeAccount: ProviderAccount { accounts.first! }
        var accountSnapshots: [String: UsageSnapshot] { shimSnapshots }
        var accountRefreshStates: [String: ProviderAccountRefreshState] { [:] }
        func switchAccount(to accountId: String) -> Bool { true }
        func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
            UsageSnapshot(providerId: id, quotas: [], capturedAt: Date())
        }
        func refreshAllAccounts(_ kind: RefreshKind) async {}
    }

    private static func snapshot(percentRemaining: Double) -> UsageSnapshot {
        UsageSnapshot(
            providerId: "stub",
            quotas: [
                UsageQuota(
                    percentRemaining: percentRemaining,
                    quotaType: .session,
                    providerId: "stub"
                ),
            ],
            capturedAt: Date()
        )
    }

    @Test
    func `empty account snapshots aggregate to unknown not healthy`() {
        let provider = StubMultiProvider()

        #expect(provider.accountSnapshots.isEmpty)
        #expect(provider.aggregateStatus == .unknown)
        #expect(provider.aggregateStatus != .healthy)
    }

    @Test
    func `aggregate status is the worst measured account`() {
        let provider = StubMultiProvider()
        provider.shimSnapshots = [
            "a": Self.snapshot(percentRemaining: 90), // healthy
            "b": Self.snapshot(percentRemaining: 10), // critical
        ]

        #expect(provider.aggregateStatus == .critical)
    }

    @Test
    func `an unmeasured account never masks a measured one`() {
        let provider = StubMultiProvider()
        provider.shimSnapshots = [
            "a": UsageSnapshot(providerId: "stub", quotas: [], capturedAt: Date()), // unknown
            "b": Self.snapshot(percentRemaining: 90),                               // healthy
        ]

        // `.unknown` is the least severe, so the measured reading still wins.
        #expect(provider.aggregateStatus == .healthy)
    }
}
