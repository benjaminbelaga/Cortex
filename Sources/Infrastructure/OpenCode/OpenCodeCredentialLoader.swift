import Foundation
import Domain

/// Resolves the OpenCode Go API key that the `opencode` CLI uses for Zen.
///
/// Lookup order:
/// 1. `OPENCODE_API_KEY` environment variable
/// 2. `opencode-go` entry in opencode's auth store
/// 3. `opencode` (shared Zen) entry in opencode's auth store
///
/// The auth store lives at `$XDG_DATA_HOME/opencode/auth.json`
/// (default `~/.local/share/opencode/auth.json`) and is keyed by provider id:
/// ```json
/// {
///   "opencode": { "type": "api", "key": "sk-..." },
///   "anthropic": { "type": "oauth", "access": "...", "refresh": "...", "expires": 0 }
/// }
/// ```
/// One account of the Go pool: the auth.json slot (or env position),
/// its display label, and its key. Labels come from the centralized
/// failover SSOT (~/.config/opencode/failover-ssot.json, ONE mapping).
public struct OpenCodePoolEntry: Sendable, Equatable {
    public let slot: String
    public let label: String?
    public let key: String
}

public struct OpenCodeCredentialLoader: Sendable {
    static let envVar = "OPENCODE_API_KEY"
    static let poolEnvVar = "OPENCODE_GO_FAILOVER_KEYS"
    static let entryKeys = ["opencode-go", "opencode"]

    private let homeDirectory: String
    private let environment: [String: String]
    /// Failover SSOT section this loader reads: `tier1` (OpenCode Go/Zen pool)
    /// or `ollama_pool` (Ollama Cloud keys used by opencode's `ollama-cloud`).
    public let section: String
    /// Slot list when the SSOT section is absent.
    public let defaultSlots: [String]
    /// Prefix of new auth.json slots enrolled into this pool.
    public let slotPrefix: String

    public init(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        section: String = "tier1"
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.section = section
        self.defaultSlots = section == "tier1" ? Self.entryKeys : ["ollama-cloud"]
        self.slotPrefix = section == "tier1" ? "opencode-" : "ollama-cloud-"
    }

    /// The Ollama Cloud key pool (SSOT `ollama_pool`), rotated by the opencode
    /// failover plugin behind the tier-2 fallback target `ollama-cloud`.
    public static func ollamaCloud(homeDirectory: String = NSHomeDirectory()) -> OpenCodeCredentialLoader {
        OpenCodeCredentialLoader(homeDirectory: homeDirectory, environment: [:], section: "ollama_pool")
    }

    /// Path to opencode's `auth.json`.
    public var authFilePath: String {
        let dataHome: String
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            dataHome = xdg
        } else {
            dataHome = (homeDirectory as NSString).appendingPathComponent(".local/share")
        }
        return (dataHome as NSString).appendingPathComponent("opencode/auth.json")
    }

    /// Path to the centralized failover SSOT (slot→label mapping).
    public var ssotFilePath: String {
        (homeDirectory as NSString).appendingPathComponent(".config/opencode/failover-ssot.json")
    }

    /// Returns the Go API key (pool primary), or nil when none is configured.
    public func loadAPIKey() -> String? {
        loadPool().first?.key
    }

    /// Returns the Go key pool: every configured account with its display
    /// label, in stable order. Env single key wins (label unknown); the
    /// comma env override yields positional labels; otherwise the SSOT
    /// slot→label mapping resolves auth.json slots (fallback: slot order).
    public func loadPool() -> [OpenCodePoolEntry] {
        if let envKey = environment[Self.envVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envKey.isEmpty {
            return [OpenCodePoolEntry(slot: "env", label: nil, key: envKey)]
        }

        if let list = environment[Self.poolEnvVar]?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }),
           !list.isEmpty {
            let multi = list.count > 1
            return list.enumerated().map { i, key in
                OpenCodePoolEntry(slot: "env[\(i)]", label: multi ? "compte \(i + 1)" : nil, key: String(key))
            }
        }

        let mapping = ssotAccountLabels()
        let slots = ssotSlots()
        guard let json = readAuthFile() else {
            return []
        }
        var pool: [OpenCodePoolEntry] = []
        for (i, slot) in slots.enumerated() {
            guard let entry = json[slot] as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.isEmpty else { continue }
            let label = slots.count > 1 ? (mapping[slot] ?? "compte \(i + 1)") : mapping[slot]
            pool.append(OpenCodePoolEntry(slot: slot, label: label, key: key))
        }
        return pool
    }

    /// slot → label from the SSOT (nil when the file is absent/corrupt).
    private func ssotAccountLabels() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ssotFilePath)),
              let ssot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier1 = ssot[section] as? [String: Any],
              let accounts = tier1["accounts"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for a in accounts {
            if let slot = a["slot"] as? String, let label = a["label"] as? String {
                out[slot] = label
            }
        }
        return out
    }

    /// Ordered slots from the SSOT (fallback: entryKeys).
    private func ssotSlots() -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ssotFilePath)),
              let ssot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier1 = ssot[section] as? [String: Any],
              let slots = tier1["slots"] as? [String], !slots.isEmpty else {
            return defaultSlots
        }
        return slots
    }

    private func readAuthFile() -> [String: Any]? {
        let path = authFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json
        } catch {
            AppLog.credentials.error("Failed to load OpenCode credentials from file: \(error.localizedDescription)")
            return nil
        }
    }
}
