import Foundation

/// Une session observée chez un outil IA. C'est une **observation**, jamais une
/// déduction : chaque champ vient d'une source nommée (transcript, base locale,
/// fichier de liveness) et peut rester inconnu.
public struct SessionObservation: Sendable, Equatable, Identifiable {
    /// Ce que la source sait de l'état de la session, du plus fort au plus faible.
    public enum Activity: String, Sendable, Equatable {
        /// Un processus vivant l'a déclarée (fichier de liveness + PID vérifié).
        case open
        /// Activité très récente sans processus identifiable (mise à jour < 2 min).
        case working
        /// Session utilisée dans la fenêtre retenue, sans activité en cours.
        case recent
        /// Activité trop ancienne pour prouver quoi que ce soit (jamais « fermée »).
        case unknown
    }

    public let id: String
    public let toolId: String
    public let title: String?
    public let directory: String?
    public let model: String?
    public let updatedAt: Date?
    public let activity: Activity
    public let isSubagent: Bool

    public var identifier: String { "\(toolId):\(id)" }

    public init(
        id: String,
        toolId: String,
        title: String? = nil,
        directory: String? = nil,
        model: String? = nil,
        updatedAt: Date? = nil,
        activity: Activity,
        isSubagent: Bool = false
    ) {
        self.id = id
        self.toolId = toolId
        self.title = title
        self.directory = directory
        self.model = model
        self.updatedAt = updatedAt
        self.activity = activity
        self.isSubagent = isSubagent
    }
}

/// Santé d'une collecte : une source qui échoue doit le dire, jamais rendre
/// une liste vide qui se lirait comme « aucune session ».
public struct SessionSourceReport: Sendable, Equatable {
    public let toolId: String
    public let observations: [SessionObservation]
    /// nil quand la collecte a réussi.
    public let failure: String?

    public init(toolId: String, observations: [SessionObservation], failure: String? = nil) {
        self.toolId = toolId
        self.observations = observations
        self.failure = failure
    }
}

/// Contrat d'une source de sessions. Chaque outil (Claude Code, Codex, Kimi,
/// Qwen, OpenCode, Command Code) l'implémente selon ce qu'il expose réellement —
/// transcripts, base locale, fichiers de processus — et déclare ce qu'il ne
/// sait pas (`activity: .unknown`) au lieu de le deviner.
public protocol SessionSource: Sendable {
    /// Id de l'outil, aligné sur `ProviderCatalog` (ex. « opencode-go »).
    var toolId: String { get }
    /// L'outil est-il présent/configuré sur cette machine ? Sert à la
    /// détection : un outil installé seul reste une suggestion.
    func isDetected() async -> Bool
    /// Collecte bornée, la plus récente d'abord. Ne lève jamais : un échec est
    /// rapporté dans `SessionSourceReport.failure`.
    func collect(limit: Int, now: Date) async -> SessionSourceReport
}

public extension SessionCounts {
    /// Comptage par état, sur des observations déjà dédupliquées par la source.
    /// Les sous-agents sont comptés à part et jamais comme sessions.
    static func from(_ observations: [SessionObservation]) -> SessionCounts {
        SessionCounts(
            open: observations.filter { $0.activity == .open && !$0.isSubagent }.count,
            working: observations.filter { $0.activity == .working && !$0.isSubagent }.count,
            recent: observations.filter { $0.activity == .recent && !$0.isSubagent }.count,
            subagents: observations.filter(\.isSubagent).count
        )
    }
}

/// Compteur d'une fenêtre : séparé explicitement pour ne jamais confondre
/// « ouverte » (processus vivant), « en travail » (activité récente) et
/// « utilisée sur la fenêtre » (historique).
public struct SessionCounts: Sendable, Equatable {
    public let open: Int
    public let working: Int
    public let recent: Int
    public let subagents: Int

    public init(open: Int, working: Int, recent: Int, subagents: Int) {
        self.open = open
        self.working = working
        self.recent = recent
        self.subagents = subagents
    }
}
