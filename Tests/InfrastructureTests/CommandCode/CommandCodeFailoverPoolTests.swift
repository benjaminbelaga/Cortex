import Testing
import Foundation
@testable import Infrastructure
import Domain

@Suite("CommandCodeFailoverPool Tests")
struct CommandCodeFailoverPoolTests {
    private final class Credentials: CredentialRepository, @unchecked Sendable {
        var values: [String: String] = [:]
        func save(_ value: String, forKey key: String) { values[key] = value }
        func get(forKey key: String) -> String? { values[key] }
        func exists(forKey key: String) -> Bool { values[key] != nil }
        func delete(forKey key: String) -> Bool { values[key] = nil; return true }
    }

    private func home(pool: String? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmdpool-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".commandcode")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{ "apiKey": "user_primary" }"#.write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        if let pool { try pool.write(to: dir.appendingPathComponent("auth-pool.json"), atomically: true, encoding: .utf8) }
        return home
    }

    @Test
    func `loader reads the runtime apiKey field of pool siblings`() throws {
        let h = try home(pool: #"{ "accounts": [{ "label": "compte-1", "apiKey": "user_one" }] }"#)
        let pool = CommandCodeCredentialLoader(homeDirectory: h.path, environment: [:]).loadPool()
        #expect(pool.map(\.slot) == ["cli", "pool:compte-1"])
        #expect(pool.last?.key == "user_one")
    }

    @Test
    func `enrol appends an apiKey entry, is idempotent and never pools the primary`() throws {
        let h = try home(pool: #"{ "_doc": "keep", "accounts": [{ "label": "compte-1", "apiKey": "user_one" }] }"#)
        let loader = CommandCodeCredentialLoader(homeDirectory: h.path, environment: [:])
        let pool = CommandCodeFailoverPool(loader: loader)
        #expect(try pool.enroll(label: "Kurtezy", key: "user_kurtezy") == "pool:kurtezy")
        #expect(try pool.enroll(label: "Kurtezy bis", key: "user_kurtezy") == "pool:kurtezy")
        #expect(try pool.enroll(label: "Primary", key: "user_primary") == "cli")
        let url = URL(fileURLWithPath: loader.poolFilePath)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let accounts = root?["accounts"] as? [[String: String]]
        #expect(accounts?.map { $0["label"] ?? "" } == ["compte-1", "Kurtezy"])
        #expect(accounts?.last?["apiKey"] == "user_kurtezy")
        #expect(root?["_doc"] as? String == "keep")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test
    func `unifier moves Keychain Command Code accounts into the CLI pool`() throws {
        let h = try home(pool: #"{ "accounts": [{ "label": "compte-1", "apiKey": "user_one" }] }"#)
        let credentials = Credentials()
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: h.appendingPathComponent("settings.json")),
            credentials: UserDefaults(suiteName: "test.cmdpool.\(UUID())")!, secureCredentials: credentials)
        credentials.save("user_one", forKey: "account.commandcode.A")
        credentials.save("user_tech", forKey: "account.commandcode.B")
        settings.addAccount(.init(accountId: "A", label: "Kurtezy", probeConfig: ["credentialKey": "account.commandcode.A"]),
                            forProvider: "commandcode")
        settings.addAccount(.init(accountId: "B", label: "Tech", probeConfig: ["credentialKey": "account.commandcode.B"]),
                            forProvider: "commandcode")
        let pool = CommandCodeFailoverPool(loader: CommandCodeCredentialLoader(homeDirectory: h.path, environment: [:]))
        let out = try OpenCodeAccountUnifier.unify(settings: settings, credentials: credentials, pool: pool,
                                                   providerId: "commandcode", apply: true)
        #expect(out.map(\.action) == [.repointed(slot: "pool:compte-1"), .enrolled(slot: "pool:tech")])
        #expect(settings.accounts(forProvider: "commandcode").map { $0.probeConfig["externalSlot"] ?? "-" }
                == ["pool:compte-1", "pool:tech"])
        #expect(settings.accounts(forProvider: "commandcode").allSatisfy { $0.probeConfig["credentialKey"] == nil })
    }
}
