import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

/// Pins `CommandCodeSessionSource` : classification d'activité (jamais
/// « fermée »), dédup par id natif, filiation (`parentSessionId`) signalée,
/// ligne illégale sautée sans tuer le lot, et un répertoire absent rapporté —
/// jamais un faux zéro. Fixtures synthétiques en dossier temporaire : aucune
/// donnée vivante de Ben n'est approchée.
@Suite("Command Code session source")
struct CommandCodeSessionSourceTests {

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("commandcode-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Écrit un transcript minimal : en-tête `type:session` (cwd) + un tour
    /// assistant portant le modèle observé.
    @discardableResult
    private func writeTranscript(
        in directory: URL,
        id: String,
        cwd: String = "/Users/test/repo",
        model: String? = "deepseek/deepseek-v4-flash"
    ) throws -> URL {
        var lines = [
            #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-09-20T12:00:00.000Z","cwd":"\#(cwd)"}"#,
        ]
        if let model {
            lines.append(#"{"type":"message","id":"m1","parentId":null,"message":{"role":"assistant"},"model":"\#(model)"}"#)
        }
        let url = directory.appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeMeta(
        in directory: URL,
        id: String,
        title: String? = nil,
        model: String? = nil,
        parentId: String? = nil
    ) throws {
        var object: [String: Any] = [:]
        if let title { object["title"] = title }
        if let model { object["model"] = model }
        if let parentId {
            object["parentSessionId"] = parentId
            object["forkedAt"] = "2026-09-20T12:00:00.000Z"
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: directory.appendingPathComponent("\(id).meta.json"))
    }

    private func setModification(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func projectDirectory(in root: URL, named name: String = "users-test") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Tests

    @Test("Une activité fraîche est « en travail », une heure plus tôt « récente », plus ancienne « inconnue »")
    func activityClassification() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try projectDirectory(in: root)
        let now = Date()

        let fresh = try writeTranscript(in: project, id: "ses_fresh", cwd: "/Users/test/fresh")
        try writeMeta(in: project, id: "ses_fresh", title: "En cours", parentId: nil)
        try setModification(now.addingTimeInterval(-30), of: fresh)

        let older = try writeTranscript(in: project, id: "ses_old", cwd: "/Users/test/old")
        try setModification(now.addingTimeInterval(-3_600), of: older)

        let stale = try writeTranscript(in: project, id: "ses_stale", cwd: "/Users/test/stale")
        try setModification(now.addingTimeInterval(-3 * 24 * 3_600), of: stale)

        let source = CommandCodeSessionSource(
            projectsDirectory: root.path,
            trackerDirectory: root.appendingPathComponent("no-trackers").path,
            processAlive: { _ in false }
        )
        let report = await source.collect(limit: 50, now: now)

        #expect(report.failure == nil)
        #expect(report.observations.count == 3)
        #expect(report.observations.first { $0.id == "ses_fresh" }?.activity == .working)
        #expect(report.observations.first { $0.id == "ses_old" }?.activity == .recent)
        // Trop ancien pour prouver quoi que ce soit : jamais « fermée ».
        #expect(report.observations.first { $0.id == "ses_stale" }?.activity == .unknown)
        let freshObservation = try #require(report.observations.first { $0.id == "ses_fresh" })
        #expect(freshObservation.title == "En cours")
        #expect(freshObservation.directory == "/Users/test/fresh")
        #expect(freshObservation.model == "deepseek/deepseek-v4-flash")
    }

    @Test("Une même session vue dans deux dossiers n'est comptée qu'une fois")
    func deduplicationByNativeId() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = try projectDirectory(in: root, named: "alpha")
        let beta = try projectDirectory(in: root, named: "beta")
        try writeTranscript(in: alpha, id: "ses_dup")
        try writeTranscript(in: beta, id: "ses_dup")

        let source = CommandCodeSessionSource(
            projectsDirectory: root.path,
            trackerDirectory: root.appendingPathComponent("no-trackers").path,
            processAlive: { _ in false }
        )
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.observations.count == 1)
        #expect(report.observations.first?.id == "ses_dup")
    }

    @Test("Une session dérivée (parentSessionId) est signalée comme sous-session")
    func subagentFlag() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try projectDirectory(in: root)

        try writeTranscript(in: project, id: "ses_parent")
        try writeMeta(in: project, id: "ses_parent", title: "Session principale")
        try writeTranscript(in: project, id: "ses_child")
        try writeMeta(in: project, id: "ses_child", title: "Session dérivée", parentId: "ses_parent")

        let source = CommandCodeSessionSource(
            projectsDirectory: root.path,
            trackerDirectory: root.appendingPathComponent("no-trackers").path,
            processAlive: { _ in false }
        )
        let report = await source.collect(limit: 50, now: Date())

        let child = try #require(report.observations.first { $0.id == "ses_child" })
        #expect(child.isSubagent)
        #expect(report.observations.first { $0.id == "ses_parent" }?.isSubagent == false)
        #expect(SessionCounts.from(report.observations).subagents == 1)
    }

    @Test("Un traceur vivant (PID vérifié) marque la session « ouverte » ; un PID mort ne le fait pas")
    func livenessTracker() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try projectDirectory(in: root)
        let trackers = root.appendingPathComponent("trackers", isDirectory: true)
        try FileManager.default.createDirectory(at: trackers, withIntermediateDirectories: true)

        try writeTranscript(in: project, id: "ses_live")
        try writeMeta(in: project, id: "ses_live", title: "Vivante")
        let payload: [String: Any] = ["tool": "commandcode", "session_id": "ses_live", "pid": 4321]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: trackers.appendingPathComponent("commandcode-4321.json"))

        let live = CommandCodeSessionSource(
            projectsDirectory: root.path,
            trackerDirectory: trackers.path,
            processAlive: { $0 == 4321 }
        )
        let liveReport = await live.collect(limit: 50, now: Date())
        #expect(liveReport.observations.first?.activity == .open)

        let dead = CommandCodeSessionSource(
            projectsDirectory: root.path,
            trackerDirectory: trackers.path,
            processAlive: { _ in false }
        )
        let deadReport = await dead.collect(limit: 50, now: Date())
        // PID mort : pas d'état « ouvert » inventé — on retombe sur mtime.
        #expect(deadReport.observations.first?.activity != .open)
    }

    @Test("Une ligne illégale est sautée sans faire tomber le lot")
    func malformedRecordIsSkipped() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try projectDirectory(in: root)

        try writeTranscript(in: project, id: "ses_good")

        // En-tête valide puis une ligne illégale puis un tour valide : la
        // session reste lisible.
        let mixed = """
            {"type":"session","version":3,"id":"ses_mixed","timestamp":"2026-09-20T12:00:00.000Z","cwd":"/Users/test/mixed"}
            ceci n'est pas du JSON
            {"type":"message","id":"m1","message":{"role":"assistant"},"model":"deepseek/deepseek-v4-flash"}
            """
        try mixed.write(to: project.appendingPathComponent("ses_mixed.jsonl"), atomically: true, encoding: .utf8)

        // Un fichier entièrement illégal n'est pas une session : il disparaît.
        try "pas de session ici\n".write(
            to: project.appendingPathComponent("ses_garbage.jsonl"), atomically: true, encoding: .utf8
        )

        let source = CommandCodeSessionSource(
            projectsDirectory: root.path,
            trackerDirectory: root.appendingPathComponent("no-trackers").path,
            processAlive: { _ in false }
        )
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.failure == nil)
        #expect(report.observations.map(\.id).sorted() == ["ses_good", "ses_mixed"])
    }

    @Test("Un répertoire de sessions absent est rapporté, jamais un faux zéro")
    func missingDirectoryReportsFailure() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = CommandCodeSessionSource(
            projectsDirectory: root.appendingPathComponent("absent").path,
            trackerDirectory: root.appendingPathComponent("no-trackers").path,
            processAlive: { _ in false }
        )
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.failure != nil)
        #expect(report.observations.isEmpty)
    }
}
