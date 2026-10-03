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

    /// A temp `cortex-accounts.json` path in its own UUID directory, following
    /// `makeRepository()`'s isolation convention. Never touches real state.
    private func makeExportURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cortex-accounts.json")
    }

    /// Decodes only the exported `generation`, mirroring the producer's own
    /// best-effort reader.
    private struct GenerationField: Decodable {
        let generation: Int?
    }

    /// The export writes on a detached task, so poll until the file has been
    /// written and carries at least `minimum` — this never mistakes a
    /// pre-existing generation (e.g. a seeded `37`) for the new result.
    private func waitForGeneration(
        at url: URL,
        atLeast minimum: Int,
        timeout: TimeInterval = 5
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let field = try? JSONDecoder().decode(GenerationField.self, from: data),
               let generation = field.generation,
               generation >= minimum {
                return generation
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return nil
    }

    /// An exporter wired to a temp URL with no settings or network access.
    private func makeExporter(outputURL: URL) -> CortexAccountsExporter {
        CortexAccountsExporter(
            outputURL: outputURL,
            preferredModelsProvider: { [:] },
            clock: { Date(timeIntervalSince1970: 0) },
            catalogIdsProvider: { [:] }
        )
    }

    @Test("the disk seed reads 37, and 0 for an absent or malformed file, never throwing")
    func diskSeedReadsGeneration() throws {
        let url = try makeExportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Absent → 0.
        #expect(CortexAccountsExporter.lastPublishedGeneration(at: url) == 0)

        // A payload that only carries the generation still seeds it.
        try Data(#"{"generation": 37}"#.utf8).write(to: url)
        #expect(CortexAccountsExporter.lastPublishedGeneration(at: url) == 37)

        // Garbage bytes → 0, no throw.
        try Data([0x00, 0xFF, 0x7B, 0x13]).write(to: url)
        #expect(CortexAccountsExporter.lastPublishedGeneration(at: url) == 0)
    }

    @Test("a fresh exporter continues above the generation on disk (restart regression)")
    func freshExporterContinuesAboveDiskGeneration() async throws {
        let url = try makeExportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A previous process left generation 37 on disk.
        try Data(#"{"generation": 37}"#.utf8).write(to: url)

        let exporter = makeExporter(outputURL: url)
        exporter.exportAfterRefresh(providers: [])

        // 38, NOT 1 — the counter must not restart.
        #expect(await waitForGeneration(at: url, atLeast: 38) == 38)
    }

    @Test("an absent file starts the sequence at 1")
    func absentFileStartsAtOne() async throws {
        let url = try makeExportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let exporter = makeExporter(outputURL: url)
        exporter.exportAfterRefresh(providers: [])

        #expect(await waitForGeneration(at: url, atLeast: 1) == 1)
    }

    @Test("a malformed file starts at 1 and never throws")
    func malformedFileStartsAtOne() async throws {
        let url = try makeExportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data([0x00, 0xFF, 0x7B, 0x13]).write(to: url)

        let exporter = makeExporter(outputURL: url)
        exporter.exportAfterRefresh(providers: [])

        #expect(await waitForGeneration(at: url, atLeast: 1) == 1)
    }

    @Test("a second exporter over the same file continues strictly above the first")
    func secondExporterContinuesAboveFirst() async throws {
        let url = try makeExportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = makeExporter(outputURL: url)
        first.exportAfterRefresh(providers: [])
        let firstGeneration = await waitForGeneration(at: url, atLeast: 1)

        let second = makeExporter(outputURL: url)
        second.exportAfterRefresh(providers: [])
        let secondGeneration = await waitForGeneration(at: url, atLeast: 2)

        #expect(firstGeneration == 1)
        #expect(secondGeneration == 2)
        #expect((secondGeneration ?? 0) > (firstGeneration ?? 0))
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
