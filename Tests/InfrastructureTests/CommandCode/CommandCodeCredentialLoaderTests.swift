import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("CommandCodeCredentialLoader Tests")
struct CommandCodeCredentialLoaderTests {

    // MARK: - Test Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("commandcode-credential-loader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func writeAuthFile(at directory: URL, json: String) throws {
        let commandCodeDir = directory.appendingPathComponent(".commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: commandCodeDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: commandCodeDir.appendingPathComponent("auth.json"))
    }

    // MARK: - Loading Tests

    @Test
    func `loads api key from auth file`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"{ "apiKey": "user_abc" }"#)

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])

        #expect(loader.loadAPIKey() == "user_abc")
    }

    @Test
    func `environment variable wins over the auth file`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"{ "apiKey": "user_file" }"#)

        let loader = CommandCodeCredentialLoader(
            homeDirectory: tempDir.path,
            environment: ["COMMAND_CODE_API_KEY": "user_env"]
        )

        #expect(loader.loadAPIKey() == "user_env")
    }

    @Test
    func `falls back to the alternate environment variable`() {
        let loader = CommandCodeCredentialLoader(environment: ["COMMANDCODE_API_KEY": "user_alt"])

        #expect(loader.loadAPIKey() == "user_alt")
    }

    @Test
    func `returns nil when the auth file is missing`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])

        #expect(loader.loadAPIKey() == nil)
    }

    @Test
    func `returns nil for an empty api key`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"{ "apiKey": "   " }"#)

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])

        #expect(loader.loadAPIKey() == nil)
    }

    @Test
    func `returns nil when the auth file is not a JSON object`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"["user_abc"]"#)

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])

        #expect(loader.loadAPIKey() == nil)
    }

    @Test
    func `trims whitespace around the file key`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"{ "apiKey": "  user_abc\n" }"#)

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])

        #expect(loader.loadAPIKey() == "user_abc")
    }

    @Test
    func `auth file path lives under the commandcode directory`() {
        let loader = CommandCodeCredentialLoader(homeDirectory: "/tmp/home", environment: [:])

        #expect(loader.authFilePath == "/tmp/home/.commandcode/auth.json")
    }

    // MARK: - Failover pool

    private func writePoolFile(at directory: URL, json: String) throws {
        let commandCodeDir = directory.appendingPathComponent(".commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: commandCodeDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: commandCodeDir.appendingPathComponent("auth-pool.json"))
    }

    @Test
    func `pool is the primary first, then siblings deduped by key`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"{ "apiKey": "user_primary" }"#)
        try writePoolFile(at: tempDir, json: #"""
        { "accounts": [
            { "label": "compte-4", "key": "user_sib1" },
            { "label": "principal précédent", "key": "user_primary" },
            { "label": "compte principal précédent", "key": "user_sib2" }
        ] }
        """#)

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])
        let pool = loader.loadPool()

        // The sibling that repeats the primary key is dropped (dedupe by key);
        // the diacritic label folds to a stable ASCII slot.
        #expect(pool.map(\.slot) == ["cli", "pool:compte-4", "pool:compte-principal-precedent"])
        #expect(pool.map(\.key) == ["user_primary", "user_sib1", "user_sib2"])
        #expect(pool.count == 3)
        #expect(pool.first?.label == nil)
        #expect(pool[1].label == "compte-4")
    }

    @Test
    func `pool env key wins and stays a single entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"{ "apiKey": "user_primary" }"#)
        try writePoolFile(at: tempDir, json: #"{ "accounts": [{ "label": "compte-4", "key": "user_sib1" }] }"#)

        let loader = CommandCodeCredentialLoader(
            homeDirectory: tempDir.path,
            environment: ["COMMAND_CODE_API_KEY": "user_env"]
        )
        let pool = loader.loadPool()

        #expect(pool.map(\.slot) == ["env"])
        #expect(pool.first?.key == "user_env")
    }

    @Test
    func `pool without the pool file returns the primary only`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"{ "apiKey": "user_primary" }"#)

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])

        #expect(loader.loadPool().map(\.slot) == ["cli"])
    }

    @Test
    func `pool tolerates a bare array and skips empty keys`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: #"{ "apiKey": "user_primary" }"#)
        try writePoolFile(at: tempDir, json: #"""
        [ { "label": "compte-4", "key": "user_sib1" },
          { "label": "vide", "key": "   " } ]
        """#)

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])

        #expect(loader.loadPool().map(\.key) == ["user_primary", "user_sib1"])
    }

    @Test
    func `pool without any credential is empty`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = CommandCodeCredentialLoader(homeDirectory: tempDir.path, environment: [:])

        #expect(loader.loadPool().isEmpty)
    }
}
