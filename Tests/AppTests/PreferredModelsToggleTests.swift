import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

/// The preferred-model toggle (icon popover + context menu) → settings path
/// (v7.2, task 4/11). The popover calls the same `PreferredModelsToggle` and
/// writes the row's list back to settings.
@Suite("Preferred models toggle → settings")
struct PreferredModelsToggleTests {

    @Test("toggling adds, then removes, then clears the row list")
    func togglesAddRemove() {
        var list = PreferredModelsToggle.toggled(.deepseek, in: nil)
        #expect(list == ["deepseek"])
        list = PreferredModelsToggle.toggled(.glm, in: list)
        #expect(list == ["deepseek", "glm"])
        list = PreferredModelsToggle.toggled(.deepseek, in: list)
        #expect(list == ["glm"])
        list = PreferredModelsToggle.toggled(.glm, in: list)
        #expect(list == nil, "emptying the list clears the settings key")
    }

    @Test("a toggled list round-trips through the settings repository per row id")
    func reachesSettings() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = JSONSettingsRepository(store: JSONSettingsStore(fileURL: dir.appendingPathComponent("settings.json")))

        let rowId = "claude|WORK"
        var map = repo.preferredModels()
        map[rowId] = PreferredModelsToggle.toggled(.kimi, in: map[rowId])
        repo.setPreferredModels(map)

        #expect(repo.preferredModels()[rowId] == ["kimi"])
        #expect(ModelFamily.families(from: repo.preferredModels()[rowId] ?? []) == [.kimi])
    }

    @Test("catalog provider families map to Cortex families (router-driven, v7.4b)")
    func catalogFamilyMapping() {
        #expect(ModelFamily(catalogFamily: "zai") == .glm)
        #expect(ModelFamily(catalogFamily: "moonshot") == .kimi)
        #expect(ModelFamily(catalogFamily: "alibaba_qwen") == .qwen)
        #expect(ModelFamily(catalogFamily: "anthropic") == .claude)
        #expect(ModelFamily(catalogFamily: "openai") == .gpt)
        #expect(ModelFamily(catalogFamily: "opencode") == nil, "no Cortex logo → dropped")
        #expect(ModelFamily(catalogFamily: "local") == nil)
    }

    @Test("offered families come from the catalog, deduped and ordered; empty falls back")
    func offeredFamilies() {
        #expect(ModelFamily.offered(catalogFamilies: ["zai", "moonshot", "opencode"]) == [.glm, .kimi])
        #expect(ModelFamily.offered(catalogFamilies: ["anthropic", "openai"]) == [.claude, .gpt])
        #expect(ModelFamily.offered(catalogFamilies: []) == ModelFamily.allCases, "no router data → static set")
        #expect(ModelFamily.offered(catalogFamilies: ["opencode", "local"]) == ModelFamily.allCases,
                "no mapabble family → static set, never an empty picker")
    }
}
