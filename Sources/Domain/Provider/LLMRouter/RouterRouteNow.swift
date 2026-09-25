import Foundation

/// The router's "route right now" recommendation block (Contract B, v7.2).
///
/// Decoded from the `route_now` object llm-router adds to its json-v2 snapshot
/// envelope. Cortex NEVER computes a recommendation locally: when this block is
/// absent the "Priority" card shows "llm-router indisponible" instead.
public struct RouterRouteNow: Sendable, Equatable {
    public let generatedAt: Date
    /// Keyed by profile: `plan`, `execute`, `flexible`.
    public let profiles: [String: RouterRecommendation]

    public init(generatedAt: Date, profiles: [String: RouterRecommendation]) {
        self.generatedAt = generatedAt
        self.profiles = profiles
    }

    /// The three recommendation profiles the UI segmented control exposes.
    public enum Profile: String, Sendable, CaseIterable, Identifiable {
        /// PLAN phase — favours glm/kimi/claude.
        case plan
        /// EXECUTE phase — the provider's preferred family (deepseek).
        case execute
        /// EXECUTE without a family constraint.
        case flexible

        public var id: String { rawValue }

        /// French UI label (rawValue is the stable storage/route key).
        public var displayName: String {
            switch self {
            case .plan: "Plan fort"
            case .execute: "Eco execution"
            case .flexible: "Flexible"
            }
        }
    }

    public func recommendation(for profile: Profile) -> RouterRecommendation? {
        profiles[profile.rawValue]
    }
}

/// One "route now" recommendation for a single profile.
public struct RouterRecommendation: Sendable, Equatable {
    public let decisionId: String
    public let provider: String
    public let account: String?
    public let model: String
    public let score: Double
    public let bindingWindow: RouterRouteWindow?
    public let timeMultiplier: Double
    /// `normal` | `peak` | `discount`.
    public let timeState: String
    public let nextBetterSlot: Date?
    public let promoExpiry: String?
    public let liveSessions: Int?
    public let reasons: [String]
    public let excluded: [RouterRouteExclusion]
    public let alternatives: [RouterRouteAlternative]

    public init(
        decisionId: String,
        provider: String,
        account: String? = nil,
        model: String,
        score: Double,
        bindingWindow: RouterRouteWindow? = nil,
        timeMultiplier: Double = 1.0,
        timeState: String = "normal",
        nextBetterSlot: Date? = nil,
        promoExpiry: String? = nil,
        liveSessions: Int? = nil,
        reasons: [String] = [],
        excluded: [RouterRouteExclusion] = [],
        alternatives: [RouterRouteAlternative] = []
    ) {
        self.decisionId = decisionId
        self.provider = provider
        self.account = account
        self.model = model
        self.score = score
        self.bindingWindow = bindingWindow
        self.timeMultiplier = timeMultiplier
        self.timeState = timeState
        self.nextBetterSlot = nextBetterSlot
        self.promoExpiry = promoExpiry
        self.liveSessions = liveSessions
        self.reasons = reasons
        self.excluded = excluded
        self.alternatives = alternatives
    }
}

/// The binding window of a recommendation (kind + remaining % + reset).
public struct RouterRouteWindow: Sendable, Equatable {
    public let kind: String
    public let remainingPct: Int
    public let resetsAt: Date?

    public init(kind: String, remainingPct: Int, resetsAt: Date? = nil) {
        self.kind = kind
        self.remainingPct = remainingPct
        self.resetsAt = resetsAt
    }
}

/// A provider/account the router considered and ruled out, with its reason.
public struct RouterRouteExclusion: Sendable, Equatable, Identifiable {
    public let provider: String
    public let account: String?
    public let reason: String

    public var id: String { "\(provider)|\(account ?? "")|\(reason)" }

    public init(provider: String, account: String? = nil, reason: String) {
        self.provider = provider
        self.account = account
        self.reason = reason
    }
}

/// A runner-up recommendation the user can see beside the chosen one.
public struct RouterRouteAlternative: Sendable, Equatable, Identifiable {
    public let provider: String
    public let account: String?
    public let model: String
    public let score: Double
    /// Fraction d'headroom restante (0…1), ou `nil` quand le quota est inconnu —
    /// une alternative non mesurable ne doit jamais passer pour comparable (R41).
    public let quotaHeadroomPct: Double?

    public var id: String { "\(provider)|\(account ?? "")|\(model)" }

    public init(
        provider: String,
        account: String? = nil,
        model: String,
        score: Double,
        quotaHeadroomPct: Double? = nil
    ) {
        self.provider = provider
        self.account = account
        self.model = model
        self.score = score
        self.quotaHeadroomPct = quotaHeadroomPct
    }
}
