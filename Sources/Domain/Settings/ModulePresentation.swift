import Foundation

/// Ce que l'utilisateur veut VOIR d'un module : automatique (dès qu'il a
/// réellement des données), toujours affiché, ou masqué. C'est une décision de
/// présentation, indépendante du SUIVI (la collecte) — masquer n'arrête pas la
/// collecte, et arrêter la collecte ne masque pas forcément la ligne.
public enum ModuleVisibility: String, Sendable, Equatable, CaseIterable, Codable {
    case automatic
    case visible
    case hidden

    public var displayLabel: String {
        switch self {
        case .automatic: "Automatique"
        case .visible: "Show"
        case .hidden: "Hide"
        }
    }
}

/// Les modules de premier niveau exposés par les réglages Cortex.
public enum FeatureModule: String, Sendable, CaseIterable, Identifiable {
    /// Barres de quota et état des fournisseurs suivis.
    case providers
    /// Sessions et activité des outils IA.
    case sessions
    /// Usage et estimation de coûts.
    case usageCosts
    /// Services IA locaux et serveurs MCP.
    case localRuntime
    /// tmux, missions, hooks et notifications externes.
    case integrations

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .providers: "Quotas"
        case .sessions: "Sessions"
        case .usageCosts: "Usage & costs"
        case .localRuntime: "Services IA locaux"
        case .integrations: "Integrations"
        }
    }

    public var subtitle: String {
        switch self {
        case .providers:
            "Quota bars for tracked tools. Visible as soon as an account is configured."
        case .sessions:
            "Live sessions and 24 h activity. Visible as soon as a tool is detected, even without quota."
        case .usageCosts:
            "Usage summary and cost estimate. Collapsed while no cost source exists."
        case .localRuntime:
            "Configured local engines and MCP servers. Advanced detail, hidden by default."
        case .integrations:
            "tmux, missions, hooks et notifications externes. Facultatif."
        }
    }

    /// Défaut de présentation quand l'utilisateur n'a rien choisi.
    public var defaultVisibility: ModuleVisibility {
        switch self {
        case .providers, .sessions, .usageCosts: .automatic
        case .localRuntime, .integrations: .hidden
        }
    }
}

/// Décision de présentation : pure, testable, sans I/O.
public struct ModulePresentationResolver: Sendable {

    public init() {}

    /// Valeur effective : le choix stocké gagne, sinon le défaut du module.
    public func effectiveVisibility(
        stored: ModuleVisibility?,
        default fallback: ModuleVisibility
    ) -> ModuleVisibility {
        stored ?? fallback
    }

    /// `hasEvidence` = le module a réellement quelque chose à montrer (un
    /// compte configuré, un outil détecté, une source de coût…). En mode
    /// automatique, un module suivi mais vide reste caché : c'est la détection
    /// qui décide, jamais une hypothèse.
    public func isVisible(
        declared: ModuleVisibility,
        isFollowed: Bool,
        hasEvidence: Bool
    ) -> Bool {
        switch declared {
        case .visible: return true
        case .hidden: return false
        case .automatic: return isFollowed && hasEvidence
        }
    }
}

/// Lecture/écriture des réglages de présentation. Implémenté par le store
/// JSON (`display.<module>.visibility`), jamais dupliqué ailleurs.
public protocol ModuleVisibilitySettingsRepository: Sendable {
    func moduleVisibility(forModule id: String, default fallback: ModuleVisibility) -> ModuleVisibility
    func setModuleVisibility(_ visibility: ModuleVisibility, forModule id: String)
}
