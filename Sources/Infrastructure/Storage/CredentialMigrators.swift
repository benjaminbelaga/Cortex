import Foundation
import Security
import Domain

/// One-shot, non-destructive migration of Keychain items from the legacy
/// `com.tddworks.claudebar` service namespace to `fr.yoyaku.cortex` (E4
/// bundle-id migration).
///
/// Rules: read-old / write-new, never delete the old items; only copies keys
/// absent from the new service (an explicit new value always wins); safe to
/// call on every launch (no-ops once migrated).
public enum KeychainServiceMigrator {
    public static let legacyService = "com.tddworks.claudebar.credentials"
    public static let currentService = "fr.yoyaku.cortex.credentials"

    public static func migrateIfNeeded(
        from oldService: String = legacyService,
        to newService: String = currentService
    ) {
        guard let accounts = allAccounts(service: oldService), !accounts.isEmpty else { return }
        var copied = 0
        for account in accounts {
            guard let data = readData(account: account, service: oldService),
                  !exists(account: account, service: newService)
            else { continue }
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: newService,
                kSecAttrAccount: account,
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ]
            if SecItemAdd(query as CFDictionary, nil) == errSecSuccess {
                copied += 1
            }
        }
        if copied > 0 {
            AppLog.credentials.info(
                "Migrated \(copied) Keychain item(s) \(oldService) → \(newService) (old items preserved)"
            )
        }
    }

    /// Lists account names in a service. Two-step read (attributes first,
    /// data per item): `kSecReturnData` combined with `kSecMatchLimitAll`
    /// is rejected (errSecParam) on this toolchain, so bulk data fetch is
    /// not used.
    private static func allAccounts(service: String) -> [String]? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return nil }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func readData(account: String, service: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }

    private static func exists(account: String, service: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// One-shot, non-destructive migration of the UserDefaults domain.
/// `UserDefaults.standard` is keyed by bundle identifier, so the
/// `com.tddworks.claudebar` → `fr.yoyaku.cortex` move orphans every stored
/// key (notify fallback token, provider tokens). This copies every key
/// absent from the current domain, then stops touching the old one.
public enum UserDefaultsDomainMigrator {
    public static let legacySuiteName = "com.tddworks.claudebar"

    public static func migrateIfNeeded(
        fromSuite legacySuiteName: String = legacySuiteName,
        to defaults: UserDefaults = .standard
    ) {
        guard let legacy = UserDefaults(suiteName: legacySuiteName) else { return }
        var copied = 0
        for (key, value) in legacy.dictionaryRepresentation() {
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        if copied > 0 {
            AppLog.credentials.info(
                "Migrated \(copied) UserDefaults key(s) \(legacySuiteName) → current domain (old domain preserved)"
            )
        }
    }
}

/// Test-only kill-switch for the launch-time legacy migrators (RC gate
/// enabler, `docs/release/RC-GATES.md` gates 5/6/8). When the environment
/// advertises `CORTEX_SKIP_LEGACY_MIGRATORS=1`, the app skips both migrations
/// before any read — so app-side gates can run under an isolated HOME without
/// a system prompt on the real login keychain. Default behavior (variable
/// absent, or any other value) is unchanged.
public enum LegacyMigratorGate {
    public static let skipEnvVar = "CORTEX_SKIP_LEGACY_MIGRATORS"

    public static func shouldSkip(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[skipEnvVar] == "1"
    }
}
