import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

/// Pins the account-descriptor migration: idempotent, additive-only, reversible,
/// and blind to every setting it does not own.
@Suite("AccountSettingsMigration")
struct AccountSettingsMigrationTests {

    private func makeStore(seed: [String: Any]) throws -> (JSONSettingsStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: seed, options: [.sortedKeys])
        try data.write(to: url)
        return (JSONSettingsStore(fileURL: url), dir)
    }

    private let seed: [String: Any] = [
        "providers": [
            "claude": [
                "activeAccountId": "personal",
                "accounts": [
                    ["accountId": "personal", "label": "PERSONAL", "probeConfig": ["routerAlias": "PERSONAL"]],
                    ["accountId": "work", "label": "Work", "probeConfig": ["claudeConfigDir": "/p/work"]],
                ],
            ],
            "bedrock": ["isEnabled": true],
            "cursor": ["isEnabled": false],
        ],
    ]

    @Test("v1 to v2 adds only the missing descriptor keys")
    func addsMissingKeysOnly() throws {
        let (store, dir) = try makeStore(seed: seed)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(store.read(key: AccountSettingsMigration.schemaVersionKey) as Int? == nil)
        let wrote = AccountSettingsMigration(store: store).migrateIfNeeded()
        #expect(wrote == true)
        #expect(store.read(key: AccountSettingsMigration.schemaVersionKey) as Int? == 2)

        let repo = JSONSettingsRepository(store: store)
        let accounts = repo.accounts(forProvider: "claude")
        let personal = try #require(accounts.first { $0.accountId == "personal" })
        let work = try #require(accounts.first { $0.accountId == "work" })

        // Router account gets source=router; native-only gets source=native.
        #expect(personal.descriptor(providerId: "claude").source == .router)
        #expect(work.descriptor(providerId: "claude").source == .native)
        // Original profile keys are untouched.
        #expect(personal.probeConfig["routerAlias"] == "PERSONAL")
        #expect(work.probeConfig["claudeConfigDir"] == "/p/work")
        // A UUID was minted for each.
        #expect(UUID(uuidString: personal.probeConfig["accountUUID"] ?? "") != nil)
        // No unknown identity was bound to a named alias for the native account.
        #expect(work.probeConfig["routerAlias"] == nil)
    }

    @Test("A second run is a no-op")
    func secondRunNoOp() throws {
        let (store, dir) = try makeStore(seed: seed)
        defer { try? FileManager.default.removeItem(at: dir) }

        let migration = AccountSettingsMigration(store: store)
        #expect(migration.migrateIfNeeded() == true)
        let afterFirst = try Data(contentsOf: store.fileURL)
        #expect(migration.migrateIfNeeded() == false)
        let afterSecond = try Data(contentsOf: store.fileURL)
        #expect(afterFirst == afterSecond)
    }

    @Test("Explicit provider isEnabled values are never touched")
    func isEnabledUntouched() throws {
        let (store, dir) = try makeStore(seed: seed)
        defer { try? FileManager.default.removeItem(at: dir) }

        AccountSettingsMigration(store: store).migrateIfNeeded()
        let repo = JSONSettingsRepository(store: store)
        #expect(repo.isEnabled(forProvider: "bedrock", defaultValue: false) == true)
        #expect(repo.isEnabled(forProvider: "cursor", defaultValue: true) == false)
    }

    @Test("Rollback restores the pre-migration settings verbatim")
    func rollbackByteEqual() throws {
        let (store, dir) = try makeStore(seed: seed)
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = try Data(contentsOf: store.fileURL)
        let migration = AccountSettingsMigration(store: store)
        #expect(migration.migrateIfNeeded() == true)
        #expect(try Data(contentsOf: store.fileURL) != before) // changed

        #expect(migration.rollback() == true)
        #expect(try Data(contentsOf: store.fileURL) == before) // byte-equal
    }
}
