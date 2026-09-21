import Foundation
import Domain

/// Narrow execution seam for the versioned llm-router snapshot command.
public protocol LLMRouterCommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data
}

/// Process-backed command runner used by the production snapshot client. Drains
/// stdout and stderr concurrently via `BoundedProcessRunner`, so a large router
/// snapshot can never deadlock on a full pipe and be misreported as a timeout.
public final class LLMRouterProcessRunner: LLMRouterCommandRunning, @unchecked Sendable {
    private let runner: BoundedProcessRunner

    public init(runner: BoundedProcessRunner = BoundedProcessRunner()) {
        self.runner = runner
    }

    public func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data {
        let result: ProcessRunResult
        do {
            result = try await runner.run(
                executable: executable,
                arguments: arguments,
                options: .init(timeout: timeout)
            )
        } catch let error as ProcessRunError {
            switch error {
            case let .launchFailed(message):
                throw RouterQuotaIssue("llm-router status could not launch: \(message)")
            case let .timedOut(after, tail):
                let suffix = tail.isEmpty ? "" : ": \(tail)"
                throw RouterQuotaIssue("llm-router status timed out after \(Int(after))s\(suffix)")
            case .cancelled:
                throw CancellationError()
            }
        }

        guard result.exitStatus == 0 else {
            let tail = result.stderrTail()
            let suffix = tail.isEmpty ? "" : ": \(tail)"
            throw RouterQuotaIssue("llm-router status exited \(result.exitStatus)\(suffix)")
        }
        // A truncated snapshot is not parseable; surface it rather than feed a
        // half JSON document to the decoder.
        if result.stdoutTruncated {
            throw RouterQuotaIssue("llm-router status output exceeded the size cap")
        }
        return result.stdout
    }
}

/// Single-reader client for llm-router's public quota snapshot v2 contract.
///
/// All router-backed provider instances share one actor. Concurrent refreshes
/// coalesce onto one subprocess, short-interval refreshes reuse the decoded
/// snapshot, and a command failure falls back to the last validated value with
/// explicit stale metadata.
public actor LLMRouterSnapshotClient: RouterQuotaSnapshotProviding {
    public typealias ExecutableResolver = @Sendable () -> String?
    public typealias Clock = @Sendable () -> Date

    private struct InFlight {
        let id: UUID
        let forceRefresh: Bool
        let usageMaxAgeSeconds: TimeInterval
        let task: Task<RouterQuotaSnapshot, Error>
    }

    private let runner: any LLMRouterCommandRunning
    private let executableResolver: ExecutableResolver
    private let timeout: TimeInterval
    private let cacheTTL: TimeInterval
    private let forcedCoalescingWindow: TimeInterval
    private let clock: Clock
    private let snapshotCacheURL: URL?

    private var cachedSnapshot: RouterQuotaSnapshot?
    private var cachedAt: Date?
    private var inFlight: InFlight?

    public init(
        runner: any LLMRouterCommandRunning = LLMRouterProcessRunner(),
        executableResolver: @escaping ExecutableResolver = LLMRouterSnapshotClient.resolveExecutable,
        timeout: TimeInterval = 60,
        cacheTTL: TimeInterval = 30,
        forcedCoalescingWindow: TimeInterval = 1,
        snapshotCacheURL: URL? = LLMRouterSnapshotClient.defaultSnapshotCacheURL(),
        clock: @escaping Clock = Date.init
    ) {
        self.runner = runner
        self.executableResolver = executableResolver
        self.timeout = timeout
        self.cacheTTL = cacheTTL
        self.forcedCoalescingWindow = forcedCoalescingWindow
        self.snapshotCacheURL = snapshotCacheURL
        self.clock = clock
        if let snapshotCacheURL,
           let data = try? Data(contentsOf: snapshotCacheURL),
           let snapshot = try? Self.parse(data) {
            cachedSnapshot = snapshot
            cachedAt = (try? snapshotCacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
    }

    public func isAvailable() async -> Bool {
        guard let executable = executableResolver() else { return false }
        return FileManager.default.isExecutableFile(atPath: executable)
    }

    public func snapshot(
        forceRefresh: Bool,
        usageMaxAgeSeconds: TimeInterval
    ) async throws -> RouterQuotaSnapshot {
        if let inFlight {
            let requestIsSatisfied = (!forceRefresh || inFlight.forceRefresh)
                && usageMaxAgeSeconds >= inFlight.usageMaxAgeSeconds
            _ = try await inFlight.task.value
            // A manual request must not inherit a weaker background flight.
            // Once that flight has settled, continue below and issue exactly
            // one stronger subprocess.
            if requestIsSatisfied {
                if let cachedSnapshot { return cachedSnapshot }
                return try await inFlight.task.value
            }
        }

        let now = clock()
        if let cachedSnapshot, let cachedAt {
            let age = now.timeIntervalSince(cachedAt)
            let allowedAge = forceRefresh ? forcedCoalescingWindow : cacheTTL
            if age >= 0, age < allowedAge {
                return cachedSnapshot
            }
        }

        guard let executable = executableResolver() else {
            let error = RouterQuotaIssue("llm-router executable was not found")
            if let cachedSnapshot { return cachedSnapshot.stale(after: error) }
            throw error
        }

        let runner = self.runner
        let timeout = self.timeout
        let snapshotCacheURL = self.snapshotCacheURL
        let usageMaxAge = max(0, Int(usageMaxAgeSeconds.rounded()))
        let requestId = UUID()
        let task = Task<RouterQuotaSnapshot, Error> {
            let data = try await runner.run(
                executable: executable,
                arguments: [
                    "status", "--format", "json-v2",
                    "--usage-max-age-seconds", String(usageMaxAge),
                ],
                timeout: timeout
            )
            let snapshot = try Self.parse(data)
            if let snapshotCacheURL {
                try? Self.persist(data, to: snapshotCacheURL)
            }
            return snapshot
        }
        inFlight = InFlight(
            id: requestId,
            forceRefresh: forceRefresh,
            usageMaxAgeSeconds: usageMaxAgeSeconds,
            task: task
        )

        do {
            let decoded = try await task.value
            if inFlight?.id == requestId { inFlight = nil }
            cachedSnapshot = decoded
            cachedAt = clock()
            return decoded
        } catch {
            if inFlight?.id == requestId { inFlight = nil }
            if let cachedSnapshot { return cachedSnapshot.stale(after: error) }
            throw error
        }
    }

    public func lastKnownSnapshot() async -> RouterQuotaSnapshot? {
        cachedSnapshot
    }

    public static func defaultSnapshotCacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudebar", isDirectory: true)
            .appendingPathComponent("router-snapshot-v2.json")
    }

    private static func persist(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func resolveExecutable() -> String? {
        if let configured = ProcessInfo.processInfo.environment["LLM_ROUTER_BIN"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return BinaryLocator.findInCommonPaths("llm-router")
            ?? BinaryLocator.which("llm-router")
    }

    static func parse(_ data: Data) throws -> RouterQuotaSnapshot {
        let wire: SnapshotWire
        do {
            wire = try JSONDecoder().decode(SnapshotWire.self, from: data)
        } catch {
            throw RouterQuotaIssue("Invalid llm-router snapshot v2 JSON: \(error.localizedDescription)")
        }

        guard wire.schemaVersion == 2 else {
            throw RouterQuotaIssue("Unsupported llm-router snapshot schema \(wire.schemaVersion); expected 2")
        }
        let generatedAt = try parseDate(wire.generatedAt, field: "generated_at")

        var providers: [String: RouterProviderQuota] = [:]
        for (key, provider) in wire.providers {
            guard !provider.providerId.isEmpty else {
                throw RouterQuotaIssue("Provider \(key) has an empty provider_id")
            }
            guard provider.providerId == key else {
                throw RouterQuotaIssue("Provider key \(key) does not match provider_id \(provider.providerId)")
            }
            try validateFraction(provider.effectiveHeadroom, field: "\(key).effective_headroom")
            guard provider.capturedAt.isFinite else {
                throw RouterQuotaIssue("\(key).captured_at must be finite")
            }
            guard provider.ageSeconds.isFinite, provider.ageSeconds >= 0 else {
                throw RouterQuotaIssue("\(key).age_seconds must be non-negative")
            }
            guard ["fresh", "usable", "stale", "unknown"].contains(provider.confidence) else {
                throw RouterQuotaIssue("\(key).confidence has an unsupported value")
            }

            let windows = try provider.windows.enumerated().map { index, window in
                try makeWindow(window, field: "\(key).windows[\(index)]")
            }
            let accounts = try provider.accounts.enumerated().map { index, account in
                guard !account.alias.isEmpty else {
                    throw RouterQuotaIssue("\(key).accounts[\(index)].alias must not be empty")
                }
                let accountWindows = try account.windows.enumerated().map { windowIndex, window in
                    try makeWindow(
                        window,
                        field: "\(key).accounts[\(index)].windows[\(windowIndex)]"
                    )
                }
                return RouterAccountQuota(
                    alias: account.alias,
                    accountId: account.accountId,
                    identity: account.identity,
                    windows: accountWindows,
                    present: account.present,
                    error: account.error,
                    source: account.source,
                    active: account.active,
                    stale: account.stale,
                    authState: account.authState
                )
            }
            providers[key] = RouterProviderQuota(
                providerId: provider.providerId,
                windows: windows,
                error: provider.error,
                source: provider.source,
                capturedAt: Date(timeIntervalSince1970: provider.capturedAt),
                accounts: accounts,
                warnings: provider.warnings,
                isStale: Self.providerReadingIsStale(provider),
                resourceKind: provider.resourceKind,
                billingMode: provider.billingMode,
                credentialState: provider.credentialState,
                resourceState: provider.resourceState,
                expiryState: provider.expiryState,
                resourceExpiresAt: try provider.resourceExpiresAt.map {
                    try parseDate($0, field: "\(key).resource_expires_at")
                },
                credentialExpiresAt: try provider.credentialExpiresAt.map {
                    try parseDate($0, field: "\(key).credential_expires_at")
                },
                expiryCandidates: provider.expiryCandidates,
                forecast: try provider.forecast.map { forecast in
                    RouterQuotaForecast(
                        windowKind: forecast.windowKind,
                        sampleCount: forecast.sampleCount,
                        observationHours: forecast.observationHours,
                        confidence: forecast.confidence,
                        burnRatePercentPerHour: forecast.burnRatePercentPerHour,
                        projectedExhaustionAt: try forecast.projectedExhaustionAt.map {
                            try parseDate($0, field: "\(key).forecast.projected_exhaustion_at")
                        },
                        projectedRemainingAtResetPercent: forecast.projectedRemainingAtResetPercent,
                        severity: forecast.severity
                    )
                }
            )
        }

        guard !providers.isEmpty else {
            throw RouterQuotaIssue("llm-router snapshot v2 contains no providers")
        }
        return RouterQuotaSnapshot(
            generatedAt: generatedAt,
            providers: providers,
            usage: try wire.usage.map { try mapUsage($0, anomalies: wire.usageAnomalies ?? []) },
            costEstimate: wire.costEstimate.map(mapCost)
        )
    }

    /// Classifies a provider reading as too untrustworthy to drive the health
    /// glyph / "under 10%" alarm. Deliberately does NOT treat `confidence ==
    /// "unknown"` as stale on its own: a fresh Claude reading is graded
    /// "unknown" yet its low weekly window is a real signal. The gate is
    /// staleness of the DATA (old manual sync, explicit stale grade, >24h age),
    /// not the router's confidence in the mapping.
    private static func providerReadingIsStale(_ provider: ProviderWire) -> Bool {
        if provider.confidence == "stale" { return true }
        // Manual console pastes (Qwen) go stale fast — a 6-day-old 0% is noise.
        if provider.manual, provider.ageSeconds > 6 * 3600 { return true }
        // Any reading older than a day is not a trustworthy live signal.
        if provider.ageSeconds > 24 * 3600 { return true }
        return false
    }

    private static func makeWindow(_ wire: WindowWire, field: String) throws -> RouterQuotaWindow {
        guard !wire.kind.isEmpty else {
            throw RouterQuotaIssue("\(field).kind must not be empty")
        }
        try validateFraction(wire.remainingPct, field: "\(field).remaining_pct")
        let reset = try wire.resetsAt.map { try parseDate($0, field: "\(field).resets_at") }
        return RouterQuotaWindow(
            kind: wire.kind,
            remainingFraction: wire.remainingPct,
            resetsAt: reset,
            note: wire.note
        )
    }

    private static func validateFraction(_ value: Double?, field: String) throws {
        guard let value else { return }
        guard value.isFinite, (0...1).contains(value) else {
            throw RouterQuotaIssue("\(field) must be a fraction between 0 and 1")
        }
    }

    private static func parseDate(_ value: String, field: String) throws -> Date {
        do {
            return try Date.ISO8601FormatStyle().parse(value)
        } catch {
            throw RouterQuotaIssue("\(field) is not a valid ISO-8601 date")
        }
    }
}

private struct SnapshotWire: Decodable {
    let schemaVersion: Int
    let generatedAt: String
    let providers: [String: ProviderWire]
    let usage: UsageWire?
    let costEstimate: CostEstimateWire?
    let usageAnomalies: [UsageAnomalyWire]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case providers
        case usage
        case costEstimate = "cost_estimate"
        case usageAnomalies = "usage_anomalies"
    }
}

// v6 Phase A/B — optional sections; synthesized decoding uses decodeIfPresent
// so older routers without them still decode.

private struct UsageWire: Decodable {
    let generatedAt: String
    let sourceUpdatedAt: String?
    let cacheAgeSeconds: Double?
    let isStale: Bool?
    let isPartial: Bool?
    let partialSources: [String]?
    let refreshError: String?
    let w24: UsageWindowWire?
    let w7: UsageWindowWire?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case sourceUpdatedAt = "source_updated_at"
        case cacheAgeSeconds = "cache_age_seconds"
        case isStale = "is_stale"
        case isPartial = "is_partial"
        case partialSources = "partial_sources"
        case refreshError = "refresh_error"
        case w24 = "24h"
        case w7 = "7d"
    }
}

private struct UsageWindowWire: Decodable {
    let byModel: [String: ModelUsageWire]
    let byBackend: [String: ModelUsageWire]
    let sessionsByHarness: [String: Int]
    let totals: ModelUsageWire

    enum CodingKeys: String, CodingKey {
        case byModel = "by_model"
        case byBackend = "by_backend"
        case sessionsByHarness = "sessions_by_harness"
        case totals
    }
}

private struct ModelUsageWire: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let messages: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case messages
    }
}

private struct UsageAnomalyWire: Decodable {
    let window: String
    let harness: String
    let backend: String
    let flags: [String]
    let inputTokens: Int?
    let cacheReadTokens: Int?
    let messages: Int?

    enum CodingKeys: String, CodingKey {
        case window
        case harness
        case backend
        case flags
        case inputTokens = "input_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case messages
    }
}

private struct CostEstimateWire: Decodable {
    let verified: Bool
    let reportingCurrency: String?
    let pricingSources: [String]?
    let fxReference: FXReferenceWire?
    let w24: CostWindowWire?
    let w7: CostWindowWire?

    enum CodingKeys: String, CodingKey {
        case verified
        case reportingCurrency = "reporting_currency"
        case pricingSources = "pricing_sources"
        case fxReference = "fx_reference"
        case w24 = "24h"
        case w7 = "7d"
    }
}

private struct FXReferenceWire: Decodable {
    let observedAt: String?
    let sourceURL: String?

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case sourceURL = "source_url"
    }
}

private struct CostWindowWire: Decodable {
    let verified: Bool?
    let unverifiedModels: [String]?
    let byModelUsd: [String: Double]
    let totalUsd: Double
    let usdPerMtok: Double?
    let usdPerSession: Double?
    let coveragePct: Double
    let unpricedModels: [String]
    let byModelEur: [String: Double]?
    let totalEur: Double?
    let eurPerMtok: Double?
    let eurPerSession: Double?

    enum CodingKeys: String, CodingKey {
        case verified
        case unverifiedModels = "unverified_models"
        case byModelUsd = "by_model_usd"
        case totalUsd = "total_usd"
        case usdPerMtok = "usd_per_mtok"
        case usdPerSession = "usd_per_session"
        case coveragePct = "coverage_pct"
        case unpricedModels = "unpriced_models"
        case byModelEur = "by_model_eur"
        case totalEur = "total_eur"
        case eurPerMtok = "eur_per_mtok"
        case eurPerSession = "eur_per_session"
    }
}

private func mapUsage(_ wire: UsageWire, anomalies: [UsageAnomalyWire]) throws -> RouterUsageSnapshot {
    let generatedAt: Date
    do {
        generatedAt = try Date.ISO8601FormatStyle().parse(wire.generatedAt)
    } catch {
        throw RouterQuotaIssue("usage.generated_at is not a valid ISO-8601 date")
    }
    let sourceUpdatedAt: Date?
    if let raw = wire.sourceUpdatedAt {
        do {
            sourceUpdatedAt = try Date.ISO8601FormatStyle().parse(raw)
        } catch {
            throw RouterQuotaIssue("usage.source_updated_at is not a valid ISO-8601 date")
        }
    } else {
        sourceUpdatedAt = nil
    }
    if let age = wire.cacheAgeSeconds, !age.isFinite || age < 0 {
        throw RouterQuotaIssue("usage.cache_age_seconds must be non-negative")
    }
    let anomalies = anomalies.map { anomaly in
        RouterUsageAnomaly(
            window: anomaly.window,
            harness: anomaly.harness,
            backend: anomaly.backend,
            flags: anomaly.flags,
            inputTokens: anomaly.inputTokens ?? 0,
            cacheReadTokens: anomaly.cacheReadTokens ?? 0,
            messages: anomaly.messages ?? 0
        )
    }
    return RouterUsageSnapshot(
        generatedAt: generatedAt,
        sourceUpdatedAt: sourceUpdatedAt,
        cacheAgeSeconds: wire.cacheAgeSeconds,
        isStale: wire.isStale ?? false,
        isPartial: wire.isPartial ?? false,
        partialSources: wire.partialSources ?? [],
        refreshError: wire.refreshError,
        last24h: wire.w24.map(mapUsageWindow),
        last7d: wire.w7.map(mapUsageWindow),
        anomalies: anomalies
    )
}

private func mapUsageWindow(_ wire: UsageWindowWire) -> RouterUsageWindow {
    func models(_ dict: [String: ModelUsageWire]) -> [String: RouterModelUsage] {
        dict.mapValues {
            RouterModelUsage(
                inputTokens: $0.inputTokens ?? 0,
                outputTokens: $0.outputTokens ?? 0,
                cacheReadTokens: $0.cacheReadTokens ?? 0,
                cacheCreationTokens: $0.cacheCreationTokens ?? 0,
                messages: $0.messages ?? 0
            )
        }
    }
    return RouterUsageWindow(
        byModel: models(wire.byModel),
        byBackend: models(wire.byBackend),
        sessionsByHarness: wire.sessionsByHarness,
        totals: RouterModelUsage(
            inputTokens: wire.totals.inputTokens ?? 0,
            outputTokens: wire.totals.outputTokens ?? 0,
            cacheReadTokens: wire.totals.cacheReadTokens ?? 0,
            cacheCreationTokens: wire.totals.cacheCreationTokens ?? 0,
            messages: wire.totals.messages ?? 0
        )
    )
}

private func mapCost(_ wire: CostEstimateWire) -> RouterCostEstimate {
    func window(_ w: CostWindowWire?) -> RouterCostWindow? {
        w.map {
            RouterCostWindow(
                verified: $0.verified ?? wire.verified,
                unverifiedModels: $0.unverifiedModels ?? [],
                byModelUsd: $0.byModelUsd,
                totalUsd: $0.totalUsd,
                usdPerMtok: $0.usdPerMtok,
                usdPerSession: $0.usdPerSession,
                coveragePct: $0.coveragePct,
                unpricedModels: $0.unpricedModels,
                byModelEur: $0.byModelEur ?? [:],
                totalEur: $0.totalEur,
                eurPerMtok: $0.eurPerMtok,
                eurPerSession: $0.eurPerSession
            )
        }
    }
    return RouterCostEstimate(
        verified: wire.verified,
        reportingCurrency: wire.reportingCurrency ?? "USD",
        pricingSources: wire.pricingSources ?? [],
        fxSourceURL: wire.fxReference?.sourceURL,
        fxObservedAt: wire.fxReference?.observedAt,
        last24h: window(wire.w24),
        last7d: window(wire.w7)
    )
}

private struct ProviderWire: Decodable {
    let providerId: String
    let windows: [WindowWire]
    let error: String?
    let source: String?
    let grade: String?
    let capturedAt: Double
    let manual: Bool
    let accounts: [AccountWire]
    let warnings: [String]
    let effectiveHeadroom: Double?
    let confidence: String
    let ageSeconds: Double
    let resourceKind: String
    let billingMode: String
    let credentialState: String
    let resourceState: String
    let expiryState: String
    let resourceExpiresAt: String?
    let credentialExpiresAt: String?
    let expiryCandidates: [String]
    let forecast: ForecastWire?

    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case windows, error, source, grade
        case capturedAt = "captured_at"
        case manual, accounts, warnings
        case effectiveHeadroom = "effective_headroom"
        case confidence
        case ageSeconds = "age_seconds"
        case resourceKind = "resource_kind"
        case billingMode = "billing_mode"
        case credentialState = "credential_state"
        case resourceState = "resource_state"
        case expiryState = "expiry_state"
        case resourceExpiresAt = "resource_expires_at"
        case credentialExpiresAt = "credential_expires_at"
        case expiryCandidates = "expiry_candidates"
        case forecast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decode(String.self, forKey: .providerId)
        windows = try container.decode([WindowWire].self, forKey: .windows)
        error = try container.decodeRequiredIfPresent(String.self, forKey: .error)
        source = try container.decodeRequiredIfPresent(String.self, forKey: .source)
        grade = try container.decodeRequiredIfPresent(String.self, forKey: .grade)
        capturedAt = try container.decode(Double.self, forKey: .capturedAt)
        manual = try container.decode(Bool.self, forKey: .manual)
        accounts = try container.decode([AccountWire].self, forKey: .accounts)
        warnings = try container.decode([String].self, forKey: .warnings)
        effectiveHeadroom = try container.decodeRequiredIfPresent(Double.self, forKey: .effectiveHeadroom)
        confidence = try container.decode(String.self, forKey: .confidence)
        ageSeconds = try container.decode(Double.self, forKey: .ageSeconds)
        resourceKind = try container.decodeIfPresent(String.self, forKey: .resourceKind) ?? "rolling_quota"
        billingMode = try container.decodeIfPresent(String.self, forKey: .billingMode) ?? "prepaid_subscription"
        credentialState = try container.decodeIfPresent(String.self, forKey: .credentialState) ?? "unknown"
        resourceState = try container.decodeIfPresent(String.self, forKey: .resourceState) ?? "unknown"
        expiryState = try container.decodeIfPresent(String.self, forKey: .expiryState) ?? "unknown"
        resourceExpiresAt = try container.decodeIfPresent(String.self, forKey: .resourceExpiresAt)
        credentialExpiresAt = try container.decodeIfPresent(String.self, forKey: .credentialExpiresAt)
        expiryCandidates = try container.decodeIfPresent([String].self, forKey: .expiryCandidates) ?? []
        forecast = try container.decodeIfPresent(ForecastWire.self, forKey: .forecast)
    }
}

private struct ForecastWire: Decodable {
    let windowKind: String
    let sampleCount: Int
    let observationHours: Double
    let confidence: String
    let burnRatePercentPerHour: Double?
    let projectedExhaustionAt: String?
    let projectedRemainingAtResetPercent: Double?
    let severity: String

    enum CodingKeys: String, CodingKey {
        case windowKind = "window_kind"
        case sampleCount = "sample_count"
        case observationHours = "observation_hours"
        case confidence
        case burnRatePercentPerHour = "burn_rate_pct_per_hour"
        case projectedExhaustionAt = "projected_exhaustion_at"
        case projectedRemainingAtResetPercent = "projected_remaining_at_reset_pct"
        case severity
    }
}

private struct AccountWire: Decodable {
    let alias: String
    let accountId: String?
    let identity: String?
    let windows: [WindowWire]
    let present: Bool
    let error: String?
    let source: String?
    let active: Bool
    let stale: Bool
    let authState: String

    enum CodingKeys: String, CodingKey {
        case alias, windows, present, error, source, active, stale
        case accountId = "account_id"
        case identity
        case authState = "auth_state"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decode(String.self, forKey: .alias)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        identity = try container.decodeIfPresent(String.self, forKey: .identity)
        windows = try container.decode([WindowWire].self, forKey: .windows)
        present = try container.decode(Bool.self, forKey: .present)
        error = try container.decodeRequiredIfPresent(String.self, forKey: .error)
        source = try container.decodeRequiredIfPresent(String.self, forKey: .source)
        active = try container.decode(Bool.self, forKey: .active)
        stale = try container.decode(Bool.self, forKey: .stale)
        authState = try container.decodeIfPresent(String.self, forKey: .authState) ?? "unknown"
    }
}

private struct WindowWire: Decodable {
    let kind: String
    let remainingPct: Double?
    let limit: Double?
    let unit: String?
    let resetsAt: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case remainingPct = "remaining_pct"
        case limit, unit
        case resetsAt = "resets_at"
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        remainingPct = try container.decodeRequiredIfPresent(Double.self, forKey: .remainingPct)
        limit = try container.decodeRequiredIfPresent(Double.self, forKey: .limit)
        unit = try container.decodeRequiredIfPresent(String.self, forKey: .unit)
        resetsAt = try container.decodeRequiredIfPresent(String.self, forKey: .resetsAt)
        note = try container.decodeRequiredIfPresent(String.self, forKey: .note)
    }
}

private extension KeyedDecodingContainer {
    func decodeRequiredIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Required key \(key.stringValue) is missing"
                )
            )
        }
        return try decodeIfPresent(type, forKey: key)
    }
}
