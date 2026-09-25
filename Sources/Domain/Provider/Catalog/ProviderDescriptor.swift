import Foundation

/// Ce qu'un provider sait réellement faire dans Cortex. C'est la déclaration
/// que lisent l'UI (réglages Fonctionnalités, catalogue `+`) et la composition :
/// un module n'est proposé que sur les dimensions qu'il supporte vraiment.
public enum ProviderCapability: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Produit des relevés de quota/usage (barres, alertes).
    case quota
    /// Plusieurs comptes isolés (profils, alias ou clés) suivis séparément.
    case accounts
    /// Profils détectables sur le disque (découverte automatique).
    case discovery
    /// Sessions/activité observables (transcripts, base locale).
    case sessions
    /// Historique d'usage (scan de transcripts / rapports quotidiens).
    case history
    /// Estimation de dépense théorique (grille tarifaire × usage).
    case costEstimate
    /// Reconnexion assistée (relogin vérifié).
    case reconnect
    /// Comptes enrôlés par clé API (sonde live → Trousseau). Seule source de
    /// vérité des écrans d'ajout par clé : aucune liste d'ids codée en dur.
    case apiKeyAccounts
}

/// Description statique d'un provider reconnu par Cortex. C'est le contrat de
/// la couche Composition : elle instancie AU PLUS UN runtime provider par `id`
/// (cf. `ProviderComposition`) en se basant sur ces champs. Aucune I/O, aucune
/// dépendance Infrastructure — pure Domain.
public struct ProviderDescriptor: Sendable, Equatable, Hashable {
    public enum Category: String, Sendable, Equatable, CaseIterable {
        /// Ajout d'un compte utilisateur authentifié (Claude, Codex, …).
        case account
        /// Connexion API/clé/locale activable/désactivable.
        case integration
    }

    /// Réglages propres aux providers servis par le snapshot llm-router.
    public struct RouterBacking: Sendable, Equatable, Hashable {
        public let routerProviderId: String
        /// Claude uniquement : pass invité + rapport d'usage quotidien.
        public let guestPassEnabled: Bool
        public let dailyUsage: Bool

        public init(routerProviderId: String, guestPassEnabled: Bool = false, dailyUsage: Bool = false) {
            self.routerProviderId = routerProviderId
            self.guestPassEnabled = guestPassEnabled
            self.dailyUsage = dailyUsage
        }
    }

    /// Comment la composition construit le runtime provider de cet id.
    public enum Runtime: Sendable, Equatable, Hashable {
        /// Toujours depuis le snapshot llm-router.
        case router(RouterBacking)
        /// Toujours depuis une sonde native Cortex (aucune dépendance routeur).
        case native
        /// Selon le `sourceMode` résolu (`QuotaSourceResolver`). Valide seulement
        /// quand `supportedModes` contient les deux modes.
        case routerOrNative(RouterBacking)
    }

    public let id: String
    public let name: String
    public let cliCommand: String
    public let dashboardURL: URL?
    public let statusPageURL: URL?
    public let supportedModes: Set<QuotaSourceMode>
    public let category: Category
    /// `true` ⇒ l'entrée ne s'affiche pas par défaut ; l'utilisateur l'active
    /// explicitement depuis le catalogue `+` (ou les réglages Fonctionnalités).
    public let isOptional: Bool
    /// Glyphe SF Symbol (4.x) de secours — le rendu officiel reste `ProviderIconView`.
    public let symbolName: String
    /// Dimensions réellement supportées (cf. `ProviderCapability`).
    public let capabilities: Set<ProviderCapability>
    /// Comment instancier ce provider.
    public let runtime: Runtime

    /// Suivi activé par défaut ? Symétrique de `isOptional`, nommé pour l'UI :
    /// un module non optionnel est suivi d'office ; un module optionnel attend
    /// une activation explicite.
    public var defaultEnabled: Bool { !isOptional }

    public init(
        id: String,
        name: String,
        cliCommand: String,
        dashboardURL: URL? = nil,
        statusPageURL: URL? = nil,
        supportedModes: Set<QuotaSourceMode>,
        category: Category,
        isOptional: Bool,
        symbolName: String,
        capabilities: Set<ProviderCapability>,
        runtime: Runtime
    ) {
        self.id = id
        self.name = name
        self.cliCommand = cliCommand
        self.dashboardURL = dashboardURL
        self.statusPageURL = statusPageURL
        self.supportedModes = supportedModes
        self.category = category
        self.isOptional = isOptional
        self.symbolName = symbolName
        self.capabilities = capabilities
        self.runtime = runtime
    }
}

/// Catalogue canonique des providers reconnus à la livraison. Il est CONSTANT
/// jusqu'à ce qu'un add/delete entre par le service d'enrôlement (pas avant).
///
/// Un seul endroit déclare : existence, catégorie, capacités, runtime. La
/// composition (`ProviderComposition`) et l'UI (réglages, catalogue `+`) en
/// dérivent — ajouter un provider = ajouter un descripteur + son constructeur.
public enum ProviderCatalog {

    /// Alias local : les descripteurs s'écrivent sans préfixer le type imbriqué.
    private typealias RouterBacking = ProviderDescriptor.RouterBacking

    // MARK: - Comptes (suivis d'office)

    public static let claude = ProviderDescriptor(
        id: "claude",
        name: "Claude",
        cliCommand: "claude",
        dashboardURL: URL(string: "https://console.anthropic.com/settings/billing"),
        statusPageURL: URL(string: "https://status.anthropic.com"),
        supportedModes: [.autonomous, .router],
        category: .account,
        isOptional: false,
        symbolName: "sparkles",
        capabilities: [.quota, .accounts, .discovery, .sessions, .history, .costEstimate, .reconnect],
        runtime: .routerOrNative(
            RouterBacking(routerProviderId: "claude", guestPassEnabled: true, dailyUsage: true)
        )
    )

    public static let codex = ProviderDescriptor(
        id: "codex",
        name: "Codex",
        cliCommand: "codex",
        dashboardURL: URL(string: "https://platform.openai.com/usage"),
        statusPageURL: URL(string: "https://status.openai.com"),
        supportedModes: [.autonomous, .router],
        category: .account,
        isOptional: false,
        symbolName: "chevron.left.forwardslash.chevron.right",
        capabilities: [.quota, .accounts, .discovery, .sessions, .costEstimate, .reconnect],
        runtime: .routerOrNative(RouterBacking(routerProviderId: "codex"))
    )

    public static let kimi = ProviderDescriptor(
        id: "kimi",
        name: "Kimi",
        cliCommand: "kimi",
        dashboardURL: URL(string: "https://www.kimi.com/code/console"),
        supportedModes: [.router],
        category: .account,
        isOptional: false,
        symbolName: "message.fill",
        capabilities: [.quota, .sessions, .costEstimate],
        runtime: .router(RouterBacking(routerProviderId: "kimi"))
    )

    public static let qwenPlan = ProviderDescriptor(
        id: "qwen",
        name: "Alibaba Token Plan",
        cliCommand: "qwen",
        dashboardURL: URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/subscription/token-plan/personal"),
        supportedModes: [.autonomous, .router],
        category: .account,
        isOptional: false,
        symbolName: "globe",
        capabilities: [.quota, .sessions, .costEstimate],
        // 2026-09-24 (Ben): il n'existe qu'UN abonnement Alibaba — le Token Plan
        // Personal, router id `bailian_token_plan`. L'ancien `qwen_personal_pro`
        // n'était qu'une sync manuelle morte (2026-08-17). Le backing suivait
        // `qwen_personal_pro` alors que RouterProviderIdMap mappait déjà
        // `qwen -> bailian_token_plan` : la contradiction est levée ici.
        runtime: .routerOrNative(RouterBacking(routerProviderId: "bailian_token_plan"))
    )

    public static let glm = ProviderDescriptor(
        id: "glm",
        name: "GLM",
        cliCommand: "claude",
        dashboardURL: URL(string: "https://z.ai/subscribe"),
        statusPageURL: URL(string: "https://docs.z.ai/devpack/faq"),
        supportedModes: [.router],
        category: .account,
        isOptional: false,
        symbolName: "bolt.fill",
        capabilities: [.quota, .costEstimate],
        runtime: .router(RouterBacking(routerProviderId: "glm_pro"))
    )

    public static let minimax = ProviderDescriptor(
        id: "minimax",
        name: "MiniMax",
        cliCommand: "minimax",
        dashboardURL: URL(string: "https://platform.minimax.io"),
        supportedModes: [.router],
        category: .account,
        isOptional: false,
        symbolName: "waveform",
        capabilities: [.quota, .costEstimate],
        runtime: .router(RouterBacking(routerProviderId: "minimax_max"))
    )

    // MARK: - Connexions suivies d'office

    public static let gemini = ProviderDescriptor(
        id: "gemini",
        name: "Gemini",
        cliCommand: "gemini",
        dashboardURL: URL(string: "https://aistudio.google.com/apikey"),
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: false,
        symbolName: "star",
        capabilities: [.quota],
        runtime: .native
    )

    public static let antigravity = ProviderDescriptor(
        id: "antigravity",
        name: "Antigravity",
        cliCommand: "antigravity",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: false,
        symbolName: "atom",
        capabilities: [.quota],
        runtime: .native
    )

    public static let copilot = ProviderDescriptor(
        id: "copilot",
        name: "Copilot",
        cliCommand: "gh",
        dashboardURL: URL(string: "https://github.com/settings/copilot"),
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: false,
        symbolName: "airplane",
        capabilities: [.quota],
        runtime: .native
    )

    /// La ligne OpenCode Go lit le pool de clés (failover SSOT) via l'API
    /// officielle `/zen/go/v1/usage`, avec repli sur la base locale.
    public static let openCodeGo = ProviderDescriptor(
        id: "opencode-go",
        name: "OpenCode Go",
        cliCommand: "opencode",
        dashboardURL: URL(string: "https://opencode.ai/workspace"),
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: false,
        symbolName: "curlybraces",
        capabilities: [.quota, .accounts, .apiKeyAccounts, .sessions],
        runtime: .native
    )

    public static let commandCode = ProviderDescriptor(
        id: "commandcode",
        name: "Command Code",
        cliCommand: "cmd",
        dashboardURL: URL(string: "https://commandcode.ai"),
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: false,
        symbolName: "command",
        capabilities: [.quota, .accounts, .apiKeyAccounts, .sessions],
        runtime: .native
    )

    /// Ollama Cloud : une clé API par abonnement, usage lu sur
    /// `GET ollama.com/api/usage` (fractions consommées par fenêtre).
    public static let ollama = ProviderDescriptor(
        id: "ollama",
        name: "Ollama Cloud",
        cliCommand: "ollama",
        dashboardURL: URL(string: "https://ollama.com/settings"),
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: false,
        symbolName: "cloud.circle",
        capabilities: [.quota, .accounts, .apiKeyAccounts],
        runtime: .native
    )

    // MARK: - Connexions optionnelles (activées explicitement)

    // NOTE 2026-09-23 (Cortex v7.2): the `qwen-api` descriptor was removed. It
    // pointed at the dead router provider `qwen_cloud_payg`; the Qwen token plan
    // is served by `qwen` → `bailian_token_plan`. Never reintroduce
    // `qwen_cloud_payg`. `QwenApiRemovalMigration` deletes any residual
    // `providers.qwen-api` settings key.

    public static let bedrock = ProviderDescriptor(
        id: "bedrock",
        name: "AWS Bedrock",
        cliCommand: "aws",
        dashboardURL: URL(string: "https://console.aws.amazon.com/bedrock/home"),
        statusPageURL: URL(string: "https://health.aws.amazon.com/health/status"),
        supportedModes: [.router],
        category: .integration,
        isOptional: true,
        symbolName: "server.rack",
        capabilities: [.quota],
        runtime: .router(RouterBacking(routerProviderId: "bedrock"))
    )

    public static let local = ProviderDescriptor(
        id: "local",
        name: "Local",
        cliCommand: "",
        supportedModes: [.router],
        category: .integration,
        isOptional: true,
        symbolName: "desktopcomputer",
        capabilities: [.quota],
        // Placeholder only: the composition resolves the real router id from
        // `providers.local.routerProviderId` and skips the row when unset.
        // No machine-specific id lives here (E1).
        runtime: .router(RouterBacking(routerProviderId: "local"))
    )

    public static let ampcode = ProviderDescriptor(
        id: "ampcode",
        name: "Amp Code",
        cliCommand: "amp",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: true,
        symbolName: "bolt.circle",
        capabilities: [.quota],
        runtime: .native
    )

    public static let kiro = ProviderDescriptor(
        id: "kiro",
        name: "Kiro",
        cliCommand: "kiro",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: true,
        symbolName: "circle.hexagongrid",
        capabilities: [.quota],
        runtime: .native
    )

    public static let cursor = ProviderDescriptor(
        id: "cursor",
        name: "Cursor",
        cliCommand: "cursor",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: true,
        symbolName: "cursorarrow",
        capabilities: [.quota],
        runtime: .native
    )

    public static let deepseek = ProviderDescriptor(
        id: "deepseek",
        name: "DeepSeek",
        cliCommand: "deepseek",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: true,
        symbolName: "water.waves",
        capabilities: [.quota],
        runtime: .native
    )

    public static let vercelGateway = ProviderDescriptor(
        id: "vercel-gateway",
        name: "Vercel AI Gateway",
        cliCommand: "vercel",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: true,
        symbolName: "triangle",
        capabilities: [.quota],
        runtime: .native
    )

    public static let mistral = ProviderDescriptor(
        id: "mistral",
        name: "Mistral",
        cliCommand: "vibe",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: true,
        symbolName: "wind",
        capabilities: [.quota, .history],
        runtime: .native
    )

    public static let omp = ProviderDescriptor(
        id: "omp",
        name: "Oh My Pi",
        cliCommand: "omp",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: true,
        symbolName: "function",
        capabilities: [.quota],
        runtime: .native
    )

    public static let grok = ProviderDescriptor(
        id: "grok",
        name: "Grok",
        cliCommand: "grok",
        supportedModes: [.autonomous],
        category: .integration,
        isOptional: true,
        symbolName: "xmark.circle",
        capabilities: [.quota],
        runtime: .native
    )

    /// Catalogue complet dans l'ordre d'affichage du menu : comptes, puis
    /// connexions suivies d'office, puis connexions optionnelles.
    /// C4 invariant: EVERY id here must have a composition decision — see
    /// `ProviderCompositionTests.catalogIsExhaustivelyMapped`. Adding a
    /// descriptor without a mapping fails that test; a provider must never
    /// disappear silently.
    public static let all: [ProviderDescriptor] = [
        claude, codex, kimi, qwenPlan, glm, minimax,
        gemini, antigravity, copilot, openCodeGo, commandCode, ollama,
        bedrock, local, ampcode, kiro, cursor,
        deepseek, vercelGateway, mistral, omp, grok,
    ]

    /// Tous les ids connus, dans l'ordre du catalogue.
    public static var allIDs: [String] { all.map(\.id) }

    /// Lookup O(1). Retourne `nil` si l'id n'est pas un provider reconnu —
    /// c'est à la couche Composition de se protéger contre un provider
    /// inconnu arrivant depuis un settings.json legacy.
    public static func descriptor(forId id: String) -> ProviderDescriptor? {
        all.first { $0.id == id }
    }

    /// Providers dont les comptes s'enrôlent par clé API, dans l'ordre du catalogue.
    public static var apiKeyAccountIDs: [String] {
        all.filter { $0.capabilities.contains(.apiKeyAccounts) }.map(\.id)
    }

    /// Providers où l'utilisateur peut ajouter un compte (profil ou clé).
    public static var addableAccountIDs: [String] {
        all.filter { $0.capabilities.contains(.accounts) }.map(\.id)
    }

    /// Les providers routables depuis le snapshot llm-router (dans l'ordre).
    /// Sert aux migrations qui décident du roster par défaut.
    public static var routerOnlyIDs: [String] {
        all.filter { descriptor in
            descriptor.supportedModes == [.router]
        }.map(\.id)
    }
}
