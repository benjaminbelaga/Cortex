import Testing
import Foundation
import Domain
import Infrastructure
@testable import Cortex

/// Pins `RouterSourceModeMigration`: une machine avec registre llm-router garde
/// la lecture partagée ; une machine vierge part en sondes natives et ne suit
/// pas d'office les lignes strictement routeur — sans jamais écraser un choix
/// utilisateur.
@MainActor
@Suite("Router source-mode migration")
struct RouterSourceModeMigrationTests {

    private func makeRepository() -> (JSONSettingsRepository, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-mode-\(UUID().uuidString)")
        let store = JSONSettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        return (JSONSettingsRepository(store: store), dir)
    }

    @Test("Registry detection reads the real accounts marker")
    func registryDetection() {
        let registryWithAccounts = "schema_version: 2\naccounts:\n  - account_id: claude-work\n"
        let emptyRegistry = "schema_version: 2\naccounts: []\n"

        #expect(RouterSourceModeMigration.routerRegistryPresent(
            registryPath: "/tmp/whatever.yaml",
            fileExists: { _ in true },
            readFile: { _ in registryWithAccounts }
        ))
        #expect(RouterSourceModeMigration.routerRegistryPresent(
            registryPath: "/tmp/whatever.yaml",
            fileExists: { _ in true },
            readFile: { _ in emptyRegistry }
        ))
        #expect(!RouterSourceModeMigration.routerRegistryPresent(
            registryPath: "/tmp/missing.yaml",
            fileExists: { _ in false },
            readFile: { _ in nil }
        ))
    }

    @Test("Default source mode follows the registry presence")
    func defaultSourceModeFollowsRegistry() {
        #expect(RouterSourceModeMigration.defaultSourceMode(
            fileExists: { _ in true },
            readFile: { _ in "accounts:\n  - account_id: x\n" }
        ) == .router)
        #expect(RouterSourceModeMigration.defaultSourceMode(
            fileExists: { _ in false },
            readFile: { _ in nil }
        ) == .autonomous)
    }

    @Test("Fresh install leaves router-only rows unfollowed")
    func freshInstallUnfollowsRouterOnly() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        RouterSourceModeMigration.applyFreshInstallDefaultsIfNeeded(
            settingsRepository: repo,
            registryPresent: false
        )

        for id in ProviderCatalog.routerOnlyIDs {
            #expect(repo.isEnabled(forProvider: id, defaultValue: true) == false,
                    "\(id) must not be followed on a fresh install")
        }
        // Une ligne bi-mode garde son défaut : le mode autonome suffit.
        #expect(repo.isEnabled(forProvider: "claude", defaultValue: true) == true)
    }

    @Test("An explicit user choice is never overwritten")
    func explicitChoicePreserved() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        repo.setEnabled(true, forProvider: "kimi")   // choix explicite
        RouterSourceModeMigration.applyFreshInstallDefaultsIfNeeded(
            settingsRepository: repo,
            registryPresent: false
        )

        #expect(repo.isEnabled(forProvider: "kimi", defaultValue: false) == true)
    }

    @Test("Router installs are left untouched")
    func routerInstallUntouched() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        RouterSourceModeMigration.applyFreshInstallDefaultsIfNeeded(
            settingsRepository: repo,
            registryPresent: true
        )

        // Aucune clé écrite : les défauts d'origine s'appliquent toujours.
        let absent = repo.isEnabled(forProvider: "kimi", defaultValue: true)
            != repo.isEnabled(forProvider: "kimi", defaultValue: false)
        #expect(absent, "a router install must not have its roster rewritten")
    }
}
