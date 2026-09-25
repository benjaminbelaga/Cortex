import Foundation
import SQLite3
import Domain

/// Source de sessions OpenCode — lecture seule, bornée, sans jamais lancer un
/// outil pour le détecter.
///
/// Deux signaux, jamais confondus :
/// 1. **Liveness** : les fichiers `opencode-<pid>.json` écrits par le plugin de
///    suivi (`session.created/updated/idle`), dont le PID est vérifié vivant.
///    La fraîcheur du traceur distingue ce qui **travaille** (réécrit < 2 min →
///    `.working`) de ce qui est simplement **ouvert** (processus vivant sans
///    activité récente → `.open`). Leur contenu porte la session (titre, dossier,
///    agent, modèle/backend observé).
/// 2. **Historique local** : la base SQLite d'OpenCode (`session`, lue en
///    READ-ONLY). Les lignes déjà vues en liveness sont conservées telles
///    quelles ; les autres deviennent `.working` (activité < 2 min) ou
///    `.recent` (fenêtre 24 h). Aucune ligne n'est jamais présentée comme
///    « fermée » : une activité trop ancienne reste `.unknown`.
///
/// Un échec de la base est rapporté (`SessionSourceReport.failure`) et n'efface
/// pas les observations de liveness — jamais de faux zéro.
public struct OpenCodeSessionSource: SessionSource {

    public let toolId = "opencode-go"

    /// Fenêtre d'historique lue dans la base locale.
    public static let historyWindow: TimeInterval = 24 * 60 * 60
    /// Une session mise à jour dans ce délai est « en travail » (activité
    /// récente) même sans processus identifiable.
    public static let workingWindow: TimeInterval = 120

    private let databasePath: String
    private let trackerDirectory: String
    private let processAlive: @Sendable (Int32) -> Bool

    public init(
        databasePath: String = OpenCodeSessionSource.defaultDatabasePath(),
        trackerDirectory: String = OpenCodeSessionSource.defaultTrackerDirectory(),
        processAlive: @escaping @Sendable (Int32) -> Bool = OpenCodeSessionSource.defaultProcessAlive
    ) {
        self.databasePath = databasePath
        self.trackerDirectory = trackerDirectory
        self.processAlive = processAlive
    }

    // MARK: - Defaults

    public static func defaultDatabasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".local/share")
        return (dataHome as NSString).appendingPathComponent("opencode/opencode.db")
    }

    public static func defaultTrackerDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let base = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("tmux-assistant-resurrect")
    }

    /// `kill(pid, 0)` : vivant si le signal passe, ou si EPERM (processus d'un
    /// autre utilisateur — il existe quand même).
    public static let defaultProcessAlive: @Sendable (Int32) -> Bool = { pid in
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - SessionSource

    public func isDetected() async -> Bool {
        FileManager.default.fileExists(atPath: databasePath)
            || !trackerFiles().isEmpty
    }

    public func collect(limit: Int, now: Date) async -> SessionSourceReport {
        var bySession: [String: SessionObservation] = [:]
        var failure: String?

        // 1) Sessions vivantes (fichiers de suivi + PID vérifié). Le traceur est
        //    réécrit à chaque `session.updated`/`session.idle` : frais (< 2 min),
        //    la session travaille ; sinon elle est ouverte mais au repos.
        for tracker in liveTrackers(now: now) {
            let isFresh = tracker.updatedAt.map { now.timeIntervalSince($0) < Self.workingWindow } ?? false
            bySession[tracker.sessionId] = SessionObservation(
                id: tracker.sessionId,
                toolId: toolId,
                title: tracker.title,
                directory: tracker.directory,
                model: tracker.model,
                updatedAt: tracker.updatedAt,
                activity: isFresh ? .working : .open,
                isSubagent: tracker.parentId != nil
            )
        }

        // 2) Historique local (READ-ONLY), pour les sessions que le liveness ne
        //    couvre pas (processus terminé depuis peu, suivi désactivé).
        do {
            let cutoffMs = Int64((now.timeIntervalSince1970 - Self.historyWindow) * 1000)
            let rows = try SQLiteReadOnly.rows(
                databasePath: databasePath,
                sql: """
                    SELECT id, parent_id, directory, title, model, time_updated,
                           tokens_input, tokens_output
                    FROM session
                    WHERE time_updated >= ?
                    ORDER BY time_updated DESC
                    LIMIT ?
                    """,
                bindings: [.int(cutoffMs), .int(Int64(limit))],
                limit: limit
            )
            for row in rows {
                guard let id = row["id"] as? String, bySession[id] == nil else { continue }
                let updatedMs = (row["time_updated"] as? Int64) ?? 0
                let updated = updatedMs > 0 ? Date(timeIntervalSince1970: Double(updatedMs) / 1000) : nil
                let tokens = ((row["tokens_input"] as? Int64) ?? 0) + ((row["tokens_output"] as? Int64) ?? 0)
                let isFresh = updated.map { now.timeIntervalSince($0) < Self.workingWindow } ?? false
                // Une session sans aucun jeton et sans activité fraîche est un
                // conteneur vide (OpenCode en crée à chaque lancement) — la
                // compter serait un faux positif, la montrer un faux zéro.
                guard tokens > 0 || isFresh else { continue }
                bySession[id] = SessionObservation(
                    id: id,
                    toolId: toolId,
                    title: row["title"] as? String,
                    directory: row["directory"] as? String,
                    model: row["model"] as? String,
                    updatedAt: updated,
                    activity: isFresh ? .working : .recent,
                    isSubagent: (row["parent_id"] as? String)?.isEmpty == false
                )
            }
        } catch {
            failure = "base locale OpenCode illisible (\(error)) — sessions vivantes uniquement"
        }

        let observations = bySession.values.sorted { lhs, rhs in
            let lhsRank = Self.rank(lhs.activity)
            let rhsRank = Self.rank(rhs.activity)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        return SessionSourceReport(toolId: toolId, observations: observations, failure: failure)
    }

    private static func rank(_ activity: SessionObservation.Activity) -> Int {
        switch activity {
        case .working: 0
        case .open: 1
        case .recent: 2
        case .unknown: 3
        }
    }

    // MARK: - Liveness files

    private struct Tracker {
        let sessionId: String
        let pid: Int32
        let title: String?
        let directory: String?
        let model: String?
        let parentId: String?
        let updatedAt: Date?
    }

    private func trackerFiles() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: trackerDirectory),
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries.filter { $0.lastPathComponent.hasPrefix("opencode-") && $0.pathExtension == "json" }
    }

    private func liveTrackers(now: Date) -> [Tracker] {
        var trackers: [Tracker] = []
        for url in trackerFiles() {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = root["session_id"] as? String,
                  !sessionId.isEmpty else { continue }
            let pid = Int32((root["pid"] as? Int) ?? 0)
            guard processAlive(pid) else { continue }
            let session = root["session"] as? [String: Any]
            let modelInfo = session?["model"] as? [String: Any]
            let providerId = modelInfo?["providerID"] as? String
            let modelId = modelInfo?["id"] as? String
            let model = [providerId, modelId].compactMap { $0 }.joined(separator: "/")
            trackers.append(Tracker(
                sessionId: sessionId,
                pid: pid,
                title: (session?["title"] as? String) ?? (root["title"] as? String),
                directory: (session?["directory"] as? String) ?? (root["cwd"] as? String),
                model: model.isEmpty ? nil : model,
                parentId: (session?["parentID"] as? String),
                updatedAt: Self.parseDate(root["timestamp"] as? String) ?? now
            ))
        }
        return trackers
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

// MARK: - SQLite (lecture seule)

/// Requête SQLite en lecture seule, bornée et minimale : trois types suffisent
/// (texte, entier, nul) et aucune écriture n'est possible.
enum SQLiteReadOnly {

    enum Binding {
        case int(Int64)
        case text(String)
    }

    enum Failure: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)

        var description: String {
            switch self {
            case let .open(message): "ouverture: \(message)"
            case let .prepare(message): "préparation: \(message)"
            case let .step(message): "lecture: \(message)"
            }
        }
    }

    static func rows(
        databasePath: String,
        sql: String,
        bindings: [Binding] = [],
        limit: Int
    ) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw Failure.open("fichier absent: \(databasePath)")
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "handle nul"
            if let handle { sqlite3_close(handle) }
            throw Failure.open(message)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case let .int(value):
                sqlite3_bind_int64(statement, position, value)
            case let .text(value):
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            }
        }

        var result: [[String: Any]] = []
        let columnCount = sqlite3_column_count(statement)
        while result.count < limit, sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) {
                        row[name] = String(cString: text)
                    }
                case SQLITE_NULL:
                    row[name] = nil
                default:
                    row[name] = nil
                }
            }
            result.append(row)
        }
        return result
    }
}

/// SQLite exige un destructeur explicite pour les textes liés.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
