import Foundation
import Domain
import Infrastructure

/// **ProviderComposition** — SEUL endroit où les providers Cortex sont
/// instanciés et assemblés. La source est unique : le catalogue canonique
/// (`ProviderCatalog`). La composition ne connaît AUCUNE liste parallèle —
/// chaque descripteur porte son `runtime` (router, natif, ou résolu).
///
/// Deux responsabilités de couche : la composition construit les instances ;
/// l'état par provider (réglages, snapshot, comptes) appartient au store /
/// monitor. Ajouter un provider = un descripteur dans le catalogue + un
/// constructeur natif si nécessaire — `knownCatalogIDs` et le test
/// d'invariant `catalogIsExhaustivelyMapped` échouent sinon.
///
/// Marked `@MainActor` because every provider type it builds
/// (`RouterBackedProvider`, `GeminiProvider`, etc.) is `@MainActor`-isolated.
@MainActor
public struct ProviderComposition {

    private let routerSnapshotClient: any RouterQuotaSnapshotProviding
    private let settingsRepository: JSONSettingsRepository

    /// The settings file live-reload watchers observe. Nil under test, where a
    /// per-provider `DispatchSource` on rapidly created/destroyed fixtures adds
    /// no value and destabilises the shared App test host.
    private var watchedSettingsURL: URL? {
        CortexRuntime.isTesting ? nil : settingsRepository.settingsFileURL
    }
    private let routerAvailability: any LLMRouterAvailabilityChecking
    private let sourceModeResolver: QuotaSourceResolver
    private let defaultSourceMode: QuotaSourceMode

    public init(
        routerSnapshotClient: any RouterQuotaSnapshotProviding,
        settingsRepository: JSONSettingsRepository,
        routerAvailability: any LLMRouterAvailabilityChecking = LLMRouterAvailability(),
        sourceModeResolver: QuotaSourceResolver = QuotaSourceResolver(),
        defaultSourceMode: QuotaSourceMode = .autonomous
    ) {
        self.routerSnapshotClient = routerSnapshotClient
        self.settingsRepository = settingsRepository
        self.routerAvailability = routerAvailability
        self.sourceModeResolver = sourceModeResolver
        self.defaultSourceMode = defaultSourceMode
    }

    /// Assembles la liste des providers suivis. Fully synchronous and
    /// side-effect-free (C4-2) : configuration + catalogue → providers.
    ///
    /// Un descripteur optionnel n'est instancié que si son suivi est activé
    /// (`providers.<id>.isEnabled`) : aucune sonde payée au démarrage pour un
    /// module que l'utilisateur n'utilise pas. Les descripteurs non optionnels
    /// sont toujours instanciés — couper leur suivi arrête la collecte sans
    /// faire disparaître la ligne ni son dernier relevé.
    public func compose() -> [any AIProvider] {
        ProviderCatalog.all.compactMap { instantiateIfFollowed(descriptor: $0) }
    }

    /// Construit UN provider à la demande, sans le gate de suivi. C'est le
    /// point d'entrée de l'activation immédiate depuis le catalogue `+` : la
    /// composition a déjà tourné au lancement, donc activer un module doit
    /// l'instancier et l'ajouter au monitor sans redémarrer l'app.
    public func makeProvider(id: String) -> (any AIProvider)? {
        guard let descriptor = ProviderCatalog.descriptor(forId: id) else {
            AppLog.providers.error(
                "makeProvider: id « \(id) » inconnu du catalogue — provider NOT instantiated"
            )
            return nil
        }
        return instantiate(descriptor)
    }

    /// Explicit, app-lifecycle-owned warm-up for the router availability cache
    /// (60 s TTL). Fire-and-forget by design, but owned by the CALLER — the
    /// composition itself stays pure.
    public func warmRouterAvailability() {
        let now = Date()
        Task.detached(priority: .background) { [routerAvailability] in
            _ = await routerAvailability.checkAvailability(now: now)
        }
    }

    /// The exact set of catalog ids this composition knows how to instantiate.
    /// C4 invariant (critique 2026-09-16): `ProviderCatalog.all` ids MUST equal
    /// this set — tested by `catalogIsExhaustivelyMapped`, and every id must
    /// instantiate once when followed (`everyCatalogIdInstantiatesWhenFollowed`).
    /// A catalog entry with no mapping fails CI instead of silently vanishing.
    public static let knownCatalogIDs: Set<String> = [
        "claude", "codex", "kimi", "qwen", "glm", "minimax",
        "gemini", "antigravity", "copilot", "opencode-go", "commandcode", "ollama",
        "bedrock", "local", "ampcode", "kiro", "cursor",
        "deepseek", "vercel-gateway", "mistral", "omp", "grok",
    ]

    // MARK: - Suivi (gate)

    private func instantiateIfFollowed(descriptor: ProviderDescriptor) -> (any AIProvider)? {
        // Honour `providers.<id>.isEnabled == false` for ANY provider, not only
        // optional connectors. This is what makes "Remove from Cortex" stick:
        // the removal path persists the flag, and the next composition must skip
        // the row instead of resurrecting it (Ben 2026-09-26: "je me retrouve
        // avec ça beaucoup plus tard"). Default is `true`, so nothing changes
        // until a provider is explicitly disabled (seeded roster or user action).
        if !isEnabled(id: descriptor.id) {
            AppLog.providers.debug(
                "Skipping provider \(descriptor.id) — isEnabled is false"
            )
            return nil
        }
        return instantiate(descriptor)
    }

    private func isEnabled(id: String) -> Bool {
        settingsRepository.isEnabled(forProvider: id, defaultValue: true)
    }

    // MARK: - Instantiation (runtime)

    /// Décision unique par descripteur. `routerOrNative` consulte le
    /// `sourceMode` configuré (résolution pure, sans I/O) : une installation
    /// autonome sonde nativement, une installation routeur lit le snapshot
    /// partagé. Le mode effectif retombe sur `.autonomous` quand le routeur
    /// n'est pas disponible — la dégradation visible est portée par la ligne
    /// (cf. `QuotaSourceModeResolution`), pas par une exception de composition.
    private func instantiate(_ descriptor: ProviderDescriptor) -> (any AIProvider)? {
        switch descriptor.runtime {
        case let .router(backing):
            return makeRouterProvider(descriptor, backing: backing)
        case .native:
            return makeNativeProvider(descriptor)
        case let .routerOrNative(backing):
            if resolvedSourceMode(for: descriptor) == .router {
                return makeRouterProvider(descriptor, backing: backing)
            }
            return makeNativeProvider(descriptor)
        }
    }

    /// Constructeur des lignes servies par le snapshot llm-router. Toutes les
    /// métadonnées d'affichage viennent du descripteur — jamais de dérive.
    /// Exception : l'id `local` lit son router id depuis les réglages
    /// (`providers.local.routerProviderId`) ; nil = pas de ligne (aucun id
    /// fabriqué — la migration écrit la valeur détectée sur les machines
    /// qui la déclarent).
    private func makeRouterProvider(
        _ descriptor: ProviderDescriptor,
        backing: ProviderDescriptor.RouterBacking
    ) -> (any AIProvider)? {
        let routerProviderId: String
        if descriptor.id == "local" {
            guard let configured = settingsRepository.localRouterProviderId() else {
                AppLog.providers.debug(
                    "Skipping local provider — no providers.local.routerProviderId configured"
                )
                return nil
            }
            routerProviderId = configured
        } else {
            routerProviderId = backing.routerProviderId
        }
        return RouterBackedProvider(
            id: descriptor.id,
            name: descriptor.name,
            routerProviderId: routerProviderId,
            cliCommand: descriptor.cliCommand,
            dashboardURL: descriptor.dashboardURL,
            statusPageURL: descriptor.statusPageURL,
            source: routerSnapshotClient,
            settingsRepository: settingsRepository,
            dailyUsageAnalyzer: backing.dailyUsage ? ClaudeDailyUsageAnalyzer() : nil,
            passProbe: backing.guestPassEnabled ? ClaudePassProbe() : nil,
            guestPassEnabled: backing.guestPassEnabled
        )
    }

    /// Native (autonomous) constructors. The switch is keyed by catalog id and
    /// the `default` branch is LOUD: an unmapped descriptor is a programming
    /// error caught by `catalogIsExhaustivelyMapped` in CI, never a silent drop.
    private func makeNativeProvider(_ descriptor: ProviderDescriptor) -> (any AIProvider)? {
        switch descriptor.id {
        case "claude":
            return ClaudeProvider(
                cliProbe: ClaudeUsageProbe(),
                apiProbe: ClaudeAPIUsageProbe(),
                passProbe: ClaudePassProbe(),
                settingsRepository: settingsRepository,
                dailyUsageAnalyzer: ClaudeDailyUsageAnalyzer(),
                cliProbeFactory: { configDir in ClaudeUsageProbe(configDirectory: ClaudeProfileLocation.customDirectory(configDir)) },
                apiProbeFactory: { configDir in
                    if let configDir = ClaudeProfileLocation.customDirectory(configDir) {
                        ClaudeAPIUsageProbe(configDirectory: configDir)
                    } else {
                        ClaudeAPIUsageProbe()
                    }
                },
                statusLineProbeFactory: { [settingsRepository] configDir in
                    ClaudeStatusLineProbe(
                        configDir: (configDir as NSString?)?.expandingTildeInPath
                            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude"),
                        settingsProvider: { [settingsRepository] in
                            settingsRepository.isClaudeStatusLineAdapterEnabled()
                        }
                    )
                }
            )
        case "codex":
            if settingsRepository.accounts(forProvider: "codex").isEmpty {
                return CodexProvider(probe: CodexUsageProbe(), settingsRepository: settingsRepository)
            }
            return AccountUsageProvider(id: descriptor.id, name: descriptor.name,
                cliCommand: descriptor.cliCommand, dashboardURL: descriptor.dashboardURL,
                settings: settingsRepository, settingsFileURL: watchedSettingsURL,
                makeProbe: { config in
                    CodexUsageProbe(client: DefaultCodexRPCClient(codexHome: config.probeConfig["codexHome"]))
                })
        case "qwen":
            return AccountUsageProvider(id: descriptor.id, name: descriptor.name,
                cliCommand: "bl", dashboardURL: descriptor.dashboardURL, settings: settingsRepository,
                defaultConfig: .init(accountId: "default", label: "Token Plan"),
                settingsFileURL: watchedSettingsURL, makeProbe: { config in
                    QwenPlanUsageProbe(profile: config.probeConfig["bailianProfile"] ?? "default",
                        site: config.probeConfig["consoleSite"] ?? "international",
                        region: config.probeConfig["consoleRegion"] ?? "ap-southeast-1")
                })
        case "gemini":
            return GeminiProvider(probe: GeminiUsageProbe(), settingsRepository: settingsRepository)
        case "antigravity":
            return AntigravityProvider(probe: AntigravityUsageProbe(), settingsRepository: settingsRepository)
        case "copilot":
            return CopilotProvider(
                billingProbe: CopilotUsageProbe(settingsRepository: settingsRepository),
                internalProbe: CopilotInternalAPIProbe(settingsRepository: settingsRepository),
                settingsRepository: settingsRepository
            )
        case "ampcode":
            return AmpCodeProvider(probe: AmpCodeUsageProbe(), settingsRepository: settingsRepository)
        case "kiro":
            return KiroProvider(probe: KiroUsageProbe(), settingsRepository: settingsRepository)
        case "cursor":
            return CursorProvider(probe: CursorUsageProbe(), settingsRepository: settingsRepository)
        case "deepseek":
            return DeepSeekProvider(
                probe: DeepSeekUsageProbe(settingsRepository: settingsRepository),
                settingsRepository: settingsRepository
            )
        case "vercel-gateway":
            return VercelProvider(
                probe: VercelUsageProbe(settingsRepository: settingsRepository),
                settingsRepository: settingsRepository
            )
        case "mistral":
            return MistralProvider(probe: MistralUsageProbe(), settingsRepository: settingsRepository)
        case "opencode-go", "commandcode", "ollama":
            return AccountUsageProvider(
                id: descriptor.id, name: descriptor.name, cliCommand: descriptor.cliCommand,
                dashboardURL: descriptor.dashboardURL, settings: settingsRepository,
                settingsFileURL: watchedSettingsURL,
                makeProbe: { config in APIAccountCredentials.probe(providerId: descriptor.id, config: config) }
            )
        case "omp":
            return OmpProvider(probe: OmpUsageProbe(), settingsRepository: settingsRepository)
        case "grok":
            return GrokProvider(probe: GrokUsageProbe(), settingsRepository: settingsRepository)
        default:
            assertionFailure(
                "Catalog id \(descriptor.id) has no native composition mapping — add it or remove the descriptor"
            )
            AppLog.providers.error(
                "Catalog id \(descriptor.id) has no native composition mapping — provider NOT instantiated"
            )
            return nil
        }
    }

    /// Résolution pure du mode de source pour un descripteur bi-mode.
    private func resolvedSourceMode(for descriptor: ProviderDescriptor) -> QuotaSourceMode {
        guard descriptor.supportedModes.count > 1 else {
            return descriptor.supportedModes.first ?? .autonomous
        }
        return sourceModeResolver.configuredMode(
            providerId: descriptor.id,
            accounts: settingsRepository.accounts(forProvider: descriptor.id),
            globalDefault: defaultSourceMode
        )
    }
}
