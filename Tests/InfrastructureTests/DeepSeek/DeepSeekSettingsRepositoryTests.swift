import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite
struct DeepSeekSettingsRepositoryTests {
    @Test
    func `user defaults repository persists and removes DeepSeek settings`() {
        let suiteName = "DeepSeekSettingsRepositoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = UserDefaultsProviderSettingsRepository(userDefaults: defaults)

        #expect(repository.deepseekAuthEnvVar().isEmpty)
        #expect(repository.hasDeepSeekApiKey() == false)

        repository.setDeepSeekAuthEnvVar("CUSTOM_DEEPSEEK_KEY")
        repository.saveDeepSeekApiKey("sk-test")

        #expect(repository.deepseekAuthEnvVar() == "CUSTOM_DEEPSEEK_KEY")
        #expect(repository.getDeepSeekApiKey() == "sk-test")
        #expect(repository.hasDeepSeekApiKey() == true)

        repository.deleteDeepSeekApiKey()
        #expect(repository.getDeepSeekApiKey() == nil)
        #expect(repository.hasDeepSeekApiKey() == false)
    }

    @Test
    func `JSON repository persists and removes DeepSeek settings`() {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekJSONSettingsTests.\(UUID().uuidString)")
        let suiteName = "DeepSeekJSONCredentialsTests.\(UUID().uuidString)"
        let credentials = UserDefaults(suiteName: suiteName)!
        let secureCredentials = InMemoryCredentialStore()
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
            credentials.removePersistentDomain(forName: suiteName)
        }
        let repository = JSONSettingsRepository(
            store: JSONSettingsStore(fileURL: tempDirectory.appendingPathComponent("settings.json")),
            credentials: credentials,
            secureCredentials: secureCredentials
        )

        #expect(repository.deepseekAuthEnvVar().isEmpty)
        #expect(repository.hasDeepSeekApiKey() == false)

        repository.setDeepSeekAuthEnvVar("CUSTOM_DEEPSEEK_KEY")
        repository.saveDeepSeekApiKey("sk-test")

        #expect(repository.deepseekAuthEnvVar() == "CUSTOM_DEEPSEEK_KEY")
        #expect(repository.getDeepSeekApiKey() == "sk-test")
        #expect(repository.hasDeepSeekApiKey() == true)
        // The secret lives in the credential store, not in UserDefaults.
        #expect(secureCredentials.get(forKey: CredentialKey.deepseekApiKey) == "sk-test")
        #expect(credentials.string(forKey: "com.claudebar.credentials.deepseek-api-key") == nil)

        repository.deleteDeepSeekApiKey()
        #expect(repository.getDeepSeekApiKey() == nil)
        #expect(repository.hasDeepSeekApiKey() == false)
        #expect(secureCredentials.get(forKey: CredentialKey.deepseekApiKey) == nil)
    }

    // MARK: - Legacy UserDefaults migration

    /// (b) A pre-existing plaintext UserDefaults value migrates to the credential
    /// store on first read, and the legacy key is removed after the verified write.
    @Test
    func `migrates a legacy DeepSeek key from UserDefaults on first read`() {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekMigrateTests.\(UUID().uuidString)")
        let suiteName = "DeepSeekMigrateCredentialsTests.\(UUID().uuidString)"
        let credentials = UserDefaults(suiteName: suiteName)!
        let secureCredentials = InMemoryCredentialStore()
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
            credentials.removePersistentDomain(forName: suiteName)
        }
        credentials.set("legacy-deepseek-key", forKey: "com.claudebar.credentials.deepseek-api-key")
        let repository = JSONSettingsRepository(
            store: JSONSettingsStore(fileURL: tempDirectory.appendingPathComponent("settings.json")),
            credentials: credentials,
            secureCredentials: secureCredentials
        )

        #expect(repository.getDeepSeekApiKey() == "legacy-deepseek-key")
        #expect(secureCredentials.get(forKey: CredentialKey.deepseekApiKey) == "legacy-deepseek-key")
        #expect(credentials.string(forKey: "com.claudebar.credentials.deepseek-api-key") == nil)
    }

    /// (c) When the credential store refuses the write, the legacy value is still
    /// returned and is never deleted.
    @Test
    func `keeps and returns a legacy DeepSeek key when the credential store refuses the write`() {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekRefusedTests.\(UUID().uuidString)")
        let suiteName = "DeepSeekRefusedCredentialsTests.\(UUID().uuidString)"
        let credentials = UserDefaults(suiteName: suiteName)!
        let secureCredentials = InMemoryCredentialStore(refusesWrites: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
            credentials.removePersistentDomain(forName: suiteName)
        }
        credentials.set("legacy-deepseek-key", forKey: "com.claudebar.credentials.deepseek-api-key")
        let repository = JSONSettingsRepository(
            store: JSONSettingsStore(fileURL: tempDirectory.appendingPathComponent("settings.json")),
            credentials: credentials,
            secureCredentials: secureCredentials
        )

        // Read twice: a refused migration must not consume the legacy value.
        #expect(repository.getDeepSeekApiKey() == "legacy-deepseek-key")
        #expect(repository.getDeepSeekApiKey() == "legacy-deepseek-key")
        #expect(secureCredentials.get(forKey: CredentialKey.deepseekApiKey) == nil)
        #expect(credentials.string(forKey: "com.claudebar.credentials.deepseek-api-key") == "legacy-deepseek-key")
    }
}

/// In-memory `CredentialRepository` for the migration tests above. `refusesWrites`
/// models an ad-hoc-signed build whose Keychain write is rejected: `save` is a no-op
/// and `get` never returns it. (`EphemeralCredentials` is private to `CortexRuntime`.)
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
