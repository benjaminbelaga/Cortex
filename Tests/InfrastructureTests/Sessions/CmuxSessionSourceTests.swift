import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

/// Pins `CmuxSessionSource` : un pane terminal présent dans l'état de session est
/// « ouvert » tant que l'état est frais, « inconnu » sinon (jamais « fermé ») ;
/// dédup par pane ; panes non-terminaux écartés ; état absent rapporté.
/// Fixtures synthétiques : aucune donnée vivante de Ben n'est lue.
@Suite("cmux session source")
struct CmuxSessionSourceTests {

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func terminalPanel(surface: String, title: String, directory: String) -> [String: Any] {
        [
            "id": surface,
            "stableSurfaceId": surface,
            "type": "terminal",
            "title": title,
            "directory": directory,
            "terminal": ["workingDirectory": directory, "isRemoteTerminal": false],
        ]
    }

    private func browserPanel(surface: String, title: String) -> [String: Any] {
        ["id": surface, "stableSurfaceId": surface, "type": "browser", "title": title]
    }

    private func workspace(
        id: String,
        directory: String,
        title: String,
        processTitle: String? = nil,
        panels: [[String: Any]]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "workspaceId": id,
            "currentDirectory": directory,
            "customTitle": title,
            "panels": panels,
        ]
        if let processTitle { object["processTitle"] = processTitle }
        return object
    }

    @discardableResult
    private func writeSnapshot(at url: URL, workspaces: [[String: Any]]) throws -> URL {
        let root: [String: Any] = [
            "createdAt": Date().timeIntervalSince1970,
            "version": 1,
            "windows": [[
                "windowId": "WIN-1",
                "tabManager": ["selectedWorkspaceIndex": 0, "workspaces": workspaces],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try data.write(to: url)
        return url
    }

    // MARK: - Tests

    @Test("Un pane terminal de l'état vivant est une session ouverte, avec son dossier et son modèle observés")
    func openTerminalPanes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("session-com.cmuxterm.app.json")
        try writeSnapshot(at: snapshot, workspaces: [
            workspace(
                id: "WS-1", directory: "/Users/test/one", title: "studio",
                processTitle: "⌘ Command Code · yoyaku · deepseek-v4-flash-(latest)",
                panels: [
                    terminalPanel(surface: "S-1", title: "cmd · gpt-4", directory: "/Users/test/one"),
                    browserPanel(surface: "S-2", title: "Analyse en ligne"),
                ]
            ),
            workspace(
                id: "WS-2", directory: "/Users/test/two", title: "odoo",
                panels: [terminalPanel(surface: "S-3", title: "~", directory: "/Users/test/two")]
            ),
        ])

        let source = CmuxSessionSource(snapshotPath: snapshot.path)
        #expect(await source.isDetected())
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.failure == nil)
        // Le pane « browser » n'est pas une session terminal.
        #expect(report.observations.map(\.id).sorted() == ["S-1", "S-3"])
        let first = try #require(report.observations.first { $0.id == "S-1" })
        #expect(first.activity == .open)
        #expect(first.directory == "/Users/test/one")
        #expect(first.model == "gpt-4")
        let plain = try #require(report.observations.first { $0.id == "S-3" })
        #expect(plain.directory == "/Users/test/two")
        #expect(plain.model == nil)
    }

    @Test("Un état trop vieux pour prouver la vie reste « inconnu », jamais « fermé »")
    func staleSnapshotIsUnknown() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("session-com.cmuxterm.app.json")
        try writeSnapshot(at: snapshot, workspaces: [
            workspace(id: "WS-1", directory: "/Users/test", title: "vieux", panels: [
                terminalPanel(surface: "S-1", title: "~", directory: "/Users/test"),
            ]),
        ])
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3 * 3_600)], ofItemAtPath: snapshot.path
        )

        let source = CmuxSessionSource(snapshotPath: snapshot.path)
        let report = await source.collect(limit: 50, now: now)

        #expect(report.observations.first?.activity == .unknown)
        #expect(SessionCounts.from(report.observations).open == 0)
    }

    @Test("Un pane vu dans deux workspaces n'est compté qu'une fois")
    func deduplicationByPaneId() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("session-com.cmuxterm.app.json")
        try writeSnapshot(at: snapshot, workspaces: [
            workspace(id: "WS-1", directory: "/a", title: "a", panels: [
                terminalPanel(surface: "S-dup", title: "~", directory: "/a"),
            ]),
            workspace(id: "WS-2", directory: "/b", title: "b", panels: [
                terminalPanel(surface: "S-dup", title: "~", directory: "/b"),
            ]),
        ])

        let source = CmuxSessionSource(snapshotPath: snapshot.path)
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.observations.map(\.id) == ["S-dup"])
    }

    @Test("Un état de session absent est rapporté, jamais un faux zéro")
    func missingSnapshotReportsFailure() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CmuxSessionSource(snapshotPath: root.appendingPathComponent("absent.json").path)

        #expect(await source.isDetected() == false)
        let report = await source.collect(limit: 50, now: Date())

        #expect(report.failure != nil)
        #expect(report.observations.isEmpty)
    }
}
