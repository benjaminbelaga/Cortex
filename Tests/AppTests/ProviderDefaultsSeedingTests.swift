import Testing
import Foundation
@testable import ClaudeBar
@testable import Infrastructure

/// Pins `ClaudeBarApp.seedCuratedProviderDefaultsIfNeeded`: the optional
/// pay-as-you-go / credentialed connectors (Qwen API, AWS Bedrock, Local) are
/// disabled on a fresh install, an explicit stored preference (true or false) is
/// never clobbered, and a manual re-enable survives a simulated restart.
@MainActor
@Suite("Provider defaults seeding")
struct ProviderDefaultsSeedingTests {

    private func makeRepository() -> (JSONSettingsRepository, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString)")
        let store = JSONSettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        return (JSONSettingsRepository(store: store), dir)
    }

    private let optionalConnectors = ["qwen-api", "bedrock", "local"]

    @Test("Absent preference is seeded to disabled for optional connectors")
    func absentSeededDisabled() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        ClaudeBarApp.seedCuratedProviderDefaultsIfNeeded(settingsRepository: repo)

        for id in optionalConnectors {
            #expect(repo.isEnabled(forProvider: id, defaultValue: true) == false)
        }
        // A core router provider is never touched by the seed.
        #expect(repo.isEnabled(forProvider: "claude", defaultValue: true) == true)
    }

    @Test("An explicitly stored true is preserved, not overwritten")
    func explicitTruePreserved() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        repo.setEnabled(true, forProvider: "bedrock")
        ClaudeBarApp.seedCuratedProviderDefaultsIfNeeded(settingsRepository: repo)

        #expect(repo.isEnabled(forProvider: "bedrock", defaultValue: false) == true)
    }

    @Test("An explicitly stored false is preserved")
    func explicitFalsePreserved() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        repo.setEnabled(false, forProvider: "qwen-api")
        ClaudeBarApp.seedCuratedProviderDefaultsIfNeeded(settingsRepository: repo)

        #expect(repo.isEnabled(forProvider: "qwen-api", defaultValue: true) == false)
    }

    @Test("Manual re-enable after seeding survives a re-seed (restart)")
    func manualEnableSurvivesRestart() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        ClaudeBarApp.seedCuratedProviderDefaultsIfNeeded(settingsRepository: repo)
        repo.setEnabled(true, forProvider: "local") // user opts in via the catalog
        ClaudeBarApp.seedCuratedProviderDefaultsIfNeeded(settingsRepository: repo) // restart

        #expect(repo.isEnabled(forProvider: "local", defaultValue: false) == true)
    }

    @Test("Legacy non-roster probe providers are still disabled")
    func legacyProbeProvidersDisabled() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        ClaudeBarApp.seedCuratedProviderDefaultsIfNeeded(settingsRepository: repo)

        for id in ["omp", "kiro", "ampcode", "grok", "cursor", "mistral", "deepseek", "vercel-gateway"] {
            #expect(repo.isEnabled(forProvider: id, defaultValue: true) == false)
        }
    }

    @Test("First-class subscriptions are surfaced by default")
    func firstClassSubscriptionsSurfaced() {
        // 2026-09-20: opencode-go + commandcode are real subscriptions
        // (API probes), no longer legacy hidden rows.
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        ClaudeBarApp.seedCuratedProviderDefaultsIfNeeded(settingsRepository: repo)

        for id in ["opencode-go", "commandcode"] {
            #expect(repo.isEnabled(forProvider: id, defaultValue: true) == true)
        }
    }
}
