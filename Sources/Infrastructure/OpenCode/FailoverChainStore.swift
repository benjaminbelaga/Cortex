import Foundation
import Domain

/// Minimal writer for the two failover actions Cortex exposes. It never changes
/// the file formats the opencode plugins read — it only removes one quarantine
/// entry, or flips `tier2.enabled`. Every write is atomic (tmp + rename) and
/// re-reads the current file first, so a concurrent plugin write is merged, not
/// clobbered.
public struct FailoverChainStore: Sendable {
    private let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    private var ssotPath: String { path(".config/opencode/failover-ssot.json") }
    private var goQuarantinePath: String { path(".claude/state/opencode-go-failover-quarantine.json") }
    private var ollamaQuarantinePath: String { path(".claude/state/ollama-cloud-failover-quarantine.json") }

    private func path(_ relative: String) -> String {
        (homeDirectory as NSString).appendingPathComponent(relative)
    }

    /// Remove a slot's quarantine so the next request tries it again.
    @discardableResult
    public func reactivate(slot: String, pool: FailoverChainState.Pool) -> Bool {
        let file = pool == .go ? goQuarantinePath : ollamaQuarantinePath
        guard var json = readJSON(file) else { return false }
        guard json.removeValue(forKey: slot) != nil else { return false }
        return writeJSON(json, to: file)
    }

    /// The Ollama fallback kill switch (`tier2.enabled`).
    @discardableResult
    public func setTier2(enabled: Bool) -> Bool {
        guard var ssot = readJSON(ssotPath),
              var tier2 = ssot["tier2"] as? [String: Any] else { return false }
        tier2["enabled"] = enabled
        ssot["tier2"] = tier2
        return writeJSON(ssot, to: ssotPath)
    }

    // MARK: - Atomic IO

    private func readJSON(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func writeJSON(_ json: [String: Any], to path: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return false
        }
        let tmp = path + ".cortex-\(UUID().uuidString).tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                      withItemAt: URL(fileURLWithPath: tmp))
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
    }
}
