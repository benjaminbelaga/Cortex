import Foundation
import Infrastructure

/// **QwenApiRemovalMigration** — deletes the residual `providers.qwen-api`
/// settings subtree left by pre-v7.2 installs.
///
/// The `qwen-api` provider pointed at the dead router provider
/// `qwen_cloud_payg` and was removed from the catalog (Cortex v7.2). The Qwen
/// token plan is served by the `qwen` provider (`bailian_token_plan`). This
/// migration is idempotent: it only writes when the key is actually present, so
/// a clean install never touches the file.
public struct QwenApiRemovalMigration: Sendable {

    public static let key = "providers.qwen-api"

    /// Removes `providers.qwen-api` when present. Returns `true` when it acted.
    @discardableResult
    public static func applyIfNeeded(store: JSONSettingsStore = .shared) -> Bool {
        guard let providers = store.readAll()["providers"] as? [String: Any],
              providers["qwen-api"] != nil else {
            return false
        }
        store.write(value: nil, key: key)
        return true
    }
}
