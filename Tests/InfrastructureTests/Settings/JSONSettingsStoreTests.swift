import Testing
import Foundation
@testable import Infrastructure

@Suite("JSONSettingsStore Tests")
struct JSONSettingsStoreTests {

    private func makeStore(initialJSON: String? = nil) throws -> (JSONSettingsStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudebar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileURL = tempDir.appendingPathComponent("settings.json")
        if let json = initialJSON {
            try json.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let store = JSONSettingsStore(fileURL: fileURL)
        return (store, tempDir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Flat Key Read/Write

    @Test
    func `read returns nil when file does not exist`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let value: String? = store.read(key: "someKey")
        #expect(value == nil)
    }

    @Test
    func `write creates file and stores value`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        store.write(value: "hello", key: "greeting")

        let result: String? = store.read(key: "greeting")
        #expect(result == "hello")
    }

    @Test
    func `write preserves existing keys`() throws {
        let json = """
        {
            "existing": "value"
        }
        """
        let (store, dir) = try makeStore(initialJSON: json)
        defer { cleanup(dir) }

        store.write(value: "new", key: "added")

        let existing: String? = store.read(key: "existing")
        let added: String? = store.read(key: "added")
        #expect(existing == "value")
        #expect(added == "new")
    }

    @Test
    func `write nil removes key`() throws {
        let json = """
        {
            "toRemove": "goodbye"
        }
        """
        let (store, dir) = try makeStore(initialJSON: json)
        defer { cleanup(dir) }

        store.write(value: nil, key: "toRemove")

        let result: String? = store.read(key: "toRemove")
        #expect(result == nil)
    }

    // MARK: - Nested Key (Dot-Notation) Read/Write

    @Test
    func `read nested key from existing JSON`() throws {
        let json = """
        {
            "app": {
                "themeMode": "dark"
            }
        }
        """
        let (store, dir) = try makeStore(initialJSON: json)
        defer { cleanup(dir) }

        let result: String? = store.read(key: "app.themeMode")
        #expect(result == "dark")
    }

    @Test
    func `write nested key creates intermediate dictionaries`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        store.write(value: "cli", key: "claude.probeMode")

        let result: String? = store.read(key: "claude.probeMode")
        #expect(result == "cli")
    }

    @Test
    func `write nested key preserves sibling keys`() throws {
        let json = """
        {
            "app": {
                "themeMode": "dark",
                "overviewMode": true
            }
        }
        """
        let (store, dir) = try makeStore(initialJSON: json)
        defer { cleanup(dir) }

        store.write(value: "light", key: "app.themeMode")

        let theme: String? = store.read(key: "app.themeMode")
        let overview: Bool? = store.read(key: "app.overviewMode")
        #expect(theme == "light")
        #expect(overview == true)
    }

    @Test
    func `deeply nested key works`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        store.write(value: true, key: "providers.claude.isEnabled")

        let result: Bool? = store.read(key: "providers.claude.isEnabled")
        #expect(result == true)
    }

    // MARK: - Type Support

    @Test
    func `reads and writes Bool values`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        store.write(value: false, key: "app.enabled")

        let result: Bool? = store.read(key: "app.enabled")
        #expect(result == false)
    }

    @Test
    func `reads and writes Int values`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        store.write(value: 42, key: "port")

        let result: Int? = store.read(key: "port")
        #expect(result == 42)
    }

    @Test
    func `reads and writes Double values`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        store.write(value: 3.14, key: "budget")

        let result: Double? = store.read(key: "budget")
        #expect(result == 3.14)
    }

    @Test
    func `reads and writes array values`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        store.write(value: ["us-east-1", "eu-west-1"], key: "bedrock.regions")

        let result: [String]? = store.read(key: "bedrock.regions")
        #expect(result == ["us-east-1", "eu-west-1"])
    }

    // MARK: - Persistence

    @Test
    func `values persist across separate store instances`() throws {
        let (store1, dir) = try makeStore()
        defer { cleanup(dir) }

        store1.write(value: "persisted", key: "app.test")

        let store2 = JSONSettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        let result: String? = store2.read(key: "app.test")
        #expect(result == "persisted")
    }

    // MARK: - Resilience

    @Test
    func `handles malformed JSON gracefully`() throws {
        let (store, dir) = try makeStore(initialJSON: "not valid json {{{")
        defer { cleanup(dir) }

        let result: String? = store.read(key: "anything")
        #expect(result == nil)
    }

    @Test
    func `write to malformed file replaces with valid JSON`() throws {
        let (store, dir) = try makeStore(initialJSON: "broken")
        defer { cleanup(dir) }

        store.write(value: "fixed", key: "status")

        let result: String? = store.read(key: "status")
        #expect(result == "fixed")
    }

    @Test
    func `creates parent directory if needed`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudebar-test-\(UUID().uuidString)")
        let deepPath = tempDir
            .appendingPathComponent("nested")
            .appendingPathComponent("dir")
            .appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = JSONSettingsStore(fileURL: deepPath)
        store.write(value: "created", key: "test")

        let result: String? = store.read(key: "test")
        #expect(result == "created")
    }

    // MARK: - readAll

    @Test
    func `readAll returns full dictionary`() throws {
        let json = """
        {
            "app": { "theme": "dark" },
            "version": 1
        }
        """
        let (store, dir) = try makeStore(initialJSON: json)
        defer { cleanup(dir) }

        let all = store.readAll()
        #expect(all["version"] as? Int == 1)
        #expect((all["app"] as? [String: Any])?["theme"] as? String == "dark")
    }

    @Test
    func `readAll returns empty dict when no file`() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let all = store.readAll()
        #expect(all.isEmpty)
    }
}
