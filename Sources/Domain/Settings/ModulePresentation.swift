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
        case .visible: "Afficher"
        case .hidden: "Masquer"
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
        case .usageCosts: "Usage et coûts"
        case .localRuntime: "Services IA locaux"
        case .integrations: "Intégrations"
        }
    }

    public var subtitle: String {
        switch self {
        case .providers:
            "Barres de quota des outils suivis. Visible dès qu'un compte est configuré."
        case .sessions:
            "Sessions en cours et activité des 24 h. Visible dès qu'un outil est détecté, même sans quota."
        case .usageCosts:
            "Résumé d'usage et estimation de dépense. Replié tant qu'aucune source de coût n'existe."
        case .localRuntime:
            "Moteurs locaux et serveurs MCP configurés. Détail avancé, masqué par défaut."
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
