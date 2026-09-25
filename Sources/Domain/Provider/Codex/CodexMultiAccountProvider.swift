import Foundation

/// Identifies one Codex account isolated by `CODEX_HOME`. Used as the
/// canonical key for `CodexMultiAccountProvider`'s roster.
public struct CodexAccountConfig: Sendable, Equatable, Hashable {
    public let label: String
    public let codexHome: String

    public init(label: String, codexHome: String) {
        self.label = label
        self.codexHome = codexHome
    }
}

/// Lightweight quota summary. Mirrors `CodexRateLimitWindow` from the
/// existing Codex reading pipeline; lives in Domain so `CodexMultiAccountProvider`
/// can compose snapshots without crossing to Infrastructure.
public struct CodexQuotaSummary: Sendable, Equatable {
    public let usedPercent: Double
    public let resetsAtDescription: String?
    public let resetTimestamp: Date?

    public init(usedPercent: Double, resetsAtDescription: String? = nil, resetTimestamp: Date? = nil) {
        self.usedPercent = usedPercent
        self.resetsAtDescription = resetsAtDescription
        self.resetTimestamp = resetTimestamp
    }
}

/// One Codex account's fresh observation. The provider emits one per
/// `CodexAccountConfig`, ordered to match the input roster.
///
/// `hasGauges == false` ⇒ API-key plan (`"metered_api"`) — the user pays per
/// token, so no 5h/7d windows exist. The UI sheet reads this to suppress the
/// "fenêtres" rows; the row still shows "Connected · quotas pending" or
/// the cost column instead.
public struct CodexAccountSnapshot: Sendable, Equatable {
    public let label: String
    public let codexHome: String
    public let email: String?
    public let planType: String?
    public let observedAt: Date
    public let primaryQuota: CodexQuotaSummary?
    public let secondaryQuota: CodexQuotaSummary?
    public let hasGauges: Bool

    public init(
        label: String,
        codexHome: String,
        email: String?,
        planType: String?,
        observedAt: Date,
        primaryQuota: CodexQuotaSummary?,
        secondaryQuota: CodexQuotaSummary?,
        hasGauges: Bool
    ) {
        self.label = label
        self.codexHome = codexHome
        self.email = email
        self.planType = planType
        self.observedAt = observedAt
        self.primaryQuota = primaryQuota
        self.secondaryQuota = secondaryQuota
        self.hasGauges = hasGauges
    }
}

/// Probe seam for one Codex account's full observation (identity + rate
/// limits). Production wires `CodexMultiAccountRPCProbe` (a thin layer over
/// `DefaultCodexRPCClient` per `CODEX_HOME`); tests inject a stub.
public protocol CodexMultiAccountProbing: Sendable {
    func snapshot(label: String, codexHome: String) async -> CodexAccountSnapshot
}

/// Multi-account Codex provider. Fans out a snapshot request across every
/// `CODEX_HOME` in `accounts` and aggregates the per-account results. The
/// fan-out is concurrent (`TaskGroup`); each task is independent — a slow
/// account never blocks a fast one.
public struct CodexMultiAccountProvider: Sendable {
    public let accounts: [CodexAccountConfig]
    public let probe: any CodexMultiAccountProbing

    public init(
        accounts: [CodexAccountConfig],
        probe: any CodexMultiAccountProbing
    ) {
        self.accounts = accounts
        self.probe = probe
    }

    /// Concurrent snapshot fan-out. Order of returned snapshots matches
    /// `accounts` (the probe labels each result with its account's label).
    public func snapshot() async -> [CodexAccountSnapshot] {
        await withTaskGroup(of: (Int, CodexAccountSnapshot).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    let snap = await probe.snapshot(
                        label: account.label,
                        codexHome: account.codexHome
                    )
                    return (index, snap)
                }
            }
            var slots: [(Int, CodexAccountSnapshot)] = []
            for await pair in group {
                slots.append(pair)
            }
            return slots
                .sorted(by: { $0.0 < $1.0 })
                .map { $0.1 }
        }
    }
}
