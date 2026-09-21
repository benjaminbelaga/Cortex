import Foundation

/// Real-usage aggregates decoded from llm-router json-v2 `usage` (v6 Phase A).
/// Raw token counts per model/backend over 24h/7d — "quel est mon usage"
/// (Ben 2026-08-24), computed once in the router, never re-derived in Cortex.
public struct RouterUsageSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let sourceUpdatedAt: Date?
    public let cacheAgeSeconds: TimeInterval?
    public let isStale: Bool
    public let isPartial: Bool
    public let partialSources: [String]
    public let refreshError: String?
    public let last24h: RouterUsageWindow?
    public let last7d: RouterUsageWindow?
    /// Anomaly flags emitted by llm-router for the current snapshot (partial
    /// sources, large contexts, high fresh-input ratio). Surfaced in Cortex as
    /// warning badges alongside the usage totals.
    public let anomalies: [RouterUsageAnomaly]

    public init(
        generatedAt: Date,
        sourceUpdatedAt: Date? = nil,
        cacheAgeSeconds: TimeInterval? = nil,
        isStale: Bool = false,
        isPartial: Bool = false,
        partialSources: [String] = [],
        refreshError: String? = nil,
        last24h: RouterUsageWindow? = nil,
        last7d: RouterUsageWindow? = nil,
        anomalies: [RouterUsageAnomaly] = []
    ) {
        self.generatedAt = generatedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.cacheAgeSeconds = cacheAgeSeconds
        self.isStale = isStale
        self.isPartial = isPartial
        self.partialSources = partialSources
        self.refreshError = refreshError
        self.last24h = last24h
        self.last7d = last7d
        self.anomalies = anomalies
    }
}

public struct RouterUsageAnomaly: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let window: String
    public let harness: String
    public let backend: String
    public let flags: [String]
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let messages: Int

    public init(
        window: String,
        harness: String,
        backend: String,
        flags: [String],
        inputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        messages: Int = 0
    ) {
        self.window = window
        self.harness = harness
        self.backend = backend
        self.flags = flags
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.messages = messages
    }
}

public struct RouterUsageWindow: Sendable, Equatable {
    public let byModel: [String: RouterModelUsage]
    public let byBackend: [String: RouterModelUsage]
    public let sessionsByHarness: [String: Int]
    public let totals: RouterModelUsage

    public init(
        byModel: [String: RouterModelUsage] = [:],
        byBackend: [String: RouterModelUsage] = [:],
        sessionsByHarness: [String: Int] = [:],
        totals: RouterModelUsage = RouterModelUsage()
    ) {
        self.byModel = byModel
        self.byBackend = byBackend
        self.sessionsByHarness = sessionsByHarness
        self.totals = totals
    }
}

public struct RouterModelUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let messages: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        messages: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.messages = messages
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }
}

/// Theoretical-cost estimate decoded from json-v2 `cost_estimate` (v6 Phase B).
/// `verified` reflects only prices actually applied from the pricing SSOT;
/// unpriced models remain visible through per-window coverage.
public struct RouterCostEstimate: Sendable, Equatable {
    public let verified: Bool
    public let reportingCurrency: String
    public let pricingSources: [String]
    public let fxSourceURL: String?
    public let fxObservedAt: String?
    public let last24h: RouterCostWindow?
    public let last7d: RouterCostWindow?

    public init(
        verified: Bool,
        reportingCurrency: String = "USD",
        pricingSources: [String] = [],
        fxSourceURL: String? = nil,
        fxObservedAt: String? = nil,
        last24h: RouterCostWindow? = nil,
        last7d: RouterCostWindow? = nil
    ) {
        self.verified = verified
        self.reportingCurrency = reportingCurrency
        self.pricingSources = pricingSources
        self.fxSourceURL = fxSourceURL
        self.fxObservedAt = fxObservedAt
        self.last24h = last24h
        self.last7d = last7d
    }
}

public struct RouterCostWindow: Sendable, Equatable {
    /// True only when every price applied inside this time window comes from
    /// a verified SSOT source. Unpriced models are tracked separately.
    public let verified: Bool
    public let unverifiedModels: [String]
    public let byModelUsd: [String: Double]
    public let totalUsd: Double
    public let usdPerMtok: Double?
    public let usdPerSession: Double?
    /// Share of tokens actually covered by a SSOT price (unpriced models are
    /// listed, never guessed).
    public let coveragePct: Double
    public let unpricedModels: [String]
    public let byModelEur: [String: Double]
    public let totalEur: Double?
    public let eurPerMtok: Double?
    public let eurPerSession: Double?

    public init(
        verified: Bool = false,
        unverifiedModels: [String] = [],
        byModelUsd: [String: Double] = [:],
        totalUsd: Double = 0,
        usdPerMtok: Double? = nil,
        usdPerSession: Double? = nil,
        coveragePct: Double = 0,
        unpricedModels: [String] = [],
        byModelEur: [String: Double] = [:],
        totalEur: Double? = nil,
        eurPerMtok: Double? = nil,
        eurPerSession: Double? = nil
    ) {
        self.verified = verified
        self.unverifiedModels = unverifiedModels
        self.byModelUsd = byModelUsd
        self.totalUsd = totalUsd
        self.usdPerMtok = usdPerMtok
        self.usdPerSession = usdPerSession
        self.coveragePct = coveragePct
        self.unpricedModels = unpricedModels
        self.byModelEur = byModelEur
        self.totalEur = totalEur
        self.eurPerMtok = eurPerMtok
        self.eurPerSession = eurPerSession
    }
}
