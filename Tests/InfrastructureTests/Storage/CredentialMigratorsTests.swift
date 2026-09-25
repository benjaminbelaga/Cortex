import Testing
import Foundation
@testable import Infrastructure

/// E4 bundle-id migration: old service/domain → new, never destructive.
/// Sandboxed service names + temp UserDefaults suites — never touches the
/// real `com.tddworks.claudebar` or `fr.yoyaku.cortex` domains.
@Suite(.serialized)
struct CredentialMigratorsTests {

    private func uniqueService(_ prefix: String) -> String {
        "com.tddworks.claudebar.tests.\(prefix).\(UUID().uuidString)"
    }

    private func save(service: String, key: String, value: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        _ = SecItemAdd(query as CFDictionary, nil)
    }

    private func read(service: String, key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func wipe(service: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    @Test("copies old-service items to the new service, preserves the old ones")
    func copiesAndPreserves() {
        let oldService = uniqueService("migrate-old")
        let newService = uniqueService("migrate-new")
        defer { wipe(service: oldService); wipe(service: newService) }
        save(service: oldService, key: "token", value: "secret-value")

        KeychainServiceMigrator.migrateIfNeeded(from: oldService, to: newService)

        #expect(read(service: newService, key: "token") == "secret-value")
        #expect(read(service: oldService, key: "token") == "secret-value")
    }

    @Test("explicit new values win; second run is a no-op")
    func explicitNewValueWinsAndIdempotent() {
        let oldService = uniqueService("migrate-old")
        let newService = uniqueService("migrate-new")
        defer { wipe(service: oldService); wipe(service: newService) }
        save(service: oldService, key: "token", value: "old-value")
        save(service: newService, key: "token", value: "explicit-new-value")

        KeychainServiceMigrator.migrateIfNeeded(from: oldService, to: newService)
        #expect(read(service: newService, key: "token") == "explicit-new-value")

        KeychainServiceMigrator.migrateIfNeeded(from: oldService, to: newService)
        #expect(read(service: newService, key: "token") == "explicit-new-value")
        #expect(read(service: oldService, key: "token") == "old-value")
    }

    @Test("empty old service is a no-op")
    func emptyOldServiceIsNoop() {
        let oldService = uniqueService("migrate-empty")
        let newService = uniqueService("migrate-new")
        defer { wipe(service: oldService); wipe(service: newService) }

        KeychainServiceMigrator.migrateIfNeeded(from: oldService, to: newService)
        #expect(read(service: newService, key: "token") == nil)
    }

    @Test("copies absent UserDefaults keys, preserves explicit values and the old domain")
    func copiesAbsentUserDefaultsKeys() {
        let oldSuite = "com.tddworks.claudebar.tests.old.\(UUID().uuidString)"
        let newSuite = "com.tddworks.claudebar.tests.new.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: oldSuite)
            UserDefaults.standard.removePersistentDomain(forName: newSuite)
        }
        guard let oldDefaults = UserDefaults(suiteName: oldSuite),
              let newDefaults = UserDefaults(suiteName: newSuite)
        else {
            Issue.record("could not create temp UserDefaults suites")
            return
        }
        oldDefaults.set("old-value", forKey: "migrated-key")
        oldDefaults.set("old-other", forKey: "other-key")
        newDefaults.set("explicit-new", forKey: "migrated-key")

        UserDefaultsDomainMigrator.migrateIfNeeded(fromSuite: oldSuite, to: newDefaults)

        #expect(newDefaults.string(forKey: "migrated-key") == "explicit-new")
        #expect(newDefaults.string(forKey: "other-key") == "old-other")
        #expect(oldDefaults.string(forKey: "migrated-key") == "old-value")
    }

    @Test("migrator kill-switch skips only on the exact env value")
    func killSwitchReadsEnvExactly() {
        #expect(LegacyMigratorGate.shouldSkip(
            environment: ["CORTEX_SKIP_LEGACY_MIGRATORS": "1"]
        ))
        #expect(!LegacyMigratorGate.shouldSkip(
            environment: ["CORTEX_SKIP_LEGACY_MIGRATORS": "0"]
        ))
        #expect(!LegacyMigratorGate.shouldSkip(
            environment: ["CORTEX_SKIP_LEGACY_MIGRATORS": "true"]
        ))
        #expect(!LegacyMigratorGate.shouldSkip(environment: [:]))
    }
}
