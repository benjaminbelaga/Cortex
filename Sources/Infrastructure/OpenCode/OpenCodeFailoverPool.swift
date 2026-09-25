import Foundation

/// Writes a new OpenCode Go key into the ONE place the whole ecosystem reads:
/// opencode's auth.json (the secret, slot `opencode-<slug>`) + the failover
/// SSOT (`tier1.slots` append + `tier1.accounts` label). The opencode failover
/// plugin rotates across that pool and Cortex reads it via `externalSlot`, so a
/// key added from Cortex immediately rescues exhausted opencode sessions.
///
/// Slots are APPENDED only: the first two slots bind the plugin's provider
/// hooks. Writes are atomic; auth.json keeps mode 0600. The same pool shape
/// serves Ollama Cloud keys (loader section `ollama_pool`, slots `ollama-cloud-*`).
/// A failover key pool Cortex can move a Keychain-backed account into.
public protocol FailoverKeyPool: Sendable {
    /// Slot already holding `key`, if pooled.
    func slot(holding key: String) -> String?
    /// Slot a new key with this label would get (dry-run display only).
    func previewSlot(for label: String) -> String
    /// Pools `key` (idempotent) and returns its slot.
    func enroll(label: String, key: String) throws -> String
}

public struct OpenCodeFailoverPool: FailoverKeyPool {
    private let loader: OpenCodeCredentialLoader

    public init(loader: OpenCodeCredentialLoader = OpenCodeCredentialLoader()) {
        self.loader = loader
    }

    public enum PoolError: Error, LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let file): "Impossible de lire \(file) (JSON invalide) — rien n’a été modifié."
            }
        }
    }

    public func slot(holding key: String) -> String? {
        loader.loadPool().first { $0.key == key }?.slot
    }

    public func previewSlot(for label: String) -> String {
        Self.freeSlot(for: label, taken: [], prefix: loader.slotPrefix)
    }

    /// Returns the slot holding `key` (existing one when already pooled).
    @discardableResult
    public func enroll(label: String, key: String) throws -> String {
        let authURL = URL(fileURLWithPath: loader.authFilePath)
        let ssotURL = URL(fileURLWithPath: loader.ssotFilePath)
        var auth = try Self.readObject(authURL, name: "auth.json")
        var ssot = try Self.readObject(ssotURL, name: "failover-ssot.json")

        let slot: String
        if let existing = auth.first(where: { ($0.value as? [String: Any])?["key"] as? String == key })?.key {
            slot = existing
        } else {
            slot = Self.freeSlot(for: label, taken: Set(auth.keys), prefix: loader.slotPrefix)
            auth[slot] = ["type": "api", "key": key]
            try Self.write(auth, to: authURL, permissions: 0o600)
        }

        var tier1 = ssot[loader.section] as? [String: Any] ?? [:]
        var slots = tier1["slots"] as? [String] ?? loader.defaultSlots
        var accounts = tier1["accounts"] as? [[String: Any]] ?? []
        var changed = false
        if !slots.contains(slot) { slots.append(slot); changed = true }
        if !accounts.contains(where: { $0["slot"] as? String == slot }) {
            accounts.append(["slot": slot, "label": label]); changed = true
        }
        if changed {
            tier1["slots"] = slots
            tier1["accounts"] = accounts
            ssot[loader.section] = tier1
            let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            ssot["last_reviewed"] = day
            try Self.write(ssot, to: ssotURL, permissions: 0o600)
        }
        return slot
    }

    static func slug(_ label: String) -> String {
        var s = label.lowercased()
        if s.hasPrefix("workspace ") { s = String(s.dropFirst("workspace ".count)) }
        let mapped = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "account" : collapsed
    }

    static func freeSlot(for label: String, taken: Set<String>, prefix: String = "opencode-") -> String {
        let base = "\(prefix)\(slug(label))"
        var slot = base
        var n = 2
        while taken.contains(slot) { slot = "\(base)-\(n)"; n += 1 }
        return slot
    }

    private static func readObject(_ url: URL, name: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoolError.unreadable(name)
        }
        return obj
    }

    private static func write(_ object: [String: Any], to url: URL, permissions: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
