import Foundation
import Testing
@testable import Domain

@Suite("CodexMultiAccountProvider")
struct CodexMultiAccountProviderTests {

    private actor StaticProbe: CodexMultiAccountProbing {
        let byHome: [String: CodexAccountSnapshot]

        init(byHome: [String: CodexAccountSnapshot]) { self.byHome = byHome }

        func snapshot(label: String, codexHome: String) async -> CodexAccountSnapshot {
            byHome[codexHome] ?? CodexAccountSnapshot(
                label: label, codexHome: codexHome,
                email: nil, planType: nil,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                primaryQuota: nil, secondaryQuota: nil, hasGauges: false
            )
        }
    }

    @Test("Two CODEX_HOME → two snapshots, isolated by home")
    func twoHomesTwoSnapshots() async {
        let stamp1 = Date(timeIntervalSince1970: 1_700_000_000)
        let stamp2 = Date(timeIntervalSince1970: 1_700_000_100)
        let probe = StaticProbe(byHome: [
            "/home/u/.codex-a": CodexAccountSnapshot(
                label: "Personal", codexHome: "/home/u/.codex-a",
                email: "a@y.fr", planType: "pro",
                observedAt: stamp1,
                primaryQuota: CodexQuotaSummary(usedPercent: 30, resetsAtDescription: "Resets in 2h"),
                secondaryQuota: CodexQuotaSummary(usedPercent: 12, resetsAtDescription: "Resets Sun"),
                hasGauges: true
            ),
            "/home/u/.codex-b": CodexAccountSnapshot(
                label: "Work", codexHome: "/home/u/.codex-b",
                email: "b@y.fr", planType: "pro",
                observedAt: stamp2,
                primaryQuota: CodexQuotaSummary(usedPercent: 70, resetsAtDescription: "Resets in 4h"),
                secondaryQuota: nil,
                hasGauges: true
            ),
        ])
        let provider = CodexMultiAccountProvider(
            accounts: [
                CodexAccountConfig(label: "Personal", codexHome: "/home/u/.codex-a"),
                CodexAccountConfig(label: "Work", codexHome: "/home/u/.codex-b"),
            ],
            probe: probe
        )
        let snaps = await provider.snapshot()
        #expect(snaps.count == 2)
        #expect(snaps[0].codexHome == "/home/u/.codex-a")
        #expect(snaps[0].email == "a@y.fr")
        #expect(snaps[0].primaryQuota?.usedPercent == 30)
        #expect(snaps[1].codexHome == "/home/u/.codex-b")
        #expect(snaps[1].email == "b@y.fr")
        #expect(snaps[1].primaryQuota?.usedPercent == 70)
    }

    @Test("API-key plan ('metered_api') → hasGauges false")
    func apiKeyPlanNoGauges() async {
        let probe = StaticProbe(byHome: [
            "/home/u/.codex-api": CodexAccountSnapshot(
                label: "API", codexHome: "/home/u/.codex-api",
                email: "api@y.fr", planType: "metered_api",
                observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                primaryQuota: nil, secondaryQuota: nil,
                hasGauges: false
            ),
        ])
        let provider = CodexMultiAccountProvider(
            accounts: [
                CodexAccountConfig(label: "API", codexHome: "/home/u/.codex-api"),
            ],
            probe: probe
        )
        let snaps = await provider.snapshot()
        #expect(snaps.count == 1)
        #expect(snaps[0].planType == "metered_api")
        #expect(snaps[0].hasGauges == false)
        #expect(snaps[0].primaryQuota == nil)
    }

    @Test("ChatGPT plan → hasGauges true")
    func chatgptPlanHasGauges() async {
        let probe = StaticProbe(byHome: [
            "/home/u/.codex-c": CodexAccountSnapshot(
                label: "C", codexHome: "/home/u/.codex-c",
                email: "c@y.fr", planType: "plus",
                observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                primaryQuota: CodexQuotaSummary(usedPercent: 50),
                secondaryQuota: CodexQuotaSummary(usedPercent: 10),
                hasGauges: true
            ),
        ])
        let provider = CodexMultiAccountProvider(
            accounts: [
                CodexAccountConfig(label: "C", codexHome: "/home/u/.codex-c"),
            ],
            probe: probe
        )
        let snaps = await provider.snapshot()
        #expect(snaps[0].hasGauges == true)
        #expect(snaps[0].primaryQuota?.usedPercent == 50)
        #expect(snaps[0].secondaryQuota?.usedPercent == 10)
    }

    @Test("Empty roster → empty snapshot")
    func emptyRosterEmptySnapshot() async {
        let probe = StaticProbe(byHome: [:])
        let provider = CodexMultiAccountProvider(accounts: [], probe: probe)
        let snaps = await provider.snapshot()
        #expect(snaps.isEmpty)
    }

    @Test("Snapshots preserve input roster order (no shuffle)")
    func orderStable() async {
        let homes = [
            "/home/u/.codex-1",
            "/home/u/.codex-2",
            "/home/u/.codex-3",
            "/home/u/.codex-4",
        ]
        var byHome: [String: CodexAccountSnapshot] = [:]
        for (idx, h) in homes.enumerated() {
            let snap = CodexAccountSnapshot(
                label: "L\(idx)", codexHome: h,
                email: nil, planType: "pro",
                observedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + idx)),
                primaryQuota: nil, secondaryQuota: nil, hasGauges: true
            )
            byHome[h] = snap
        }
        let probe = StaticProbe(byHome: byHome)
        let provider = CodexMultiAccountProvider(
            accounts: homes.map { CodexAccountConfig(label: $0, codexHome: $0) },
            probe: probe
        )
        let snaps = await provider.snapshot()
        #expect(snaps.map { $0.codexHome } == homes)
    }
}
