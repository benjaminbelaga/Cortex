import Testing
import Foundation
import Domain
import Infrastructure
@testable import Cortex

/// C4 invariant (review critique 2026-09-16): every catalog descriptor must
/// lead to exactly ONE composition decision — instantiated router provider,
/// instantiated-after-gate optional, or explicitly unknown (test failure).
/// A provider must never disappear silently because someone added a
/// `ProviderDescriptor` without a mapping. This suite is the mechanical
/// backstop for the kimi/qwen/glm/minimax regression that shipped undetected
/// between B3-Startup and B3-final.
@Suite("ProviderComposition exhaustive catalog mapping")
@MainActor
struct ProviderCompositionExhaustiveTests {

    private func makeRepository() -> (JSONSettingsRepository, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cortex-composition-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = JSONSettingsStore(
            fileURL: tempDir.appendingPathComponent("settings.json")
        )
        return (JSONSettingsRepository(store: store), tempDir)
    }

    @Test("Catalog ids and composition known ids are exactly equal — no unmapped descriptor, no dead mapping")
    func catalogIsExhaustivelyMapped() {
        let catalogIDs = Set(ProviderCatalog.all.map(\.id))
        #expect(catalogIDs == ProviderComposition.knownCatalogIDs,
                """
                Catalog/composition drift: catalog-only = \
                \(catalogIDs.subtracting(ProviderComposition.knownCatalogIDs).sorted()), \
                mapping-only = \
                \(ProviderComposition.knownCatalogIDs.subtracting(catalogIDs).sorted()). \
                Add the mapping or remove the descriptor — never let a provider vanish.
                """)
    }

    @Test("Every non-optional catalog id instantiates exactly one provider")
    func nonOptionalIdsInstantiateOnce() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let composition = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo
        )
        let providers = composition.compose()
        let ids = Dictionary(grouping: providers.map(\.id), by: { $0 })
        for descriptor in ProviderCatalog.all where !descriptor.isOptional {
            #expect(ids[descriptor.id]?.count == 1,
                    "non-optional \(descriptor.id) must yield exactly 1 provider, got \(ids[descriptor.id]?.count ?? 0)")
        }
    }

    @Test("Optional ids instantiate when enabled, and never duplicate")
    func optionalIdsGateAndNeverDuplicate() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        for id in ["bedrock", "local"] {
            repo.setEnabled(true, forProvider: id)
        }
        // The local row needs a configured router id (fixture value here;
        // production seeds the real one from the detected snapshot).
        repo.setLocalRouterProviderId("local_test")
        let composition = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo
        )
        let providers = composition.compose()
        let ids = Dictionary(grouping: providers.map(\.id), by: { $0 })
        for id in ["bedrock", "local"] {
            #expect(ids[id]?.count == 1,
                    "enabled optional \(id) must yield exactly 1 provider, got \(ids[id]?.count ?? 0)")
        }
    }

    @Test("compose() returns each provider id at most once — no router/native double-instantiation")
    func noProviderIdDuplicates() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let composition = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo
        )
        let providers = composition.compose()
        let allIDs = providers.map(\.id)
        #expect(Set(allIDs).count == allIDs.count,
                "duplicate provider ids in composition output: \(allIDs)")
    }

    @Test("Every catalog id instantiates exactly one provider once followed")
    func everyCatalogIdInstantiatesWhenFollowed() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        for descriptor in ProviderCatalog.all where descriptor.isOptional {
            repo.setEnabled(true, forProvider: descriptor.id)
        }
        repo.setLocalRouterProviderId("local_test")
        let composition = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo
        )
        let providers = composition.compose()
        let ids = Dictionary(grouping: providers.map(\.id), by: { $0 })
        for descriptor in ProviderCatalog.all {
            #expect(ids[descriptor.id]?.count == 1,
                    "followed \(descriptor.id) must yield exactly 1 provider, got \(ids[descriptor.id]?.count ?? 0)")
        }
        #expect(Set(providers.map(\.id)) == Set(ProviderCatalog.all.map(\.id)),
                "composition must cover the whole catalog when everything is followed")
    }

    @Test("makeProvider(id:) instantiates any catalog id on demand — the + activation path")
    func makeProviderCoversEveryCatalogId() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        repo.setLocalRouterProviderId("local_test")
        let composition = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo
        )
        for descriptor in ProviderCatalog.all {
            let provider = composition.makeProvider(id: descriptor.id)
            #expect(provider?.id == descriptor.id,
                    "makeProvider(\(descriptor.id)) must return that provider (got \(provider?.id ?? "nil"))")
        }
        #expect(composition.makeProvider(id: "not-a-provider") == nil)
    }

    @Test("A disabled non-optional provider is skipped — removal sticks across recomposition")
    func disabledNonOptionalProviderIsSkipped() {
        // Regression (Ben 2026-09-26): "Remove from Cortex" persists
        // `providers.<id>.isEnabled = false`, but composition used to honour
        // that flag only for optional connectors — so a removed first-class
        // provider came back on the next recomposition ("je me retrouve avec ça
        // beaucoup plus tard").
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProviderCatalog.claude.isOptional == false)
        repo.setEnabled(false, forProvider: "claude")
        let composition = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo
        )
        let ids = composition.compose().map(\.id)
        #expect(!ids.contains("claude"),
                "a disabled provider must not be recomposed, got \(ids)")
    }

    @Test("Descriptor runtime and supported modes cannot contradict each other")
    func descriptorRuntimeAndModesAreCoherent() {
        for descriptor in ProviderCatalog.all {
            switch descriptor.runtime {
            case .router:
                #expect(descriptor.supportedModes == [.router],
                        "\(descriptor.id): a router-only runtime must declare exactly [.router]")
            case .native:
                #expect(descriptor.supportedModes.contains(.autonomous),
                        "\(descriptor.id): a native runtime must support .autonomous")
            case .routerOrNative:
                #expect(descriptor.supportedModes == [.autonomous, .router],
                        "\(descriptor.id): a dual runtime must support both modes")
            }
        }
    }

    @Test("Capabilities are declared exactly once per dimension and stay coherent")
    func capabilitiesAreCoherent() {
        for descriptor in ProviderCatalog.all {
            if descriptor.capabilities.contains(.discovery) {
                #expect(descriptor.capabilities.contains(.accounts),
                        "\(descriptor.id): discovery without accounts makes no sense")
            }
            #expect(!descriptor.capabilities.isEmpty,
                    "\(descriptor.id): a provider with no declared capability should not be in the catalog")
        }
        // The two dimensions Settings surfaces separately must exist somewhere.
        #expect(ProviderCatalog.all.contains { $0.capabilities.contains(.sessions) })
        #expect(ProviderCatalog.all.contains { $0.capabilities.contains(.reconnect) })
    }

    /// Minimal inert snapshot source — composition only stores it, never calls
    /// it during `compose()`.
    private struct StubSnapshotClient: RouterQuotaSnapshotProviding {
        func isAvailable() async -> Bool { true }
        func snapshot(
            forceRefresh: Bool,
            usageMaxAgeSeconds: TimeInterval
        ) async throws -> RouterQuotaSnapshot {
            RouterQuotaSnapshot(generatedAt: Date(), providers: [:])
        }
        func lastKnownSnapshot() async -> RouterQuotaSnapshot? { nil }
    }

    @Test("Autonomous default builds native claude/codex rows; explicit router builds router-backed rows")
    func sourceModeRoutesClaudeCodex() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        let autonomous = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo,
            defaultSourceMode: .autonomous
        )
        let nativeRows = Dictionary(
            grouping: autonomous.compose().map { $0 }, by: \.id
        )
        #expect(nativeRows["claude"]?.first is ClaudeProvider,
                "autonomous claude must be a native ClaudeProvider")
        #expect(nativeRows["codex"]?.first is CodexProvider,
                "autonomous codex must be a native CodexProvider")

        let routered = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo,
            defaultSourceMode: .router
        )
        let routerRows = Dictionary(
            grouping: routered.compose().map { $0 }, by: \.id
        )
        #expect(routerRows["claude"]?.first is RouterBackedProvider,
                "router claude must stay RouterBackedProvider")
        #expect(routerRows["codex"]?.first is RouterBackedProvider,
                "router codex must stay RouterBackedProvider")
    }

    @Test("Local row is skipped without a configured router id — never a fabricated id")
    func localSkippedWithoutConfiguredRouterId() {
        let (repo, dir) = makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        repo.setEnabled(true, forProvider: "local")
        // No localRouterProviderId configured: the row must not exist,
        // even though the integration is enabled.
        let composition = ProviderComposition(
            routerSnapshotClient: StubSnapshotClient(),
            settingsRepository: repo
        )
        let ids = composition.compose().map(\.id)
        #expect(!ids.contains("local"),
                "local row without a configured router id would fabricate one")
        #expect(composition.makeProvider(id: "local") == nil)
    }
}
