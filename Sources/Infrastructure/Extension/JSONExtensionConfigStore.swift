import Foundation
import Domain

/// Persists extension config values: non-secrets in `JSONSettingsStore`, secrets in
/// the credential store (Keychain in production).
///
/// Each secret's credential account is `ext-<extensionId>-<fieldId>`. Earlier builds
/// wrote the same secret in plaintext to UserDefaults under that account prefixed with
/// `com.claudebar.credentials.`; that key is now read-only legacy, migrated on first
/// read and removed only after a verified secure write.
public final class JSONExtensionConfigRepository: ExtensionConfigRepository, @unchecked Sendable {
    private let settingsStore: JSONSettingsStore
    private let credentialStore: any CredentialRepository
    private let userDefaults: UserDefaults

    /// Legacy keys whose secure write was refused. A locally built (ad-hoc signed)
    /// Cortex has no stable Keychain identity, so the store rejects the write with
    /// errSecAuthFailed (-25293) and `save` cannot report it. Remembering the refusal
    /// stops every later read from retrying a write that keeps failing; it is
    /// per-process only.
    private let refusalLock = NSLock()
    private var refusedAccounts: Set<String> = []

    /// Creates an extension config repository.
    /// - Parameters:
    ///   - settingsStore: The JSON store for non-secret values.
    ///   - credentialStore: The secure store for secret values.
    ///   - userDefaultsSuiteName: The legacy plaintext secret store, read during migration.
    public init(
        settingsStore: JSONSettingsStore,
        credentialStore: any CredentialRepository,
        userDefaultsSuiteName: String? = nil
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        if let suiteName = userDefaultsSuiteName {
            self.userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            self.userDefaults = .standard
        }
    }

    // MARK: - Non-Secret Values

    public func value(forFieldId fieldId: String, extensionId: String) -> String? {
        settingsStore.read(key: "extensions.\(extensionId).\(fieldId)")
    }

    public func setValue(_ value: String?, forFieldId fieldId: String, extensionId: String) {
        settingsStore.write(value: value, key: "extensions.\(extensionId).\(fieldId)")
    }

    // MARK: - Secret Values

    public func secretValue(forFieldId fieldId: String, extensionId: String) -> String? {
        let account = accountKey(extensionId: extensionId, fieldId: fieldId)
        if let value = credentialStore.get(forKey: account) {
            return value
        }

        let legacyKey = legacyKey(forAccount: account)
        guard let legacyValue = userDefaults.string(forKey: legacyKey) else {
            return nil
        }
        // The store already refused this secret once; the plaintext copy is the only one
        // there is, so hand it back without writing again.
        if isRefused(account: account) {
            return legacyValue
        }

        credentialStore.save(legacyValue, forKey: account)
        // Prove the write landed before dropping the plaintext copy: `save` cannot report
        // a refusal, and dropping a value that was never stored would lose it for good.
        if credentialStore.get(forKey: account) == legacyValue {
            userDefaults.removeObject(forKey: legacyKey)
            clearRefusal(account: account)
        } else {
            rememberRefusal(account: account)
            AppLog.credentials.warning(
                "Extension secret \(account) could not be migrated to the Keychain, keeping the legacy value"
            )
        }

        // Return what is proven readable, whether that is the migrated copy or the legacy
        // one this run could not move.
        return legacyValue
    }

    public func setSecretValue(_ value: String?, forFieldId fieldId: String, extensionId: String) {
        let account = accountKey(extensionId: extensionId, fieldId: fieldId)
        let legacyKey = legacyKey(forAccount: account)

        guard let value else {
            // Clearing the field removes both copies. An empty string is the user's
            // absence of a secret, never a secret to store.
            credentialStore.delete(forKey: account)
            userDefaults.removeObject(forKey: legacyKey)
            clearRefusal(account: account)
            return
        }

        credentialStore.save(value, forKey: account)
        if credentialStore.get(forKey: account) == value {
            // Verified: any earlier plaintext copy is stale and must not linger.
            userDefaults.removeObject(forKey: legacyKey)
            clearRefusal(account: account)
        } else {
            // Keep the legacy copy rather than lose the user's secret, and stop later
            // reads from retrying a write the store keeps refusing.
            rememberRefusal(account: account)
            AppLog.credentials.warning(
                "Extension secret \(account) could not be stored in the Keychain"
            )
        }
    }

    // MARK: - All Values

    public func allValues(forExtensionId extensionId: String, fields: [ConfigField]) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            let stored: String? = if field.isSecret {
                secretValue(forFieldId: field.id, extensionId: extensionId)
            } else {
                value(forFieldId: field.id, extensionId: extensionId)
            }
            if let effective = field.effectiveValue(stored: stored) {
                result[field.id] = effective
            }
        }
        return result
    }

    // MARK: - Private

    /// The credential account for an extension secret, e.g. `ext-openrouter-apiKey`.
    private func accountKey(extensionId: String, fieldId: String) -> String {
        "ext-\(extensionId)-\(fieldId)"
    }

    /// The plaintext UserDefaults key this account used before the Keychain move.
    private func legacyKey(forAccount account: String) -> String {
        "com.claudebar.credentials.\(account)"
    }

    private func isRefused(account: String) -> Bool {
        refusalLock.withLock { refusedAccounts.contains(account) }
    }

    private func rememberRefusal(account: String) {
        refusalLock.withLock { refusedAccounts.insert(account) }
    }

    private func clearRefusal(account: String) {
        refusalLock.withLock { refusedAccounts.remove(account) }
    }
}
