import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("OpenCodeCredentialLoader Tests")
struct OpenCodeCredentialLoaderTests {

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-credential-loader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Writes `<dataDir>/opencode/auth.json` — the layout opencode uses under `$XDG_DATA_HOME`.
    private func writeAuthFile(dataDirectory: URL, json: [String: Any]) throws {
        let dir = dataDirectory.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: dir.appendingPathComponent("auth.json"))
    }

    // MARK: - Path resolution

    @Test
    func `defaults to ~/.local/share/opencode/auth.json`() {
        let loader = OpenCodeCredentialLoader(homeDirectory: "/Users/alice", environment: [:])
        #expect(loader.authFilePath == "/Users/alice/.local/share/opencode/auth.json")
    }

    @Test
    func `honors XDG_DATA_HOME`() {
        let loader = OpenCodeCredentialLoader(
            homeDirectory: "/Users/alice",
            environment: ["XDG_DATA_HOME": "/custom/data"]
        )
        #expect(loader.authFilePath == "/custom/data/opencode/auth.json")
    }

    // MARK: - Key resolution

    @Test
    func `loads api key from opencode-go entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeAuthFile(dataDirectory: tempDir, json: [
            "opencode-go": ["type": "api", "key": "go-key-123"]
        ])

        let loader = OpenCodeCredentialLoader(environment: ["XDG_DATA_HOME": tempDir.path])

        #expect(loader.loadAPIKey() == "go-key-123")
    }

    @Test
    func `falls back to shared opencode zen entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeAuthFile(dataDirectory: tempDir, json: [
            "anthropic": ["type": "oauth", "access": "a", "refresh": "r", "expires": 0],
            "opencode": ["type": "api", "key": "zen-key-456"]
        ])

        let loader = OpenCodeCredentialLoader(environment: ["XDG_DATA_HOME": tempDir.path])

        #expect(loader.loadAPIKey() == "zen-key-456")
    }

    @Test
    func `prefers opencode-go entry over opencode entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeAuthFile(dataDirectory: tempDir, json: [
            "opencode": ["type": "api", "key": "zen-key"],
            "opencode-go": ["type": "api", "key": "go-key"]
        ])

        let loader = OpenCodeCredentialLoader(environment: ["XDG_DATA_HOME": tempDir.path])

        #expect(loader.loadAPIKey() == "go-key")
    }

    @Test
    func `OPENCODE_API_KEY env var wins over auth file`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeAuthFile(dataDirectory: tempDir, json: [
            "opencode-go": ["type": "api", "key": "file-key"]
        ])

        let loader = OpenCodeCredentialLoader(
            environment: ["XDG_DATA_HOME": tempDir.path, "OPENCODE_API_KEY": "env-key"]
        )

        #expect(loader.loadAPIKey() == "env-key")
    }

    @Test
    func `returns nil when auth file missing`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = OpenCodeCredentialLoader(environment: ["XDG_DATA_HOME": tempDir.path])

        #expect(loader.loadAPIKey() == nil)
    }

    @Test
    func `returns nil when entries have no usable key`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeAuthFile(dataDirectory: tempDir, json: [
            "opencode": ["type": "api", "key": ""],
            "openai": ["type": "api", "key": "unrelated"]
        ])

        let loader = OpenCodeCredentialLoader(environment: ["XDG_DATA_HOME": tempDir.path])

        #expect(loader.loadAPIKey() == nil)
    }

    @Test
    func `returns nil when auth file is not valid JSON`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dir = tempDir.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("auth.json"))

        let loader = OpenCodeCredentialLoader(environment: ["XDG_DATA_HOME": tempDir.path])

        #expect(loader.loadAPIKey() == nil)
    }

    // MARK: - Pool (failover SSOT)

    /// Writes `<home>/.config/opencode/failover-ssot.json` with slot→label mapping.
    private func writeSsot(home: URL, slots: [String] = ["opencode-go", "opencode"]) throws {
        let dir = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let accounts = slots.enumerated().map { i, slot in
            ["slot": slot, "label": "compte \(i + 1)", "workspace": "wrk_test\(i)"]
        }
        let ssot: [String: Any] = ["version": 1, "tier1": ["slots": slots, "accounts": accounts]]
        let data = try JSONSerialization.data(withJSONObject: ssot)
        try data.write(to: dir.appendingPathComponent("failover-ssot.json"))
    }

    @Test
    func `loadPool returns SSOT-labeled entries in slot order`() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAuthFile(dataDirectory: home.appendingPathComponent(".local/share"), json: [
            "opencode": ["type": "api", "key": "key-B"],
            "opencode-go": ["type": "api", "key": "key-A"],
        ])
        try writeSsot(home: home)

        let loader = OpenCodeCredentialLoader(homeDirectory: home.path, environment: [:])
        let pool = loader.loadPool()

        #expect(pool.map(\.slot) == ["opencode-go", "opencode"])
        #expect(pool.map(\.label) == ["compte 1", "compte 2"])
        #expect(pool.map(\.key) == ["key-A", "key-B"])
        #expect(loader.loadAPIKey() == "key-A")
    }

    @Test
    func `loadPool falls back to positional labels without SSOT`() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAuthFile(dataDirectory: home.appendingPathComponent(".local/share"), json: [
            "opencode-go": ["type": "api", "key": "key-A"],
            "opencode": ["type": "api", "key": "key-B"],
        ])

        let loader = OpenCodeCredentialLoader(homeDirectory: home.path, environment: [:])
        let pool = loader.loadPool()

        #expect(pool.map(\.label) == ["compte 1", "compte 2"])
    }

    @Test
    func `loadPool is single unlabeled entry for env key`() {
        let loader = OpenCodeCredentialLoader(
            homeDirectory: "/nonexistent/home",
            environment: ["OPENCODE_API_KEY": "env-key"]
        )
        let pool = loader.loadPool()

        #expect(pool.count == 1)
        #expect(pool.first?.label == nil)
        #expect(pool.first?.key == "env-key")
    }
}
