import Foundation

/// Writes a Command Code key into the CLI failover pool (`~/.commandcode/auth-pool.json`,
/// entries `{label, apiKey}` read by the runtime failover mod), so Cortex and the
/// `cmd` CLI share ONE pool and Cortex never needs a Keychain item for it.
/// The primary key (`auth.json`) is never copied; an already pooled key is reused.
public struct CommandCodeFailoverPool: FailoverKeyPool {
    private let loader: CommandCodeCredentialLoader

    public init(loader: CommandCodeCredentialLoader = CommandCodeCredentialLoader()) {
        self.loader = loader
    }

    public func slot(holding key: String) -> String? {
        loader.loadPool().first { $0.key == key }?.slot
    }

    public func previewSlot(for label: String) -> String {
        "pool:" + label.lowercased()
    }

    @discardableResult
    public func enroll(label: String, key: String) throws -> String {
        if let existing = slot(holding: key) { return existing }
        let url = URL(fileURLWithPath: loader.poolFilePath)
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OpenCodeFailoverPool.PoolError.unreadable("auth-pool.json")
            }
            root = object
        }
        var accounts = root["accounts"] as? [[String: Any]] ?? []
        accounts.append(["label": label, "apiKey": key])
        root["accounts"] = accounts
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let slot = slot(holding: key) else {
            throw OpenCodeFailoverPool.PoolError.unreadable("auth-pool.json")
        }
        return slot
    }
}
