import Testing
import Foundation
@testable import Domain

/// Collapsible provider groups (Ben 2026-09-23) + binding-window usability (bible R36).
@Suite
struct ProviderGroupTests {
    private func window(_ title: String, _ pct: Double, _ scope: WindowScope) -> WindowSnapshot {
        WindowSnapshot(id: title, title: title, percentRemaining: pct, resetsAt: nil, compactReset: nil, scope: scope)
    }

    private func row(_ provider: String, _ account: String, session: Double?, weekly: Double?,
                     auth: AccountAuthState = .unknown, error: String? = nil) -> ProviderSnapshot {
        var windows: [WindowSnapshot] = []
        if let session { windows.append(window("5h", session, .session)) }
        if let weekly { windows.append(window("7d", weekly, .weekly)) }
        return ProviderSnapshot(id: "\(provider)|\(account)", providerId: provider, providerName: provider,
            accountLabel: account, windows: windows, errorMessage: error, authState: auth)
    }

    @Test func `groups keep sort order; members sort by usability then headroom`() {
        // Task 3 (v7.2): inside a group, usable accounts float up, then by
        // binding-window headroom descending — so cc|b (90 %) leads cc|a (50 %),
        // reversing the raw builder account order.
        let rows = [row("cc", "a", session: 50, weekly: 50), row("cc", "b", session: 90, weekly: 90),
                    row("kimi", "x", session: 80, weekly: 80)]
        let groups = OverviewBuilder.groups(rows)
        #expect(groups.map(\.providerId) == ["cc", "kimi"])
        #expect(groups[0].rows.map(\.id) == ["cc|b", "cc|a"])
        #expect(groups[0].isMultiAccount)
        #expect(!groups[1].isMultiAccount)
    }

    @Test func `exhausted week makes a full session unusable`() {
        let blocked = row("cc", "a", session: 100, weekly: 0)
        #expect(blocked.bindingRemaining == 0)
        #expect(!blocked.isUsableNow)
    }

    @Test func `representative is the most usable account, not the first`() {
        let rows = [row("oc", "1", session: 100, weekly: 0),
                    row("oc", "2", session: 40, weekly: 60),
                    row("oc", "3", session: 70, weekly: 80)]
        let group = OverviewBuilder.groups(rows)[0]
        #expect(group.representative.id == "oc|3")
        #expect(group.usableCount == 2)
    }

    @Test func `reconnect accounts are counted and never representative when another works`() {
        let rows = [row("claude", "web", session: nil, weekly: nil, auth: .reconnectRequired, error: "relogin"),
                    row("claude", "tech", session: 70, weekly: 20)]
        let group = OverviewBuilder.groups(rows)[0]
        #expect(group.reconnectCount == 1)
        #expect(group.usableCount == 1)
        #expect(group.representative.id == "claude|tech")
    }
}

@Suite
struct ModelFamilyTests {
    @Test func `model ids map to their family`() {
        #expect(ModelFamily(modelId: "deepseek-v4-pro") == .deepseek)
        #expect(ModelFamily(modelId: "qwen3.8-max") == .qwen)
        #expect(ModelFamily(modelId: "GLM-5.3") == .glm)
        #expect(ModelFamily(modelId: "mystery-1") == nil)
    }

    @Test func `stored ids keep catalog order and drop unknowns`() {
        #expect(ModelFamily.families(from: ["qwen", "bogus", "deepseek"]) == [.deepseek, .qwen])
    }
}
