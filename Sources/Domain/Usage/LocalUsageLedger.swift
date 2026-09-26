import Foundation

/// One tool's aggregate for one calendar day (legacy day buckets, kept for the
/// v1 files already on disk — the v2 payload also publishes time windows).
public struct LocalUsageToolDay: Codable, Sendable, Equatable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheCreation: Int
    public let reasoning: Int
    public let messages: Int
    /// v1 field: published cost in USD, or nil when the source does not publish
    /// one ("not computed here", never "free"). v2 moved this into `cost`.
    public let costUsd: Double?

    public init(input: Int, output: Int, cacheRead: Int, cacheCreation: Int,
                reasoning: Int, messages: Int, costUsd: Double?) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.reasoning = reasoning
        self.messages = messages
        self.costUsd = costUsd
    }

    public var totalTokens: Int { input + output + cacheRead + cacheCreation + reasoning }
    public var nonCacheTokens: Int { input + output + reasoning }
}

/// Cost of a bucket, typed: `declared` (published by the source) or
/// `unavailable`. An unknown cost is never rendered as 0.
public struct LocalUsageCost: Codable, Sendable, Equatable {
    public let kind: String
    public let usd: Double?

    public init(kind: String, usd: Double?) {
        self.kind = kind
        self.usd = usd
    }

    public var isDeclared: Bool { kind == "declared" && usd != nil }
}

/// Tokens + messages for one tool over one measured window.
public struct LocalUsageBucket: Codable, Sendable, Equatable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheCreation: Int
    public let reasoning: Int
    public let messages: Int
    public let cost: LocalUsageCost?

    public init(input: Int, output: Int, cacheRead: Int, cacheCreation: Int,
                reasoning: Int, messages: Int, cost: LocalUsageCost?) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.reasoning = reasoning
        self.messages = messages
        self.cost = cost
    }

    public var totalTokens: Int { input + output + cacheRead + cacheCreation + reasoning }
    public var nonCacheTokens: Int { input + output + reasoning }

    /// Share of the volume served from cache, measured on THIS window — never a
    /// hardcoded constant (audit V2 §3).
    public var cacheShare: Double? {
        guard totalTokens > 0 else { return nil }
        return Double(cacheRead + cacheCreation) / Double(totalTokens)
    }
}

/// A measured time window (`today` = local civil day, `last24h` / `last7d` =
/// rolling windows). The last stored day is NOT "the last 24 hours".
public struct LocalUsageWindow: Codable, Sendable, Equatable {
    public let start: String
    public let end: String
    public let tools: [String: LocalUsageBucket]

    public init(start: String, end: String, tools: [String: LocalUsageBucket]) {
        self.start = start
        self.end = end
        self.tools = tools
    }
}

/// Per-source collection status. A source that could not be read is reported,
/// never converted into a reassuring zero.
public struct LocalUsageSourceStatus: Codable, Sendable, Equatable {
    public let status: String
    public let error: String?
    public let files: Int?
    public let messages: Int?
    public let lastObservedAt: String?

    public init(status: String, error: String? = nil, files: Int? = nil,
                messages: Int? = nil, lastObservedAt: String? = nil) {
        self.status = status
        self.error = error
        self.files = files
        self.messages = messages
        self.lastObservedAt = lastObservedAt
    }

    public var isOK: Bool { status == "ok" }
}

/// The centralized local usage ledger (`~/.claudebar/usage/ledger.json`):
/// per-source, per-window token truth for every session on this Mac, as opposed
/// to the router snapshot which only sees routed traffic.
public struct LocalUsageLedger: Codable, Sendable, Equatable {
    /// Stable keys the aggregator publishes.
    public static let windowNames = ["today", "last24h", "last7d"]

    public let schemaVersion: Int?
    public let generatedAt: String
    public let sources: [String: LocalUsageSourceStatus]?
    public let windows: [String: LocalUsageWindow]?
    /// v1 day buckets — present so an older file still decodes.
    public let days: [String: [String: LocalUsageToolDay]]

    public init(schemaVersion: Int? = 2,
                generatedAt: String,
                sources: [String: LocalUsageSourceStatus]? = nil,
                windows: [String: LocalUsageWindow]? = nil,
                days: [String: [String: LocalUsageToolDay]] = [:]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sources = sources
        self.windows = windows
        self.days = days
    }

    public var sortedDayKeys: [String] { days.keys.sorted() }
    public var latestDayKey: String? { sortedDayKeys.last }

    /// A published window, if the aggregator measured it.
    public func window(_ name: String) -> LocalUsageWindow? { windows?[name] }

    /// Names actually present, in canonical order.
    public var availableWindowNames: [String] {
        Self.windowNames.filter { windows?[$0] != nil }
    }

    /// Sources that are not `ok` — surfaced in the UI instead of silence.
    public var degradedSources: [(name: String, status: LocalUsageSourceStatus)] {
        (sources ?? [:]).filter { !$0.value.isOK }
            .map { (name: $0.key, status: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// Per-tool rows of a window, descending by tokens.
    public func perTool(inWindow name: String) -> [(tool: String, bucket: LocalUsageBucket)] {
        guard let window = windows?[name] else { return [] }
        return window.tools
            .map { (tool: $0.key, bucket: $0.value) }
            .sorted { $0.bucket.totalTokens > $1.bucket.totalTokens }
    }

    // MARK: - Legacy day-bucket accessors (v1 files)

    public func tokens(lastDays count: Int) -> Int {
        Array(sortedDayKeys.suffix(count))
            .flatMap { days[$0]?.values ?? [:].values }
            .reduce(0) { $0 + $1.totalTokens }
    }

    public func perTool(lastDays count: Int) -> [(tool: String, tokens: Int, messages: Int)] {
        let keys = Array(sortedDayKeys.suffix(count))
        var acc: [String: (tokens: Int, messages: Int)] = [:]
        for key in keys {
            for (tool, day) in days[key] ?? [:] {
                let current = acc[tool] ?? (0, 0)
                acc[tool] = (current.tokens + day.totalTokens, current.messages + day.messages)
            }
        }
        return acc.map { (tool: $0.key, tokens: $0.value.tokens, messages: $0.value.messages) }
            .sorted { $0.tokens > $1.tokens }
    }
}
