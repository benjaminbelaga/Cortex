import Foundation

/// Read-only snapshot of the OpenCode → Ollama failover chain, as the opencode
/// plugins actually operate it. Cortex displays this, never re-derives routing:
/// the SSOT is `~/.config/opencode/failover-ssot.json` plus the shared
/// quarantine state files written by `opencode-go-failover.js` /
/// `provider-fallback.js`. No values, no secrets — slot ids and labels only.
public struct FailoverChainState: Equatable, Sendable {
    public enum Pool: String, Equatable, Sendable {
        /// Tier 1 — OpenCode Go / Zen accounts, rotated first.
        case go
        /// Tier 2 — Ollama Cloud keys, reached only once every Go key is spent.
        case ollama
    }

    /// One account in the chain, in the order the plugins try them.
    public struct Slot: Equatable, Sendable, Identifiable {
        public enum Status: Equatable, Sendable {
            /// First account of its pool with quota — the one serving now.
            case head
            /// Available, but another account of the pool is ahead of it.
            case healthy
            /// Benched until this instant after a 402/429.
            case quarantined(until: Date)
        }

        public let slot: String
        public let label: String
        public let pool: Pool
        public let status: Status

        public init(slot: String, label: String, pool: Pool, status: Status) {
            self.slot = slot
            self.label = label
            self.pool = pool
            self.status = status
        }

        public var id: String { slot }
        public var isQuarantined: Bool { if case .quarantined = status { return true }; return false }
    }

    public let slots: [Slot]
    /// `tier2.enabled` — the Ollama fallback kill switch.
    public let tier2Enabled: Bool
    /// Fallback target as `<provider>/<model>`, e.g. `ollama-cloud/deepseek-v4.1-flash`.
    public let tier2Target: String?
    /// OpenCode sessions currently replaying on Ollama (from the origin file).
    public let sessionsOnOllama: Int
    /// When the snapshot was taken (for the countdowns to stay honest).
    public let capturedAt: Date

    public init(slots: [Slot], tier2Enabled: Bool, tier2Target: String?,
                sessionsOnOllama: Int, capturedAt: Date = Date()) {
        self.slots = slots
        self.tier2Enabled = tier2Enabled
        self.tier2Target = tier2Target
        self.sessionsOnOllama = sessionsOnOllama
        self.capturedAt = capturedAt
    }

    public var goSlots: [Slot] { slots.filter { $0.pool == .go } }
    public var ollamaSlots: [Slot] { slots.filter { $0.pool == .ollama } }

    /// The account serving the next Go request (first non-quarantined Go slot).
    public var servingGo: Slot? { goSlots.first { !$0.isQuarantined } }

    /// Ollama is actually reachable when the kill switch is on AND at least one
    /// Ollama key is still un-quarantined — mirroring the plugin's health gate.
    public var ollamaArmed: Bool { tier2Enabled && ollamaSlots.contains { !$0.isQuarantined } }

    public static let empty = FailoverChainState(slots: [], tier2Enabled: false,
                                                 tier2Target: nil, sessionsOnOllama: 0)
}
