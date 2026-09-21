import Foundation
import Domain

/// Source de sessions **Command Code** (`cmd`) — lecture seule, bornée, sans
/// jamais lancer l'outil pour le détecter.
///
/// Ce que la recon a prouvé (2026-09-20, poste de Ben) :
///   • `~/.commandcode/projects/<cwd-encodé>/<session>.jsonl` — le transcript :
///     la première ligne est un en-tête `{"type":"session","id":…,"cwd":…,
///     "timestamp":…}` ; les lignes suivantes sont des `message` (le `model`,
///     `usage` et `effort` apparaissent sur les tours assistant) et des
///     `compaction`.
///   • `…/<session>.meta.json` — `title`, parfois `model`, et, pour une session
///     dérivée (fork), `parentSessionId` + `forkedAt`.
///   • `…/<session>.checkpoints.jsonl` — points de reprise, ignorés ici.
///
/// Il n'existe **aucune** trace de processus vivant par session : ni PID, ni
/// fichier de verrou (seul le planificateur cron a un bail, `cron/scheduler-
/// lease.json`). L'état « ouverte » n'est donc jamais deviné : une activité
/// fraîche (< 2 min) vaut `.working`, la fenêtre 24 h vaut `.recent`, plus
/// ancien vaut `.unknown` — jamais « fermée ». Un fichier illisible/illégal est
/// ignoré sans faire tomber le lot ; un répertoire absent est rapporté comme
/// échec, jamais comme un faux zéro.
public struct CommandCodeSessionSource: SessionSource {

    public let toolId = "commandcode"

    /// Fenêtre d'historique retenue (alignée sur OpenCode).
    public static let historyWindow: TimeInterval = 24 * 60 * 60
    /// Une session touchée dans ce délai est « en travail » (activité récente).
    public static let workingWindow: TimeInterval = 120

    /// Bornes de lecture : jamais plus de ces octets par fichier.
    static let headBytes = 64 * 1024
    static let tailBytes = 64 * 1024
    static let metaMaxBytes = 512 * 1024
    static let maxFilesScan = 1024

    private let projectsDirectory: String
    private let trackerDirectory: String
    private let processAlive: @Sendable (Int32) -> Bool

    public init(
        projectsDirectory: String = CommandCodeSessionSource.defaultProjectsDirectory(),
        trackerDirectory: String = CommandCodeSessionSource.defaultTrackerDirectory(),
        processAlive: @escaping @Sendable (Int32) -> Bool = CommandCodeSessionSource.defaultProcessAlive
    ) {
        self.projectsDirectory = projectsDirectory
        self.trackerDirectory = trackerDirectory
        self.processAlive = processAlive
    }

    // MARK: - Defaults

    public static func defaultProjectsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let override = environment["COMMANDCODE_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
            return (override as NSString).appendingPathComponent("projects")
        }
        return (home as NSString).appendingPathComponent(".commandcode/projects")
    }

    /// Même dossier de suivi que le plugin OpenCode (`tmux-assistant-resurrect`).
    /// Aucun traceur `commandcode-*.json` n'y existe aujourd'hui : la recon l'a
    /// vérifié. Le chemin reste injectable pour que les tests n'approchent
    /// jamais les données vivantes.
    public static func defaultTrackerDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let base = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("tmux-assistant-resurrect")
    }

    /// `kill(pid, 0)` : vivant si le signal passe, ou si EPERM.
    public static let defaultProcessAlive: @Sendable (Int32) -> Bool = { pid in
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - SessionSource

    public func isDetected() async -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: projectsDirectory, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func collect(limit: Int, now: Date) async -> SessionSourceReport {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: projectsDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return SessionSourceReport(
                toolId: toolId,
                observations: [],
                failure: "répertoire de sessions Command Code introuvable (\(projectsDirectory))"
            )
        }

        let projectDirectories: [String]
        do {
            projectDirectories = try fm.contentsOfDirectory(atPath: projectsDirectory)
        } catch {
            return SessionSourceReport(
                toolId: toolId,
                observations: [],
                failure: "répertoire des sessions Command Code illisible (\(error))"
            )
        }

        let liveIDs = liveSessionIDs()
        var bySession: [String: SessionObservation] = [:]
        var scanned = 0

        for project in projectDirectories.sorted() {
            let projectPath = (projectsDirectory as NSString).appendingPathComponent(project)
            var projectIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &projectIsDirectory),
                  projectIsDirectory.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files.sorted() where file.hasSuffix(".jsonl") && !file.hasSuffix(".checkpoints.jsonl") {
                guard scanned < Self.maxFilesScan else { break }
                scanned += 1
                let stem = (file as NSString).deletingPathExtension
                guard bySession[stem] == nil else { continue }   // dédup par id natif
                let transcript = (projectPath as NSString).appendingPathComponent(file)
                if let observation = observation(
                    sessionId: stem,
                    transcriptPath: transcript,
                    metaPath: (projectPath as NSString).appendingPathComponent("\(stem).meta.json"),
                    isLive: liveIDs.contains(stem),
                    now: now
                ) {
                    bySession[stem] = observation
                }
                // Un fichier illisible/illégal est simplement sauté : le lot continue.
            }
        }

        let observations = bySession.values.sorted { lhs, rhs in
            let lhsRank = Self.rank(lhs.activity)
            let rhsRank = Self.rank(rhs.activity)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        return SessionSourceReport(
            toolId: toolId,
            observations: Array(observations.prefix(limit)),
            failure: nil
        )
    }

    // MARK: - One session

    private func observation(
        sessionId: String,
        transcriptPath: String,
        metaPath: String,
        isLive: Bool,
        now: Date
    ) -> SessionObservation? {
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: transcriptPath) else {
            return nil
        }
        // Un transcript sans en-tête `type:session` n'est pas une session :
        // on le saute (ligne illégale, fichier tronqué) sans tuer le lot.
        guard let header = Self.firstSessionHeader(url: transcriptURL) else { return nil }
        let updatedAt = attributes[.modificationDate] as? Date

        // Modèle : `meta.json` d'abord, sinon dernier `model` vu dans une
        // fenêtre de queue (borné).
        let meta = Self.readJSONObject(url: URL(fileURLWithPath: metaPath), maxBytes: Self.metaMaxBytes)
        let model = (meta?["model"] as? String) ?? Self.lastModel(url: transcriptURL)

        let live = isLive
        let activity: SessionObservation.Activity
        if live {
            activity = .open
        } else if let updatedAt {
            let age = now.timeIntervalSince(updatedAt)
            if age < Self.workingWindow { activity = .working }
            else if age < Self.historyWindow { activity = .recent }
            else { activity = .unknown }
        } else {
            activity = .unknown
        }

        // Sous-session signalée par les données : `meta.json` porte
        // `parentSessionId` (+ `forkedAt`) — Command Code n'expose pas de
        // marqueur « sous-agent » distinct, on signale la filiation telle quelle.
        let parentId = (meta?["parentSessionId"] as? String)?.trimmingCharacters(in: .whitespaces)
        let isSubagent = parentId?.isEmpty == false

        return SessionObservation(
            id: sessionId,
            toolId: toolId,
            title: (meta?["title"] as? String) ?? header.title,
            directory: header.cwd,
            model: model,
            updatedAt: updatedAt,
            activity: activity,
            isSubagent: isSubagent
        )
    }

    private static func rank(_ activity: SessionObservation.Activity) -> Int {
        switch activity {
        case .open: 0
        case .working: 1
        case .recent: 2
        case .unknown: 3
        }
    }

    // MARK: - Liveness (optionnelle — aucun traceur présent aujourd'hui)

    private func liveSessionIDs() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: trackerDirectory) else { return [] }
        var ids = Set<String>()
        for name in entries.sorted() where name.hasPrefix("commandcode-") && name.hasSuffix(".json") {
            let url = URL(fileURLWithPath: trackerDirectory).appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) <= Self.metaMaxBytes,
                  let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let sessionId = (root["session_id"] as? String) ?? (root["sessionId"] as? String)
            let pid = Int32((root["pid"] as? Int) ?? 0)
            if let sessionId, !sessionId.isEmpty, processAlive(pid) { ids.insert(sessionId) }
        }
        return ids
    }

    // MARK: - Bounded reads

    private struct Header {
        let cwd: String?
        let title: String?
    }

    /// Première ligne `type:session` rencontrée dans la fenêtre de tête.
    private static func firstSessionHeader(url: URL) -> Header? {
        guard let data = readWindow(url: url, maxBytes: headBytes, fromEnd: false) else { return nil }
        for object in jsonLines(in: data) where (object["type"] as? String) == "session" {
            return Header(cwd: object["cwd"] as? String, title: object["title"] as? String)
        }
        return nil
    }

    /// Dernier `model` non vide dans la fenêtre de queue (le tour assistant le
    /// plus récent porte le modèle observé).
    private static func lastModel(url: URL) -> String? {
        guard let data = readWindow(url: url, maxBytes: tailBytes, fromEnd: true) else { return nil }
        var model: String?
        for object in jsonLines(in: data) {
            if let value = object["model"] as? String, !value.isEmpty { model = value }
        }
        return model
    }

    private static func readJSONObject(url: URL, maxBytes: Int) -> [String: Any]? {
        guard let data = readWindow(url: url, maxBytes: maxBytes, fromEnd: false),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func jsonLines(in data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var objects: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            objects.append(object)
        }
        return objects
    }

    /// Lit au plus `maxBytes` au début ou à la fin d'un fichier (jamais tout).
    private static func readWindow(url: URL, maxBytes: Int, fromEnd: Bool) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if fromEnd, size > UInt64(maxBytes) {
            try? handle.seek(toOffset: size - UInt64(maxBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        return try? handle.read(upToCount: maxBytes)
    }
}
