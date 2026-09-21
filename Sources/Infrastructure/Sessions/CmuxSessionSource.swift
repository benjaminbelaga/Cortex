import Foundation
import Domain

/// Source de sessions **cmux** — l'app de workspaces/terminaux. Lecture seule du
/// fichier d'état de session, sans jamais lancer l'app ni parler à son socket.
///
/// Ce que la recon a prouvé (2026-09-20, poste de Ben) : cmux persiste son état
/// vivant dans
///   `~/Library/Application Support/cmux/session-com.cmuxterm.app.json`
/// dont la forme est `windows[] → tabManager.workspaces[] → panels[]` :
///   • chaque workspace porte `workspaceId`, `currentDirectory`, `customTitle`
///     et `processTitle` (le titre du processus du pane focalisé — ex.
///     « ⌘ Command Code · yoyaku · deepseek-v4-flash-(latest) ») ;
///   • chaque panel (pane) porte `id`, `stableSurfaceId`, `type`
///     (`terminal`/`browser`/`filepreview`), `title`, `directory` et
///     `terminal.workingDirectory`.
///
/// Un pane **terminal** présent dans cet état est une session ouverte
/// (`activity: .open`), avec son dossier (`directory`) et son libellé (`title`).
/// La fraîcheur du fichier sert de preuve de vie : cmux n'écrit aucun PID
/// sur disque, et son socket de contrôle est protégé par mot de passe — on ne
/// s'y connecte donc pas. Un état trop vieux pour prouver la vie n'est jamais
/// présenté comme « ouvert » : il reste `.unknown`.
///
/// Rien n'est inventé : les panes `browser`/`filepreview` ne sont pas des
/// sessions terminal et sont écartés ; l'absence du fichier est rapportée comme
/// échec, jamais comme un faux zéro.
public struct CmuxSessionSource: SessionSource {

    public let toolId = "cmux"

    /// Au-delà de ce délai, l'état de session ne prouve plus qu'un pane est
    /// ouvert : il redevient `.unknown` (jamais « fermé »). cmux réécrit ce
    /// fichier à chaque changement ; la fenêtre est volontairement large.
    public static let livenessWindow: TimeInterval = 30 * 60

    /// Le fichier d'état reste petit (quelques centaines de Ko) ; on borne tout
    /// de même la lecture.
    static let maxSnapshotBytes = 8 * 1024 * 1024

    private let snapshotPath: String
    private let livenessWindow: TimeInterval

    public init(
        snapshotPath: String = CmuxSessionSource.defaultSnapshotPath(),
        livenessWindow: TimeInterval = CmuxSessionSource.livenessWindow
    ) {
        self.snapshotPath = snapshotPath
        self.livenessWindow = livenessWindow
    }

    // MARK: - Defaults

    /// `~/Library/Application Support/cmux/session-<bundle-id>.json`, le
    /// bundle id de l'app étant `com.cmuxterm.app`.
    public static func defaultSnapshotPath(
        home: String = NSHomeDirectory(),
        bundleId: String = "com.cmuxterm.app"
    ) -> String {
        let support = (home as NSString).appendingPathComponent("Library/Application Support/cmux")
        return (support as NSString).appendingPathComponent("session-\(bundleId).json")
    }

    // MARK: - SessionSource

    public func isDetected() async -> Bool {
        FileManager.default.fileExists(atPath: snapshotPath)
    }

    public func collect(limit: Int, now: Date) async -> SessionSourceReport {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: snapshotPath) else {
            return SessionSourceReport(
                toolId: toolId,
                observations: [],
                failure: "état de session cmux introuvable (\(snapshotPath))"
            )
        }
        let modifiedAt = attributes[.modificationDate] as? Date
        let url = URL(fileURLWithPath: snapshotPath)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) <= Self.maxSnapshotBytes,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SessionSourceReport(
                toolId: toolId,
                observations: [],
                failure: "état de session cmux illisible (\(snapshotPath))"
            )
        }

        let isLive = modifiedAt.map { now.timeIntervalSince($0) < livenessWindow } ?? false
        let observations = Self.panes(in: root, updatedAt: modifiedAt, isLive: isLive)
        return SessionSourceReport(
            toolId: toolId,
            observations: Array(observations.prefix(limit)),
            failure: nil
        )
    }

    // MARK: - Parsing

    private static func panes(in root: [String: Any], updatedAt: Date?, isLive: Bool) -> [SessionObservation] {
        var byPane: [String: SessionObservation] = [:]
        var order: [String] = []
        guard let windows = root["windows"] as? [[String: Any]] else { return [] }
        for window in windows {
            guard let tabManager = window["tabManager"] as? [String: Any],
                  let workspaces = tabManager["workspaces"] as? [[String: Any]] else { continue }
            for workspace in workspaces {
                let workspaceDirectory = workspace["currentDirectory"] as? String
                let processTitle = workspace["processTitle"] as? String
                guard let panels = workspace["panels"] as? [[String: Any]] else { continue }
                for panel in panels {
                    guard (panel["type"] as? String) == "terminal" else { continue }
                    let identifier = (panel["stableSurfaceId"] as? String) ?? (panel["id"] as? String)
                    guard let identifier, !identifier.isEmpty, byPane[identifier] == nil else { continue }
                    let terminal = panel["terminal"] as? [String: Any]
                    let title = panel["title"] as? String
                    byPane[identifier] = SessionObservation(
                        id: identifier,
                        toolId: "cmux",
                        title: title,
                        directory: (panel["directory"] as? String)
                            ?? (terminal?["workingDirectory"] as? String)
                            ?? workspaceDirectory,
                        // Best-effort : le modèle n'existe que dans le libellé du
                        // pane focalisé (« … · <modèle> »).
                        model: modelToken(from: title) ?? modelToken(from: processTitle),
                        updatedAt: updatedAt,
                        // Un pane présent dans l'état vivant est « ouvert » ; un
                        // état trop vieux pour le prouver reste `.unknown`.
                        activity: isLive ? .open : .unknown,
                        isSubagent: false
                    )
                    order.append(identifier)
                }
            }
        }
        return order.compactMap { byPane[$0] }
    }

    /// Extrait le dernier segment « · <modèle> » d'un titre de pane/processus,
    /// sans jamais le deviner quand il n'y a pas de séparateur.
    private static func modelToken(from title: String?) -> String? {
        guard let title, title.contains("·") else { return nil }
        guard let last = title.split(separator: "·").last?.trimmingCharacters(in: .whitespaces),
              !last.isEmpty else { return nil }
        // Un identifiant de modèle porte un chiffre ou un tiret (« v4 », « gpt-4 ») :
        // un simple mot (« yoyaku ») n'est jamais pris pour un modèle.
        let looksLikeModel = last.contains("-") || last.contains(where: \.isNumber)
        return looksLikeModel ? last : nil
    }
}
