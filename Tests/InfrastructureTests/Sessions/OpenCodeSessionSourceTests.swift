import Testing
import Foundation
import SQLite3

/// Copie obligatoire côté SQLite : le pont String→CString de Swift est
/// temporaire, un destructeur nil laisserait un pointeur libéré.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
@testable import Infrastructure
@testable import Domain

/// Pins `OpenCodeSessionSource` : liveness (fichier + PID vérifié) ≠ historique
/// (base locale), dédup par session, et une base illisible ne produit jamais un
/// faux zéro.
@Suite("OpenCode session source")
struct OpenCodeSessionSourceTests {

    private struct Row {
        let id: String
        var parent: String? = nil
        var directory = "/Users/test/repo"
        var title = "Session"
        var model: String? = "ollama-cloud/deepseek-v4.1-flash"
        var updatedMs: Int64
        var tokensIn: Int64 = 100
        var tokensOut: Int64 = 50
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDatabase(at url: URL, rows: [Row]) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open(url.path, &handle)
        #expect(openResult == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE session (
                id text PRIMARY KEY,
                parent_id text,
                directory text NOT NULL,
                title text NOT NULL,
                model text,
                time_updated integer NOT NULL,
                tokens_input integer NOT NULL DEFAULT 0,
                tokens_output integer NOT NULL DEFAULT 0
            );
            """
        sqlite3_exec(handle, schema, nil, nil, nil)

        for row in rows {
            var statement: OpaquePointer?
            let insert = """
                INSERT INTO session (id, parent_id, directory, title, model, time_updated, tokens_input, tokens_output)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
            guard sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, row.id, -1, SQLITE_TRANSIENT)
            if let parent = row.parent {
                sqlite3_bind_text(statement, 2, parent, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_text(statement, 3, row.directory, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, row.title, -1, SQLITE_TRANSIENT)
            if let model = row.model {
                sqlite3_bind_text(statement, 5, model, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_bind_int64(statement, 6, row.updatedMs)
            sqlite3_bind_int64(statement, 7, row.tokensIn)
            sqlite3_bind_int64(statement, 8, row.tokensOut)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    private func writeTracker(
        in directory: URL,
        pid: Int,
        sessionId: String,
        title: String,
        parentId: String? = nil
    ) throws {
        var session: [String: Any] = [
            "id": sessionId,
            "directory": "/Users/test/live",
            "title": title,
            "model": ["providerID": "ollama-cloud", "id": "deepseek-v4.1-flash"],
        ]
        if let parentId { session["parentID"] = parentId }
        let payload: [String: Any] = [
            "tool": "opencode",
            "session_id": sessionId,
            "pid": pid,
            "cwd": "/Users/test/live",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "session": session,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: directory.appendingPathComponent("opencode-\(pid).json"))
    }

    // MARK: - Tests

    @Test("A live tracker with an alive PID is an open session carrying its observed backend")
    func liveTrackerIsOpen() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTracker(in: dir, pid: 42, sessionId: "ses_live", title: "Correction POS")

        let source = OpenCodeSessionSource(
            databasePath: dir.appendingPathComponent("absent.db").path,
            trackerDirectory: dir.path,
            processAlive: { $0 == 42 }
        )
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.observations.count == 1)
        let observation = try #require(report.observations.first)
        #expect(observation.activity == .open)
        #expect(observation.id == "ses_live")
        #expect(observation.title == "Correction POS")
        #expect(observation.model == "ollama-cloud/deepseek-v4.1-flash")
        // Une base absente est rapportée, sans effacer la session vivante.
        #expect(report.failure != nil)
    }

    @Test("A dead PID is not an open session")
    func deadPidIsIgnored() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTracker(in: dir, pid: 43, sessionId: "ses_dead", title: "Terminée")

        let source = OpenCodeSessionSource(
            databasePath: dir.appendingPathComponent("absent.db").path,
            trackerDirectory: dir.path,
            processAlive: { _ in false }
        )
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.observations.isEmpty)
    }

    @Test("Local history classifies fresh activity as working and older usage as recent")
    func historyClassification() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = dir.appendingPathComponent("opencode.db")
        let now = Date()
        let fresh = Int64(now.timeIntervalSince1970 * 1000) - 30_000      // il y a 30 s
        let older = Int64(now.timeIntervalSince1970 * 1000) - 3_600_000   // il y a 1 h
        let empty = Int64(now.timeIntervalSince1970 * 1000) - 7_200_000   // 2 h, aucun jeton
        try makeDatabase(at: database, rows: [
            Row(id: "ses_fresh", title: "En cours", updatedMs: fresh, tokensIn: 0, tokensOut: 0),
            Row(id: "ses_old", title: "Plus tôt", updatedMs: older),
            Row(id: "ses_empty", title: "New session", updatedMs: empty, tokensIn: 0, tokensOut: 0),
        ])

        let source = OpenCodeSessionSource(
            databasePath: database.path,
            trackerDirectory: dir.appendingPathComponent("no-trackers").path,
            processAlive: { _ in false }
        )
        let report = await source.collect(limit: 50, now: now)

        #expect(report.failure == nil)
        #expect(report.observations.map(\.id).sorted() == ["ses_fresh", "ses_old"])
        #expect(report.observations.first { $0.id == "ses_fresh" }?.activity == .working)
        #expect(report.observations.first { $0.id == "ses_old" }?.activity == .recent)
    }

    @Test("A session seen in both signals appears once, as open, and subagents are flagged")
    func deduplicationAndSubagents() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = dir.appendingPathComponent("opencode.db")
        let now = Date()
        let updated = Int64(now.timeIntervalSince1970 * 1000) - 60_000
        try makeDatabase(at: database, rows: [
            Row(id: "ses_both", title: "DB title", updatedMs: updated),
            Row(id: "ses_child", parent: "ses_both", title: "Sous-agent", updatedMs: updated),
        ])
        try writeTracker(in: dir, pid: 44, sessionId: "ses_both", title: "Live title")
        try writeTracker(in: dir, pid: 45, sessionId: "ses_child", title: "Sous-agent", parentId: "ses_both")

        let source = OpenCodeSessionSource(
            databasePath: database.path,
            trackerDirectory: dir.path,
            processAlive: { $0 == 44 || $0 == 45 }
        )
        let report = await source.collect(limit: 50, now: now)

        #expect(report.observations.count == 2)
        let both = try #require(report.observations.first { $0.id == "ses_both" })
        #expect(both.activity == .open)
        #expect(both.title == "Live title")   // le liveness, plus riche, gagne
        #expect(both.isSubagent == false)

        let counts = SessionCounts.from(report.observations)
        #expect(counts.open == 1)             // le sous-agent n'est pas compté comme session
        #expect(counts.subagents == 1)
    }

    @Test("An unreadable database reports a failure without inventing sessions")
    func unreadableDatabaseNeverZeroes() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("broken.db")
        try Data("not a database".utf8).write(to: broken)

        let source = OpenCodeSessionSource(
            databasePath: broken.path,
            trackerDirectory: dir.path,
            processAlive: { _ in false }
        )
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.failure != nil)
        #expect(report.observations.isEmpty)
    }
}
