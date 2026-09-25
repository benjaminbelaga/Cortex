import Testing
import Foundation
@testable import Infrastructure
import Domain

@Suite("OpenCodeAccountUnifier Tests")
struct OpenCodeAccountUnifierTests {
    private final class Credentials: CredentialRepository, @unchecked Sendable {
        var values: [String: String] = [:]
        func save(_ value: String, forKey key: String) { values[key] = value }
        func get(forKey key: String) -> String? { values[key] }
        func exists(forKey key: String) -> Bool { values[key] != nil }
        func delete(forKey key: String) -> Bool { values[key] = nil; return true }
    }

    private let pooled = "oc_sPOOLEDPOOLEDPOOLEDPOOLEDPOOLEDPOOLEDPOOLED1"
    private let fresh = "oc_sFRESHFRESHFRESHFRESHFRESHFRESHFRESHFRESH22"

    private func fixture() throws -> (JSONSettingsRepository, Credentials, OpenCodeCredentialLoader) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("unifier-\(UUID().uuidString)")
        let auth = home.appendingPathComponent(".local/share/opencode")
        let cfg = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["opencode-kurtezy": ["type": "api", "key": pooled]])
            .write(to: auth.appendingPathComponent("auth.json"))
        try JSONSerialization.data(withJSONObject: ["tier1": ["slots": ["opencode-kurtezy"],
            "accounts": [["slot": "opencode-kurtezy", "label": "ben@kurtezy.com"]]]])
            .write(to: cfg.appendingPathComponent("failover-ssot.json"))
        let credentials = Credentials()
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: home.appendingPathComponent("settings.json")),
            credentials: UserDefaults(suiteName: "test.unifier.\(UUID())")!, secureCredentials: credentials)
        return (settings, credentials, OpenCodeCredentialLoader(homeDirectory: home.path, environment: [:]))
    }

    private func keychainAccount(_ id: String, _ label: String, key: String,
                                 settings: JSONSettingsRepository, credentials: Credentials) {
        let reference = "account.opencode-go.\(id)"
        credentials.save(key, forKey: reference)
        settings.addAccount(.init(accountId: id, label: label, probeConfig: ["credentialKey": reference, "source": "native"]),
                            forProvider: "opencode-go")
    }

    @Test
    func `keychain key already pooled is repointed at its slot`() throws {
        let (settings, credentials, loader) = try fixture()
        keychainAccount("A", "Kurtezy", key: pooled, settings: settings, credentials: credentials)
        let out = try OpenCodeAccountUnifier.unify(settings: settings, credentials: credentials, loader: loader, apply: true)
        #expect(out.map(\.action) == [.repointed(slot: "opencode-kurtezy")])
        let account = settings.accounts(forProvider: "opencode-go").first
        #expect(account?.probeConfig["externalSlot"] == "opencode-kurtezy")
        #expect(account?.probeConfig["credentialKey"] == nil)
        #expect(account?.label == "Kurtezy")
        #expect(credentials.values.count == 1) // Keychain item kept, reported as orphan
    }

    @Test
    func `keychain key not in pool is enrolled then repointed`() throws {
        let (settings, credentials, loader) = try fixture()
        keychainAccount("B", "Studio", key: fresh, settings: settings, credentials: credentials)
        let out = try OpenCodeAccountUnifier.unify(settings: settings, credentials: credentials, loader: loader, apply: true)
        #expect(out.map(\.action) == [.enrolled(slot: "opencode-studio")])
        #expect(loader.loadPool().contains { $0.slot == "opencode-studio" && $0.key == fresh })
    }

    @Test
    func `slot already shown by another account makes the keychain one a duplicate`() throws {
        let (settings, credentials, loader) = try fixture()
        settings.addAccount(.init(accountId: "imported-opencode-kurtezy", label: "ben@kurtezy.com",
                                  probeConfig: ["externalSlot": "opencode-kurtezy"]), forProvider: "opencode-go")
        keychainAccount("C", "Kurtezy", key: pooled, settings: settings, credentials: credentials)
        let out = try OpenCodeAccountUnifier.unify(settings: settings, credentials: credentials, loader: loader, apply: true)
        #expect(out.map(\.action) == [.duplicateRemoved(slot: "opencode-kurtezy")])
        #expect(settings.accounts(forProvider: "opencode-go").map(\.accountId) == ["imported-opencode-kurtezy"])
    }

    @Test
    func `ollama keychain accounts move into the ollama pool without touching tier1`() throws {
        let (settings, credentials, loader) = try fixture()
        let home = (loader.authFilePath as NSString).deletingLastPathComponent
            .replacingOccurrences(of: "/.local/share/opencode", with: "")
        let ollama = OpenCodeCredentialLoader.ollamaCloud(homeDirectory: home)
        let live = "0123456789abcdef0123456789abcdef.OLLAMAKEYOLLAMAKEY01"
        credentials.save(live, forKey: "account.ollama.M")
        settings.addAccount(.init(accountId: "M", label: "Max", probeConfig: ["credentialKey": "account.ollama.M"]),
                            forProvider: "ollama")
        let out = try OpenCodeAccountUnifier.unify(settings: settings, credentials: credentials,
                                                   loader: ollama, providerId: "ollama", apply: true)
        #expect(out.map(\.action) == [.enrolled(slot: "ollama-cloud-max")])
        #expect(ollama.loadPool().map(\.slot) == ["ollama-cloud-max"])
        #expect(settings.accounts(forProvider: "ollama").first?.probeConfig["externalSlot"] == "ollama-cloud-max")
        #expect(loader.loadPool().map(\.slot) == ["opencode-kurtezy"])
        let ssot = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ollama.ssotFilePath))) as? [String: Any]
        #expect((ssot?["ollama_pool"] as? [String: Any])?["slots"] as? [String] == ["ollama-cloud", "ollama-cloud-max"])
    }

    @Test
    func `dry run changes nothing`() throws {
        let (settings, credentials, loader) = try fixture()
        keychainAccount("B", "Studio", key: fresh, settings: settings, credentials: credentials)
        _ = try OpenCodeAccountUnifier.unify(settings: settings, credentials: credentials, loader: loader, apply: false)
        #expect(settings.accounts(forProvider: "opencode-go").first?.probeConfig["credentialKey"] != nil)
        #expect(loader.loadPool().count == 1)
    }
}
