import Foundation
import Domain

/// Resolves the Command Code API key that the `cmd` CLI uses.
///
/// Lookup order:
/// 1. `COMMAND_CODE_API_KEY` environment variable
/// 2. `COMMANDCODE_API_KEY` environment variable
/// 3. `apiKey` in `~/.commandcode/auth.json`
///
/// The auth file is a flat object written by `cmd login`:
/// ```json
/// { "apiKey": "user_..." }
/// ```
/// Command Code authenticates with a long-lived API key — there is no OAuth
/// token to refresh.
public struct CommandCodeCredentialLoader: Sendable {
    static let envVars = ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"]

    private let homeDirectory: String
    private let environment: [String: String]

    public init(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    /// Path to Command Code's `auth.json`.
    public var authFilePath: String {
        (homeDirectory as NSString).appendingPathComponent(".commandcode/auth.json")
    }

    /// Returns the API key, or nil when none is configured.
    public func loadAPIKey() -> String? {
        for name in Self.envVars {
            if let envKey = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !envKey.isEmpty {
                return envKey
            }
        }

        let path = authFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            guard let key = json["apiKey"] as? String else { return nil }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            AppLog.credentials.error("Failed to load Command Code credentials from file: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Failover pool

    /// Path to the sibling failover pool: siblings only,
    /// `{"accounts": [{"label": "...", "apiKey": "..."}]}` — the field the
    /// runtime failover mod (`~/.commandcode/mods/go-failover.ts`) reads. The
    /// primary lives in `auth.json` and is never copied there. Legacy `key`
    /// entries are still read.
    public var poolFilePath: String {
        (homeDirectory as NSString).appendingPathComponent(".commandcode/auth-pool.json")
    }

    /// Returns the Command Code key pool: the CLI primary first (env or
    /// `auth.json`), then every sibling of the failover pool, deduped by key.
    ///
    /// The env variable is the CLI's own override: when set it is the only
    /// entry (the pool is a CLI concept, an env key is not pooled). Mirrors
    /// `OpenCodeCredentialLoader.loadPool()` so both providers expose ONE
    /// account shape to the account rail.
    public func loadPool() -> [CommandCodePoolEntry] {
        if let envKey = Self.envVars.lazy
            .compactMap({ environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return [CommandCodePoolEntry(slot: "env", label: nil, key: envKey)]
        }

        var pool: [CommandCodePoolEntry] = []
        var seen = Set<String>()
        if let primary = loadAPIKey() {
            pool.append(CommandCodePoolEntry(slot: "cli", label: nil, key: primary))
            seen.insert(primary)
        }
        var takenSlots = Set(pool.map(\.slot))
        for sibling in siblingEntries() where !seen.contains(sibling.key) {
            var slot = sibling.slot
            var n = 2
            while takenSlots.contains(slot) {
                slot = "\(sibling.slot)-\(n)"
                n += 1
            }
            takenSlots.insert(slot)
            pool.append(CommandCodePoolEntry(slot: slot, label: sibling.label, key: sibling.key))
            seen.insert(sibling.key)
        }
        return pool
    }

    /// Siblings from the pool file. Tolerates the canonical
    /// `{"accounts": [...]}` object and a bare array; skips empty keys.
    private func siblingEntries() -> [(slot: String, label: String?, key: String)] {
        let path = poolFilePath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let rawAccounts: [Any]
        if let object = root as? [String: Any], let accounts = object["accounts"] as? [Any] {
            rawAccounts = accounts
        } else if let array = root as? [Any] {
            rawAccounts = array
        } else {
            return []
        }

        var entries: [(slot: String, label: String?, key: String)] = []
        for raw in rawAccounts {
            guard let account = raw as? [String: Any],
                  let key = ((account["apiKey"] ?? account["key"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                continue
            }
            let label = (account["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (label?.isEmpty == false) ? label : nil
            entries.append((slot: "pool:" + Self.slug(display ?? "sibling"), label: display, key: key))
        }
        return entries
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "sibling" : collapsed
    }
}

/// One account of the Command Code pool: the CLI primary (`auth.json` /
/// env) or a sibling of the failover pool, with its display label and key.
public struct CommandCodePoolEntry: Sendable, Equatable {
    public let slot: String
    public let label: String?
    public let key: String

    public init(slot: String, label: String?, key: String) {
        self.slot = slot
        self.label = label
        self.key = key
    }
}
