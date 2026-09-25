import Foundation
import Domain

/// Reads the live OpenCode → Ollama failover chain, read-only, from the files
/// the opencode plugins own. Never writes, never touches a key — it resolves
/// slot ids to labels through the SSOT and reports quarantine/reset times.
///
/// Sources (all under the injected `homeDirectory`):
/// - `~/.config/opencode/failover-ssot.json` — tier1 + ollama_pool order/labels, tier2 switch
/// - `~/.claude/state/opencode-go-failover-quarantine.json`  — slot → until (ms epoch)
/// - `~/.claude/state/ollama-cloud-failover-quarantine.json` — slot → until (ms epoch)
/// - `~/.claude/state/opencode-provider-fallback-origin.json` — sessions replayed on the fallback
public struct FailoverChainReader: Sendable {
    private let homeDirectory: String
    private let now: @Sendable () -> Date

    public init(homeDirectory: String = NSHomeDirectory(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.homeDirectory = homeDirectory
        self.now = now
    }

    public func read() -> FailoverChainState {
        let ssot = readJSON(".config/opencode/failover-ssot.json") ?? [:]
        let goQuarantine = quarantine(".claude/state/opencode-go-failover-quarantine.json")
        let ollamaQuarantine = quarantine(".claude/state/ollama-cloud-failover-quarantine.json")
        let origin = readJSON(".claude/state/opencode-provider-fallback-origin.json") ?? [:]

        let goSlots = slots(from: ssot["tier1"], section: "tier1", pool: .go, quarantine: goQuarantine)
        let ollamaSlots = slots(from: ssot["ollama_pool"], section: "ollama_pool", pool: .ollama, quarantine: ollamaQuarantine)

        let tier2 = ssot["tier2"] as? [String: Any]
        let enabled = (tier2?["enabled"] as? Bool) ?? false
        let fallback = tier2?["fallback"] as? [String: Any]
        let target = [fallback?["providerID"] as? String, fallback?["modelID"] as? String]
            .compactMap { $0 }.joined(separator: "/")

        return FailoverChainState(
            slots: goSlots + ollamaSlots,
            tier2Enabled: enabled,
            tier2Target: target.isEmpty ? nil : target,
            sessionsOnOllama: origin.count,
            capturedAt: now()
        )
    }

    // MARK: - Parsing

    /// Section → ordered slots. `slots` gives the order; `accounts` gives the
    /// display labels. The first non-quarantined slot is marked `.head`.
    private func slots(from value: Any?, section: String, pool: FailoverChainState.Pool,
                       quarantine: [String: Double]) -> [FailoverChainState.Slot] {
        guard let dict = value as? [String: Any] else { return [] }
        let order = (dict["slots"] as? [String]) ?? []
        let labels = labels(from: dict)
        let nowMs = now().timeIntervalSince1970 * 1000
        var out: [FailoverChainState.Slot] = []
        var sawHead = false
        for slot in order {
            let status: FailoverChainState.Slot.Status
            if let until = quarantine[slot], until > nowMs {
                status = .quarantined(until: Date(timeIntervalSince1970: until / 1000))
            } else if !sawHead {
                status = .head
                sawHead = true
            } else {
                status = .healthy
            }
            out.append(.init(slot: slot, label: labels[slot] ?? slot, pool: pool, status: status))
        }
        return out
    }

    private func labels(from section: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for account in (section["accounts"] as? [[String: Any]]) ?? [] {
            if let slot = account["slot"] as? String, let label = account["label"] as? String {
                out[slot] = label
            }
        }
        return out
    }

    /// slot → until (ms epoch). Corrupt or absent → empty (fail-open: no false
    /// quarantine shown).
    private func quarantine(_ path: String) -> [String: Double] {
        guard let json = readJSON(path) else { return [:] }
        var out: [String: Double] = [:]
        for (slot, value) in json {
            if let ms = value as? Double { out[slot] = ms }
            else if let ms = value as? Int { out[slot] = Double(ms) }
        }
        return out
    }

    private func readJSON(_ relativePath: String) -> [String: Any]? {
        let path = (homeDirectory as NSString).appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
