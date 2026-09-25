import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// Contract A export (v7.2). The load-bearing test proves the emitted JSON can
/// NOT carry a `probeConfig` value: it is built from the overview projection,
/// which never reads a credential reference.
@Suite("CortexAccountsExporter")
@MainActor
struct CortexAccountsExporterTests {

    /// A probe returning a fixed weekly window; the credential lives only in the
    /// account's `probeConfig` (settings), never in the snapshot.
    struct StubProbe: UsageProbe {
        func probe() async throws -> UsageSnapshot {
            UsageSnapshot(
                providerId: "opencode-go",
                quotas: [UsageQuota(percentRemaining: 96, quotaType: .weekly, providerId: "opencode-go")],
                capturedAt: Date(timeIntervalSince1970: 1_790_000_000)
            )
        }
        func isAvailable() async -> Bool { true }
    }

    private func makeRepository() -> (JSONSettingsRepository, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = JSONSettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        return (JSONSettingsRepository(store: store), dir)
    }

    @Test("the exported roster never contains any probeConfig secret value")
    func exportOmitsProbeConfigSecrets() async throws {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        repo.setEnabled(true, forProvider: "opencode-go")
        repo.addAccount(
            ProviderAccountConfig(
                accountId: "go1",
                label: "Ben",
                probeConfig: ["credentialKey": "SECRET-REF", "token": "sk-live-shouldnotleak"]
            ),
            forProvider: "opencode-go"
        )
        // A second account makes the per-account label surface in the rows.
        repo.addAccount(ProviderAccountConfig(accountId: "go2", label: "Tech"), forProvider: "opencode-go")

        let provider = AccountUsageProvider(
            id: "opencode-go", name: "OpenCode Go", cliCommand: "opencode",
            dashboardURL: nil, settings: repo, makeProbe: { _ in StubProbe() }
        )
        await provider.refreshAllAccounts(.interactive)

        let payload = CortexAccountsExporter.payload(
            rows: OverviewBuilder.build(providers: [provider]),
            preferredModels: ["opencode-go|go1": ["deepseek"]],
            now: Date()
        )
        let data = try CortexAccountsExporter.encode(payload)
        let json = String(decoding: data, as: UTF8.self)

        // The account IS exported (proves the pipeline ran) …
        #expect(json.contains("opencode_go"))
        #expect(json.contains("\"Ben\""))
        // … and no secret survived the projection.
        #expect(!json.contains("SECRET-REF"))
        #expect(!json.contains("sk-"))
        #expect(!json.contains("o1_"))
        #expect(!json.contains("credentialKey"))
    }

    @Test("payload maps windows, router_provider, and preferred families")
    func payloadMapsFields() async throws {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        repo.setEnabled(true, forProvider: "opencode-go")
        repo.addAccount(
            ProviderAccountConfig(accountId: "go1", label: "Ben"),
            forProvider: "opencode-go"
        )
        repo.addAccount(ProviderAccountConfig(accountId: "go2", label: "Tech"), forProvider: "opencode-go")
        let provider = AccountUsageProvider(
            id: "opencode-go", name: "OpenCode Go", cliCommand: "opencode",
            dashboardURL: nil, settings: repo, makeProbe: { _ in StubProbe() }
        )
        await provider.refreshAllAccounts(.interactive)

        let payload = CortexAccountsExporter.payload(
            rows: OverviewBuilder.build(providers: [provider]),
            preferredModels: ["opencode-go": ["glm", "kimi"]],
            now: Date()
        )

        let entry = try #require(payload.accounts.first { $0.accountId == "go1" })
        #expect(entry.routerProvider == "opencode_go")
        #expect(entry.cortexProvider == "opencode-go")
        #expect(entry.accountId == "go1")
        #expect(entry.label == "Ben")
        #expect(entry.status == "healthy")
        #expect(entry.preferredFamilies == ["glm", "kimi"])
        #expect(entry.windows.contains { $0.kind == "weekly" && $0.remainingPct == 96 })
    }

    @Test("Settings provider-level pin wins over the legacy per-row list (R35)")
    func settingsPinWins() async throws {
        let merged = CortexAccountsExporter.effectivePreferences(
            providerPreferred: ["opencode-go": "deepseek", "kimi": ""],
            legacy: ["opencode-go": ["glm", "kimi"], "opencode-go|go1": ["qwen"], "claude": ["claude"]]
        )
        #expect(merged["opencode-go"] == ["deepseek"])
        #expect(merged["claude"] == ["claude"])
        #expect(merged["kimi"] == nil, "an empty Settings value never masks or invents a pin")

        // Provider-level key beats the legacy row key in the exported entry.
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        repo.setEnabled(true, forProvider: "opencode-go")
        repo.addAccount(ProviderAccountConfig(accountId: "go1", label: "Ben"), forProvider: "opencode-go")
        let provider = AccountUsageProvider(
            id: "opencode-go", name: "OpenCode Go", cliCommand: "opencode",
            dashboardURL: nil, settings: repo, makeProbe: { _ in StubProbe() }
        )
        await provider.refreshAllAccounts(.interactive)
        let payload = CortexAccountsExporter.payload(
            rows: OverviewBuilder.build(providers: [provider]),
            preferredModels: merged.merging(["opencode-go|go1": ["qwen"]]) { a, _ in a },
            now: Date()
        )
        let entry = try #require(payload.accounts.first { $0.accountId == "go1" })
        #expect(entry.preferredFamilies == ["deepseek"])
    }

    @Test("providers absent from the router mapping are skipped")
    func skipsUnmappedProviders() async throws {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        repo.setEnabled(true, forProvider: "gemini")
        // "gemini" is not in the router mapping table → dropped.
        let rows = [ProviderSnapshot(
            id: "gemini", providerId: "gemini", providerName: "Gemini",
            accountLabel: nil, windows: []
        )]
        let payload = CortexAccountsExporter.payload(rows: rows, preferredModels: [:], now: Date())
        #expect(payload.accounts.isEmpty)
    }
}
