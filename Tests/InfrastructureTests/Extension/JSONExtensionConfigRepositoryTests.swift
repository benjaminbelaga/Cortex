import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite
struct JSONExtensionConfigRepositoryTests {
    // MARK: - Fixture

    /// In-memory credential store. `refusesWrites` models an ad-hoc-signed build whose
    /// Keychain write is rejected: `save` is a no-op and `get` never returns it.
    private final class InMemoryCredentialStore: CredentialRepository, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private let refusesWrites: Bool

        init(refusesWrites: Bool = false) {
            self.refusesWrites = refusesWrites
        }

        func save(_ value: String, forKey key: String) {
            guard !refusesWrites else { return }
            lock.withLock { values[key] = value }
        }

        func get(forKey key: String) -> String? {
            lock.withLock { values[key] }
        }

        func delete(forKey key: String) -> Bool {
            lock.withLock { values[key] = nil }
            return true
        }

        func exists(forKey key: String) -> Bool {
            get(forKey: key) != nil
        }
    }

    private struct Fixture {
        let store: JSONExtensionConfigRepository
        let dir: URL
        let suiteName: String
        let defaults: UserDefaults
        let credentials: InMemoryCredentialStore
    }

    private func makeFixture(refusesWrites: Bool = false) -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "claudebar-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let suiteName = "com.claudebar.test.\(UUID().uuidString)"
        let credentials = InMemoryCredentialStore(refusesWrites: refusesWrites)
        let store = JSONExtensionConfigRepository(
            settingsStore: JSONSettingsStore(fileURL: tempDir.appending(path: "settings.json")),
            credentialStore: credentials,
            userDefaultsSuiteName: suiteName
        )
        return Fixture(
            store: store,
            dir: tempDir,
            suiteName: suiteName,
            defaults: UserDefaults(suiteName: suiteName)!,
            credentials: credentials
        )
    }

    private func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.dir)
        UserDefaults(suiteName: fixture.suiteName)?.removePersistentDomain(forName: fixture.suiteName)
    }

    private func legacyKey(extensionId: String, fieldId: String) -> String {
        "com.claudebar.credentials.ext-\(extensionId)-\(fieldId)"
    }

    // MARK: - Non-Secret Values

    @Test
    func `stores and retrieves a string value`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.store.setValue("https://api.example.com", forFieldId: "baseUrl", extensionId: "openrouter")
        let value = fixture.store.value(forFieldId: "baseUrl", extensionId: "openrouter")

        #expect(value == "https://api.example.com")
    }

    @Test
    func `returns nil for unset value`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        let value = fixture.store.value(forFieldId: "missing", extensionId: "openrouter")

        #expect(value == nil)
    }

    @Test
    func `isolates values between extensions`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.store.setValue("value-a", forFieldId: "url", extensionId: "ext-a")
        fixture.store.setValue("value-b", forFieldId: "url", extensionId: "ext-b")

        #expect(fixture.store.value(forFieldId: "url", extensionId: "ext-a") == "value-a")
        #expect(fixture.store.value(forFieldId: "url", extensionId: "ext-b") == "value-b")
    }

    @Test
    func `removes value when set to nil`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.store.setValue("something", forFieldId: "url", extensionId: "test")
        fixture.store.setValue(nil, forFieldId: "url", extensionId: "test")

        #expect(fixture.store.value(forFieldId: "url", extensionId: "test") == nil)
    }

    // MARK: - Secret Values

    @Test
    func `secret round-trips through the credential store, not UserDefaults`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.store.setSecretValue("sk-secret-123", forFieldId: "apiKey", extensionId: "openrouter")

        #expect(fixture.store.secretValue(forFieldId: "apiKey", extensionId: "openrouter") == "sk-secret-123")
        #expect(fixture.credentials.get(forKey: "ext-openrouter-apiKey") == "sk-secret-123")
        #expect(fixture.defaults.string(forKey: legacyKey(extensionId: "openrouter", fieldId: "apiKey")) == nil)
    }

    @Test
    func `returns nil for unset secret`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        let value = fixture.store.secretValue(forFieldId: "apiKey", extensionId: "openrouter")

        #expect(value == nil)
    }

    @Test
    func `migrates a legacy UserDefaults secret on first read and clears the legacy key`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.defaults.set("legacy-secret", forKey: legacyKey(extensionId: "openrouter", fieldId: "apiKey"))

        let value = fixture.store.secretValue(forFieldId: "apiKey", extensionId: "openrouter")

        #expect(value == "legacy-secret")
        #expect(fixture.credentials.get(forKey: "ext-openrouter-apiKey") == "legacy-secret")
        #expect(fixture.defaults.string(forKey: legacyKey(extensionId: "openrouter", fieldId: "apiKey")) == nil)
    }

    @Test
    func `keeps and returns a legacy secret when the credential store refuses the write`() {
        let fixture = makeFixture(refusesWrites: true)
        defer { cleanup(fixture) }

        fixture.defaults.set("legacy-secret", forKey: legacyKey(extensionId: "openrouter", fieldId: "apiKey"))

        let firstRead = fixture.store.secretValue(forFieldId: "apiKey", extensionId: "openrouter")
        // A second read must still work, without the store ever taking the value.
        let secondRead = fixture.store.secretValue(forFieldId: "apiKey", extensionId: "openrouter")

        #expect(firstRead == "legacy-secret")
        #expect(secondRead == "legacy-secret")
        #expect(fixture.credentials.get(forKey: "ext-openrouter-apiKey") == nil)
        #expect(fixture.defaults.string(forKey: legacyKey(extensionId: "openrouter", fieldId: "apiKey")) == "legacy-secret")
    }

    @Test
    func `removes secret when set to nil`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.store.setSecretValue("secret", forFieldId: "token", extensionId: "test")
        // A stale plaintext copy must go too.
        fixture.defaults.set("legacy", forKey: legacyKey(extensionId: "test", fieldId: "token"))

        fixture.store.setSecretValue(nil, forFieldId: "token", extensionId: "test")

        #expect(fixture.store.secretValue(forFieldId: "token", extensionId: "test") == nil)
        #expect(fixture.credentials.get(forKey: "ext-test-token") == nil)
        #expect(fixture.defaults.string(forKey: legacyKey(extensionId: "test", fieldId: "token")) == nil)
    }

    // MARK: - All Values (for env var injection)

    @Test
    func `allValues returns all stored values for an extension`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        let fields = [
            ConfigField(id: "baseUrl", label: "URL", type: .string),
            ConfigField(id: "apiKey", label: "Key", type: .secret),
            ConfigField(id: "budget", label: "Budget", type: .number, defaultValue: "100"),
        ]

        fixture.store.setValue("https://api.example.com", forFieldId: "baseUrl", extensionId: "test")
        fixture.store.setSecretValue("sk-123", forFieldId: "apiKey", extensionId: "test")
        // budget not set — should use default from field definition

        let values = fixture.store.allValues(forExtensionId: "test", fields: fields)

        #expect(values["baseUrl"] == "https://api.example.com")
        #expect(values["apiKey"] == "sk-123")
        #expect(values["budget"] == "100")
    }

    @Test
    func `allValues omits fields with no stored value and no default`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        let fields = [
            ConfigField(id: "optional", label: "Optional", type: .string),
        ]

        let values = fixture.store.allValues(forExtensionId: "test", fields: fields)

        #expect(values.isEmpty)
    }
}
