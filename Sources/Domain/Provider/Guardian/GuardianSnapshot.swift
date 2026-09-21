import Foundation

/// Domain model for the mac-guardian daemon's state snapshot.
///
/// Promoted from `Sources/Infrastructure/LocalState/GuardianStateReader.State`
/// to `Sources/Domain/Provider/Guardian/` so the views can import `Domain`
/// alone (ISP — the App layer must not depend on `Infrastructure` for the
/// model it consumes). The reader lives in `Infrastructure` and is responsible
/// for decoding the JSON payload into a `GuardianSnapshot`.
///
/// `status` is a free string (green | yellow | red | blind) — the daemon's
/// vocabulary, not ClaudeBar's. Views map it to colors via their own logic
/// (see `GuardianCardView.statusColor`).
public struct GuardianSnapshot: Sendable, Equatable {
    public let status: String
    public let capturedAt: Date
    public let metrics: Metrics
    public let findings: [Finding]
    /// True when `capturedAt` is older than the reader's staleness gate
    /// (180 s). The reader sets this flag; the domain model just carries it.
    public let isStale: Bool

    public init(
        status: String,
        capturedAt: Date,
        metrics: Metrics,
        findings: [Finding],
        isStale: Bool
    ) {
        self.status = status
        self.capturedAt = capturedAt
        self.metrics = metrics
        self.findings = findings
        self.isStale = isStale
    }

    public struct Metrics: Sendable, Equatable, Decodable {
        public let swapUsedPct: Double?
        public let ramFreePct: Double?
        public let load1: Double?
        public let load1PerCore: Double?
        public let runnable: Int?
        public let zombies: Int?
        public let liveClaude: Int?
        public let liveCodex: Int?
        public let limited: Int?

        enum CodingKeys: String, CodingKey {
            case swapUsedPct = "swap_used_pct"
            case ramFreePct = "ram_free_pct"
            case load1, load1PerCore = "load1_per_core"
            case runnable, zombies
            case liveClaude = "live_claude"
            case liveCodex = "live_codex"
            case limited
        }
    }

    public struct Finding: Sendable, Equatable, Decodable {
        public let rule: String
        public let severity: String
        public let message: String
        public let autoDone: Bool

        enum CodingKeys: String, CodingKey {
            case rule, severity, message
            case autoDone = "auto_done"
        }
    }
}
