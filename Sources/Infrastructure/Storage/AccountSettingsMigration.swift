import Foundation
import Domain

/// Versioned, idempotent, reversible migration that backfills the
/// `AccountDescriptor` fields (UUID, source, visibility, sortOrder) onto every
/// stored account's `probeConfig` without changing the JSON shape or touching
/// any other setting. It writes only the keys that are missing, so an account
/// already carrying descriptor metadata — and every unrelated preference such as
/// `isEnabled` — is left byte-for-byte alone.
public struct AccountSettingsMigration {
    public static let schemaVersionKey = "accounts.schemaVersion"
    public static let currentVersion = 2

    private let store: JSONSettingsStore
    private let clock: () -> Date

    public init(store: JSONSettingsStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    private var backupURL: URL {
        store.fileURL.deletingLastPathComponent().appendingPathComponent("settings.pre-v2.json")
    }

    /// The schema version currently recorded (1 when the key is absent).
    public func storedVersion() -> Int {
        (store.read(key: Self.schemaVersionKey) as Int?) ?? 1
    }

    /// Runs the migration if needed. Returns true when it wrote anything. Safe to
    /// call on every launch: a second run is a no-op.
    @discardableResult
    public func migrateIfNeeded() -> Bool {
        guard storedVersion() < Self.currentVersion else { return false }

        backupOnce()

        let all = store.readAll()
        if let providers = all["providers"] as? [String: Any] {
            for (providerId, value) in providers {
                guard let providerDict = value as? [String: Any],
                      let accounts = providerDict["accounts"] as? [[String: Any]] else { continue }
                let enriched = accounts.map { enrichAccount($0) }
                store.write(value: enriched, key: "providers.\(providerId).accounts")
            }
        }

        store.write(value: Self.currentVersion, key: Self.schemaVersionKey)
        return true
    }

    /// Restores the pre-migration settings verbatim from the one-time backup.
    /// Returns true when a backup existed and was restored.
    @discardableResult
    public func rollback() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path) else { return false }
        try? fm.removeItem(at: store.fileURL)
        try? fm.copyItem(at: backupURL, to: store.fileURL)
        return true
    }

    // MARK: - Private

    private func backupOnce() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.fileURL.path),
              !fm.fileExists(atPath: backupURL.path) else { return }
        try? fm.copyItem(at: store.fileURL, to: backupURL)
    }

    /// Adds only the missing descriptor keys. `source` is derived the same way a
    /// pre-descriptor account is read: router when a `routerAlias` is present,
    /// native otherwise — an unknown identity is never bound to a named alias.
    private func enrichAccount(_ account: [String: Any]) -> [String: Any] {
        var account = account
        var probe = (account["probeConfig"] as? [String: Any])?
            .compactMapValues { $0 as? String } ?? [:]
        typealias K = ProviderAccountConfig.DescriptorKeys

        if probe[K.uuid] == nil {
            probe[K.uuid] = UUID().uuidString
        }
        if probe[K.source] == nil {
            probe[K.source] = probe[K.routerAlias] != nil
                ? AccountSource.router.rawValue
                : AccountSource.native.rawValue
        }
        if probe[K.visibility] == nil {
            probe[K.visibility] = AccountVisibility.visible.rawValue
        }
        if probe[K.sortOrder] == nil {
            probe[K.sortOrder] = "0"
        }

        account["probeConfig"] = probe
        return account
    }
}
