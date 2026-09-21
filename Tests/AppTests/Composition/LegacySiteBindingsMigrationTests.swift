import Testing
import Foundation
import Domain
import Infrastructure
@testable import ClaudeBar

/// Pins the E1 site-specific row bindings: the `local` router id and extra
/// tmux sockets are remembered from detected capability, never hardcoded.
/// Fresh installs (nothing detected) keep both absent — no fabricated rows,
/// default socket only.
@MainActor
@Suite("Legacy site bindings migration")
struct LegacySiteBindingsMigrationTests {

    private func makeRepository() -> (JSONSettingsRepository, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-bindings-\(UUID().uuidString)")
        let store = JSONSettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        return (JSONSettingsRepository(store: store), dir)
    }

    private func snapshotCache(containing ids: [String]) -> (URL, (String) -> Data?) {
        let idsJSON = ids.map { "\"\($0)\": {}" }.joined(separator: ", ")
        let text = "{\"providers\": {\(idsJSON)}}"
        let data = Data(text.utf8)
        return (URL(fileURLWithPath: "/tmp/snapshot.json"), { _ in data })
    }

    @Test("detects the legacy local id in the snapshot cache")
    func detectsLocalRouterId() {
        let (url, read) = snapshotCache(containing: ["claude", "local_legacy"])
        #expect(
            LegacyInstallMigration.detectLocalRouterId(snapshotCacheURL: url, readFile: read)
                == "local_legacy"
        )
    }

    @Test("no detection without the id, or without a cache")
    func noDetectionWithoutIdOrCache() {
        let (url, read) = snapshotCache(containing: ["claude", "codex"])
        #expect(
            LegacyInstallMigration.detectLocalRouterId(snapshotCacheURL: url, readFile: read)
                == nil
        )
        #expect(
            LegacyInstallMigration.detectLocalRouterId(
                snapshotCacheURL: URL(fileURLWithPath: "/tmp/missing.json"),
                readFile: { _ in nil }
            ) == nil
        )
    }

    @Test("seeds the local id once, never overwrites an explicit value")
    func seedsLocalIdOnce() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, read) = snapshotCache(containing: ["local_legacy"])

        LegacyInstallMigration.seedLocalRouterIdIfNeeded(
            settingsRepository: repo, snapshotCacheURL: url, readFile: read
        )
        #expect(repo.localRouterProviderId() == "local_legacy")

        // Explicit user value wins over any later detection.
        repo.setLocalRouterProviderId("local_custom")
        let (url2, read2) = snapshotCache(containing: ["local_legacy"])
        LegacyInstallMigration.seedLocalRouterIdIfNeeded(
            settingsRepository: repo, snapshotCacheURL: url2, readFile: read2
        )
        #expect(repo.localRouterProviderId() == "local_custom")
    }

    @Test("seeds responding tmux sockets once, leaves fresh installs alone")
    func seedsTmuxSocketsOnce() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        LegacyInstallMigration.seedTmuxSocketsIfNeeded(
            settingsRepository: repo,
            candidates: ["yoyaku", "nope"],
            socketResponds: { $0 == "yoyaku" }
        )
        #expect(repo.tmuxSocketNames() == ["yoyaku"])

        // Second run is a no-op (key present).
        LegacyInstallMigration.seedTmuxSocketsIfNeeded(
            settingsRepository: repo,
            candidates: ["yoyaku", "nope"],
            socketResponds: { _ in true }
        )
        #expect(repo.tmuxSocketNames() == ["yoyaku"])
    }

    @Test("no socket detected means nothing written")
    func noSocketDetectedWritesNothing() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        LegacyInstallMigration.seedTmuxSocketsIfNeeded(
            settingsRepository: repo,
            candidates: ["yoyaku"],
            socketResponds: { _ in false }
        )
        #expect(repo.tmuxSocketNames().isEmpty)
    }
}
