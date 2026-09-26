import Foundation

/// One tool's aggregate for one calendar day, as written by
/// `scripts/cortex-usage-ledger.py` (the single aggregator — the app never
/// re-parses transcripts itself).
public struct LocalUsageToolDay: Codable, Sendable, Equatable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheCreation: Int
    public let reasoning: Int
    public let messages: Int
    /// Published cost in USD, or nil when the source does not publish one
    /// ("not computed here", never "free").
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

    /// Every token the model saw, cache reads included — the honest volume.
    public var totalTokens: Int { input + output + cacheRead + cacheCreation + reasoning }

    /// Tokens that were not served from cache — the "fresh" work.
    public var nonCacheTokens: Int { input + output + reasoning }
}

/// The centralized local usage ledger (`~/.claudebar/usage/ledger.json`):
/// per-day, per-tool token truth for every session on this Mac, as opposed to
/// the router snapshot which only sees routed traffic (Ben 2026-09-26: the
/// displayed 24h was ~512M while local sources showed ~3.05B).
public struct LocalUsageLedger: Codable, Sendable, Equatable {
    public let generatedAt: String
    public let days: [String: [String: LocalUsageToolDay]]

    public init(generatedAt: String, days: [String: [String: LocalUsageToolDay]]) {
        self.generatedAt = generatedAt
        self.days = days
    }

    public var sortedDayKeys: [String] { days.keys.sorted() }

    /// The most recent day key present, if any.
    public var latestDayKey: String? { sortedDayKeys.last }

    /// Total tokens across the last `count` day keys (inclusive of the latest).
    public func tokens(lastDays count: Int) -> Int {
        Array(sortedDayKeys.suffix(count))
            .flatMap { days[$0]?.values ?? [:].values }
            .reduce(0) { $0 + $1.totalTokens }
    }

    /// Per-tool token totals over the last `count` day keys, descending.
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
