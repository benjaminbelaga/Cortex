import Foundation
import Testing
@testable import Domain

/// Member ordering inside an expanded provider group (v7.2, task 3): usable
/// accounts first, then by binding-window headroom descending, ties keep the
/// builder's account order.
@Suite("ProviderGroup member sort")
struct ProviderGroupMemberSortTests {

    private func row(
        account: String,
        weeklyPct: Double,
        reconnect: Bool = false
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "claude|\(account)",
            providerId: "claude",
            providerName: "Claude",
            accountLabel: account,
            windows: [WindowSnapshot(
                id: "claude|\(account)|7d",
                title: "7d",
                percentRemaining: weeklyPct,
                resetsAt: nil,
                compactReset: nil,
                scope: .weekly
            )],
            authState: reconnect ? .reconnectRequired : .connected
        )
    }

    @Test("usable accounts float up, then by binding remaining descending")
    func sortsMembersByUsabilityThenHeadroom() {
        // Input order deliberately scrambled.
        let input = [
            row(account: "low", weeklyPct: 20),
            row(account: "dead", weeklyPct: 90, reconnect: true),
            row(account: "high", weeklyPct: 80),
        ]
        let groups = OverviewBuilder.groups(input)
        let group = try! #require(groups.first)

        #expect(group.rows.map(\.accountLabel) == ["high", "low", "dead"])
        // The representative is still the most usable account.
        #expect(group.representative.accountLabel == "high")
        #expect(group.usableCount == 2)
        #expect(group.reconnectCount == 1)
    }

    @Test("ties keep the builder's account order")
    func tiesKeepInputOrder() {
        let input = [
            row(account: "first", weeklyPct: 50),
            row(account: "second", weeklyPct: 50),
        ]
        let group = try! #require(OverviewBuilder.groups(input).first)
        #expect(group.rows.map(\.accountLabel) == ["first", "second"])
    }
}
