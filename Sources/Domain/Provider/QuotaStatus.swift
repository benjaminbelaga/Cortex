import Foundation

/// Represents the health status of a usage quota.
/// Rich domain model - status is determined by business rules, not UI logic.
public enum QuotaStatus: Sendable, Equatable, Hashable, Comparable {
    /// Quota has remaining capacity (>50%)
    case healthy
    /// Quota is getting low (20-50%)
    case warning
    /// Quota is almost exhausted (<20%)
    case critical
    /// Quota is completely exhausted (0%)
    case depleted
    /// No measurement is available (no probe yet, a probe that returned no
    /// windows, or a failed probe with no cached data).
    ///
    /// Deliberately distinct from `.healthy`: absence of data must never be
    /// reported as an all-good state (honest-states doctrine). It carries the
    /// LOWEST severity so an unmeasured reading never outranks a real one when
    /// the worst status is taken (`max()`), and it never triggers a degradation
    /// alert.
    case unknown

    // MARK: - Factory Methods

    /// Creates a status based on the percentage remaining.
    /// This encapsulates the business rules for status thresholds.
    public static func from(percentRemaining: Double) -> QuotaStatus {
        switch percentRemaining {
        case ...0:
            .depleted
        case 0..<20:
            .critical
        case 20..<50:
            .warning
        default:
            .healthy
        }
    }

    /// Creates a pace-aware status using burn rate (usage% / timeElapsed%).
    /// Burn rate > threshold means consuming faster than the period can sustain.
    /// Critical and depleted thresholds are always absolute (safety net).
    /// Falls back to absolute thresholds when time elapsed is 0 (start of period).
    ///
    /// - Parameters:
    ///   - percentRemaining: The percentage of quota remaining (0-100)
    ///   - percentTimeElapsed: How much of the reset period has elapsed (0-100)
    ///   - burnRateThreshold: The multiplier above which a warning fires (e.g., 1.5 = 50% faster than sustainable)
    public static func from(
        percentRemaining: Double,
        percentTimeElapsed: Double,
        burnRateThreshold: Double
    ) -> QuotaStatus {
        // Absolute safety nets — always apply regardless of pace
        if percentRemaining <= 0 { return .depleted }
        if percentRemaining < 20 { return .critical }

        // At start of period or no time data, fall back to absolute thresholds
        guard percentTimeElapsed > 0 else {
            return from(percentRemaining: percentRemaining)
        }

        let percentUsed = 100 - percentRemaining
        let burnRate = percentUsed / percentTimeElapsed

        // Only warn if burn rate exceeds threshold AND remaining is below 50%
        // (no point warning about high burn rate when there's plenty of quota left)
        if burnRate > burnRateThreshold && percentRemaining < 50 {
            return .warning
        }

        return .healthy
    }

    // MARK: - Status Behavior

    /// Whether this status indicates a problem that needs attention.
    /// `.unknown` is absence of data, not a problem — it needs a probe, not a
    /// warning.
    public var needsAttention: Bool {
        switch self {
        case .healthy, .unknown:
            false
        case .warning, .critical, .depleted:
            true
        }
    }

    /// The severity level (higher = more severe).
    /// `.unknown` sits BELOW `.healthy` so `max()` (worst status wins) never
    /// lets an unmeasured reading mask a real one.
    private var severity: Int {
        switch self {
        case .unknown: -1
        case .healthy: 0
        case .warning: 1
        case .critical: 2
        case .depleted: 3
        }
    }

    public static func < (lhs: QuotaStatus, rhs: QuotaStatus) -> Bool {
        lhs.severity < rhs.severity
    }
}
