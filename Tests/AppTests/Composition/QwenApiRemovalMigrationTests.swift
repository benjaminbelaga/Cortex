import Testing
import Foundation
@testable import Cortex
@testable import Domain
@testable import Infrastructure

/// v7.2 removal of the `qwen-api` provider (dead router id `qwen_cloud_payg`).
@Suite("QwenApiRemovalMigration + catalog")
struct QwenApiRemovalMigrationTests {

    private func makeStore() -> (JSONSettingsStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (JSONSettingsStore(fileURL: dir.appendingPathComponent("settings.json")), dir)
    }

    @Test("migration deletes a residual providers.qwen-api subtree, idempotently")
    func deletesResidualKey() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.write(value: true, key: "providers.qwen-api.isEnabled")
        store.write(value: true, key: "providers.claude.isEnabled")

        #expect(QwenApiRemovalMigration.applyIfNeeded(store: store) == true)
        let providers = store.readAll()["providers"] as? [String: Any]
        #expect(providers?["qwen-api"] == nil)
        // A sibling provider is untouched.
        #expect(providers?["claude"] != nil)

        // Idempotent: a second run does nothing.
        #expect(QwenApiRemovalMigration.applyIfNeeded(store: store) == false)
    }

    @Test("clean install is a no-op")
    func cleanInstallNoOp() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(QwenApiRemovalMigration.applyIfNeeded(store: store) == false)
    }

    @Test("qwen-api is gone from the catalog and no descriptor references qwen_cloud_payg")
    func catalogHasNoQwenApi() {
        #expect(ProviderCatalog.descriptor(forId: "qwen-api") == nil)
        #expect(!ProviderCatalog.allIDs.contains("qwen-api"))
        for descriptor in ProviderCatalog.all {
            #expect(!"\(descriptor.runtime)".contains("qwen_cloud_payg"),
                    "\(descriptor.id) must not reference the dead router provider qwen_cloud_payg")
        }
    }
}
