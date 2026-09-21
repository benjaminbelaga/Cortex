import Foundation

/// Normalized, credential-free snapshot supplied by llm-router.
///
/// Percentages deliberately remain fractions here. Conversion to ClaudeBar's
/// 0...100 `UsageQuota` model happens once in `RouterBackedProvider`.
public struct RouterQuotaSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let providers: [String: RouterProviderQuota]
    public let isStale: Bool
    public let fallbackError: String?
    /// Real-usage aggregates (v6 Phase A) — optional: older routers don't emit it.
    public let usage: RouterUsageSnapshot?
    /// Theoretical-cost estimate (v6 Phase B) — optional, same reason.
    public let costEstimate: RouterCostEstimate?

    public init(
        generatedAt: Date,
        providers: [String: RouterProviderQuota],
        isStale: Bool = false,
        fallbackError: String? = nil,
        usage: RouterUsageSnapshot? = nil,
        costEstimate: RouterCostEstimate? = nil
    ) {
        self.generatedAt = generatedAt
        self.providers = providers
        self.isStale = isStale
        self.fallbackError = fallbackError
        self.usage = usage
        self.costEstimate = costEstimate
    }

    public func stale(after error: Error) -> Self {
        Self(
            generatedAt: generatedAt,
            providers: providers,
            isStale: true,
            fallbackError: error.localizedDescription,
            usage: usage,
            costEstimate: costEstimate
        )
    }

    /// Anomalies extracted from the live usage snapshot (v6 Phase A+).
    public var usageAnomalies: [RouterUsageAnomaly] {
        usage?.anomalies ?? []
    }
}

public struct RouterProviderQuota: Sendable, Equatable {
    public let providerId: String
    public let windows: [RouterQuotaWindow]
    public let error: String?
    public let source: String?
    public let capturedAt: Date
    public let accounts: [RouterAccountQuota]
    public let warnings: [String]
    /// True when this provider's reading is too untrustworthy to drive the
    /// menu-bar health glyph or the "under 10%" alarm: an explicitly stale
    /// confidence, an old manual sync (e.g. a 6-day-old Qwen console paste),
    /// or data older than a day. A stale 0% must never read as a real
    /// exhaustion (Ben 2026-08-24: brain red while models are available).
    public let isStale: Bool
    public let resourceKind: String
    public let billingMode: String
    public let credentialState: String
    public let resourceState: String
    public let expiryState: String
    public let resourceExpiresAt: Date?
    public let credentialExpiresAt: Date?
    public let expiryCandidates: [String]
    public let forecast: RouterQuotaForecast?

    public init(
        providerId: String,
        windows: [RouterQuotaWindow] = [],
        error: String? = nil,
        source: String? = nil,
        capturedAt: Date,
        accounts: [RouterAccountQuota] = [],
        warnings: [String] = [],
        isStale: Bool = false,
        resourceKind: String = "rolling_quota",
        billingMode: String = "prepaid_subscription",
        credentialState: String = "unknown",
        resourceState: String = "unknown",
        expiryState: String = "unknown",
        resourceExpiresAt: Date? = nil,
        credentialExpiresAt: Date? = nil,
        expiryCandidates: [String] = [],
        forecast: RouterQuotaForecast? = nil
    ) {
        self.providerId = providerId
        self.windows = windows
        self.error = error
        self.source = source
        self.capturedAt = capturedAt
        self.accounts = accounts
        self.warnings = warnings
        self.isStale = isStale
        self.resourceKind = resourceKind
        self.billingMode = billingMode
        self.credentialState = credentialState
        self.resourceState = resourceState
        self.expiryState = expiryState
        self.resourceExpiresAt = resourceExpiresAt
        self.credentialExpiresAt = credentialExpiresAt
        self.expiryCandidates = expiryCandidates
        self.forecast = forecast
    }
}

/// A cautious provider-level exhaustion projection derived by llm-router from
/// its rolling quota history. `calibrating` deliberately carries no time.
public struct RouterQuotaForecast: Sendable, Equatable, Hashable {
    public let windowKind: String
    public let sampleCount: Int
    public let observationHours: Double
    public let confidence: String
    public let burnRatePercentPerHour: Double?
    public let projectedExhaustionAt: Date?
    public let projectedRemainingAtResetPercent: Double?
    public let severity: String

    public init(
        windowKind: String,
        sampleCount: Int,
        observationHours: Double,
        confidence: String,
        burnRatePercentPerHour: Double?,
        projectedExhaustionAt: Date?,
        projectedRemainingAtResetPercent: Double?,
        severity: String
    ) {
        self.windowKind = windowKind
        self.sampleCount = sampleCount
        self.observationHours = observationHours
        self.confidence = confidence
        self.burnRatePercentPerHour = burnRatePercentPerHour
        self.projectedExhaustionAt = projectedExhaustionAt
        self.projectedRemainingAtResetPercent = projectedRemainingAtResetPercent
        self.severity = severity
    }
}

public struct RouterAccountQuota: Sendable, Equatable {
    public let alias: String
    public let accountId: String?
    public let identity: String?
    public let windows: [RouterQuotaWindow]
    public let present: Bool
    public let error: String?
    public let source: String?
    public let active: Bool
    public let stale: Bool
    public let authState: String

    public init(
        alias: String,
        accountId: String? = nil,
        identity: String? = nil,
        windows: [RouterQuotaWindow] = [],
        present: Bool = true,
        error: String? = nil,
        source: String? = nil,
        active: Bool = true,
        stale: Bool = false,
        authState: String = "unknown"
    ) {
        self.alias = alias
        self.accountId = accountId
        self.identity = identity
        self.windows = windows
        self.present = present
        self.error = error
        self.source = source
        self.active = active
        self.stale = stale
        self.authState = authState
    }
}

public struct RouterQuotaWindow: Sendable, Equatable {
    public let kind: String
    public let remainingFraction: Double?
    public let resetsAt: Date?
    public let note: String?

    public init(
        kind: String,
        remainingFraction: Double?,
        resetsAt: Date? = nil,
        note: String? = nil
    ) {
        self.kind = kind
        self.remainingFraction = remainingFraction
        self.resetsAt = resetsAt
        self.note = note
    }
}

public protocol RouterQuotaSnapshotProviding: Sendable {
    func isAvailable() async -> Bool
    func snapshot(
        forceRefresh: Bool,
        usageMaxAgeSeconds: TimeInterval
    ) async throws -> RouterQuotaSnapshot
    func lastKnownSnapshot() async -> RouterQuotaSnapshot?
}

/// Lets the overview choose quota/API/credit/local row templates without
/// reverse-engineering provider names.
@MainActor
public protocol RouterResourceReporting: Sendable {
    var routerResource: RouterProviderQuota? { get }
}

public extension RouterQuotaSnapshotProviding {
    func snapshot(forceRefresh: Bool) async throws -> RouterQuotaSnapshot {
        try await snapshot(forceRefresh: forceRefresh, usageMaxAgeSeconds: 60)
    }

    func lastKnownSnapshot() async -> RouterQuotaSnapshot? { nil }
}

/// Providers can expose account-scoped warnings without fabricating quota
/// windows for missing, expired, or stale credentials.
@MainActor
public protocol GroupErrorReporting: Sendable {
    var lastGroupErrors: [String: String] { get }
}

public struct RouterQuotaIssue: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
