import Domain
import Foundation

public enum MissionLoad: String, CaseIterable, Sendable {
    case light
    case heavy

    public var criticality: String {
        switch self {
        case .light: "low"
        case .heavy: "high"
        }
    }
}

/// The account the router selected for a route. Two accounts can share the same
/// provider and model, so a route identity that stops at `provider:model` is
/// ambiguous (audit V2 §3 "Identité d'une route", T11). These are the labels the
/// router already prints in its own CLI — no secret is exposed here.
public struct MissionAccount: Sendable, Equatable {
    public let id: String?
    public let alias: String?
    public let identity: String?

    public init(id: String? = nil, alias: String? = nil, identity: String? = nil) {
        self.id = id
        self.alias = alias
        self.identity = identity
    }

    /// Display label, most human first (`alias` → `identity` → `id`).
    public var label: String? {
        for value in [alias, identity, id] {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }
}

public struct MissionCandidate: Sendable, Equatable, Identifiable {
    /// Route identity: every dimension the router can distinguish on —
    /// provider, model, effort, account and launcher. Deduplicating on
    /// `provider:model` collapsed two accounts (or two efforts) into one
    /// `ForEach` identity, so `ForEach(id: \.element.id)` received duplicates.
    public var id: String {
        var parts = [provider, model]
        if let effort, !effort.isEmpty { parts.append(effort) }
        if let label = account?.label, !label.isEmpty { parts.append(label) }
        if let launcher = launchPlan?.launcherId, !launcher.isEmpty { parts.append(launcher) }
        return parts.joined(separator: ":")
    }

    public let provider: String
    public let model: String
    public let score: Double
    public let launcherCommand: String
    public let quotaHeadroomPercent: Double?
    public let reasons: [String]
    public let warnings: [String]
    public let launchPlan: MissionLaunchPlan?
    public let effort: String?
    public let account: MissionAccount?
    /// Eligible routes are the only ones offered; an ineligible one keeps a reason.
    public let eligible: Bool?
    /// Time-tariff multiplier for this route right now (`< 1` = discount window,
    /// the engine's own vocabulary — CORTEX_BIBLE §15, never recomputed here).
    public let timeMultiplier: Double?
    public let penalties: [String]
    /// Where the quota behind this decision came from and how old it is. `nil`
    /// age is *unknown*, never zero (audit V2 §3 "inconnu n'est pas mesuré").
    public let statusSource: String?
    public let statusAgeMinutes: Double?
}

/// A discount window the engine says is not open yet (audit V2 §5). Display only:
/// Cortex never decides to wait or to launch on the strength of it.
public struct MissionWaitSuggestion: Sendable, Equatable {
    public let provider: String
    public let model: String
    public let opensAtDisplay: String?
    public let opensInMinutes: Int?
    public let multiplier: Double?
    public let reason: String?
}

/// A route the engine ruled out, with its reason. The audit (§12) requires the
/// reasons alternatives were rejected to be *visible*, not recomputed.
public struct MissionIneligibleRoute: Sendable, Equatable {
    public let provider: String
    public let reasons: [String]
}

public struct MissionLaunchPlan: Sendable, Equatable {
    public let schemaVersion: Int
    public let launcherId: String
    public let harness: String
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
}

public struct MissionSuggestion: Sendable, Equatable {
    public let missionId: String
    public let taskClass: String
    public let candidates: [MissionCandidate]
    public let explanation: [String]
    public let warnings: [String]
    /// When the engine produced the decision. Shown as an age so a stale
    /// decision is visible instead of implied fresh (audit V2 §12).
    public let generatedAt: Date?
    public let privacy: String?
    public let contextEstimate: Int?
    public let fallbackChain: [String]
    public let waitSuggestion: MissionWaitSuggestion?
    public let ineligible: [MissionIneligibleRoute]
}

/// Bounded client for `llm-router suggest --json`. It reuses the same executable
/// resolver and process runner as the quota snapshot path, but never blocks the
/// main actor and never fabricates a launcher when the catalog omits one.
public struct LLMRouterSuggestionClient: Sendable {
    public typealias ExecutableResolver = @Sendable () -> String?

    private let runner: any LLMRouterCommandRunning
    private let executableResolver: ExecutableResolver
    private let timeout: TimeInterval

    public init(
        runner: any LLMRouterCommandRunning = LLMRouterProcessRunner(),
        executableResolver: @escaping ExecutableResolver = LLMRouterSnapshotClient.resolveExecutable,
        timeout: TimeInterval = 15
    ) {
        self.runner = runner
        self.executableResolver = executableResolver
        self.timeout = timeout
    }

    public func suggest(mission: String, load: MissionLoad) async throws -> MissionSuggestion {
        let trimmed = mission.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RouterQuotaIssue("Describe the mission first")
        }
        guard let executable = executableResolver() else {
            throw RouterQuotaIssue("llm-router executable was not found")
        }
        let data = try await runner.run(
            executable: executable,
            arguments: [
                "suggest", trimmed,
                "--criticality", load.criticality,
                "--json",
            ],
            timeout: timeout
        )
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> MissionSuggestion {
        let wire: SuggestionWire
        do {
            wire = try JSONDecoder().decode(SuggestionWire.self, from: data)
        } catch {
            throw RouterQuotaIssue("Invalid llm-router suggestion JSON: \(error.localizedDescription)")
        }

        let ordered = [wire.recommended].compactMap { $0 } + wire.alternatives
        let candidates = ordered.compactMap { candidate -> MissionCandidate? in
            guard let command = candidate.launcherCommand?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !command.isEmpty else { return nil }
            return MissionCandidate(
                provider: candidate.provider,
                model: candidate.model,
                score: candidate.score,
                launcherCommand: command,
                quotaHeadroomPercent: candidate.quotaHeadroom.map { $0 * 100 },
                reasons: candidate.reasons,
                warnings: candidate.warnings,
                launchPlan: candidate.launchPlan.map {
                    MissionLaunchPlan(
                        schemaVersion: $0.schemaVersion,
                        launcherId: $0.launcherId,
                        harness: $0.harness,
                        executable: $0.executable,
                        arguments: $0.arguments,
                        environment: $0.environment
                    )
                },
                effort: candidate.effort,
                account: candidate.account.map {
                    MissionAccount(id: $0.id, alias: $0.alias, identity: $0.identity)
                },
                eligible: candidate.eligible,
                timeMultiplier: candidate.timeMultiplier,
                penalties: candidate.penalties ?? [],
                statusSource: candidate.statusSource,
                statusAgeMinutes: candidate.statusAgeMinutes
            )
        }
        guard !candidates.isEmpty else {
            throw RouterQuotaIssue("No launchable route available")
        }
        return MissionSuggestion(
            missionId: wire.missionId,
            taskClass: wire.taskClass,
            candidates: Array(candidates.prefix(3)),
            explanation: wire.explanation,
            warnings: wire.warnings,
            generatedAt: Self.parseTimestamp(wire.generatedAt),
            privacy: wire.privacy,
            contextEstimate: wire.contextEstimate,
            fallbackChain: wire.fallbackChain ?? [],
            waitSuggestion: wire.waitSuggestion.map {
                MissionWaitSuggestion(
                    provider: $0.provider,
                    model: $0.model,
                    opensAtDisplay: $0.opensAtDisplay,
                    opensInMinutes: $0.opensInMinutes,
                    multiplier: $0.multiplier,
                    reason: $0.reason
                )
            },
            ineligible: (wire.ineligible ?? []).map {
                MissionIneligibleRoute(provider: $0.provider, reasons: $0.reasons ?? [])
            }
        )
    }

    /// The engine prints microsecond ISO-8601 (`2026-09-27T15:22:34.045801+02:00`).
    /// Foundation's fractional formatter is only reliable to milliseconds, so the
    /// fraction is trimmed before a second attempt; and a missing timestamp stays
    /// `nil` rather than becoming "now".
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        if let dot = raw.firstIndex(of: "."),
           let boundary = raw[raw.index(after: dot)...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let head = raw[raw.startIndex..<dot]
            let digits = raw[raw.index(after: dot)..<boundary].prefix(3)
            let tail = raw[boundary...]
            if let date = fractional.date(from: "\(head).\(digits)\(tail)") { return date }
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private struct SuggestionWire: Decodable {
    let missionId: String
    let taskClass: String
    let recommended: CandidateWire?
    let alternatives: [CandidateWire]
    let explanation: [String]
    let warnings: [String]
    let generatedAt: String?
    let privacy: String?
    let contextEstimate: Int?
    let fallbackChain: [String]?
    let waitSuggestion: WaitWire?
    let ineligible: [IneligibleWire]?

    enum CodingKeys: String, CodingKey {
        case missionId = "mission_id"
        case taskClass = "task_class"
        case recommended, alternatives, explanation, warnings, privacy, ineligible
        case generatedAt = "generated_at"
        case contextEstimate = "context_estimate"
        case fallbackChain = "fallback_chain"
        case waitSuggestion = "suggest_wait_until"
    }
}

private struct WaitWire: Decodable {
    let provider: String
    let model: String
    let opensAtDisplay: String?
    let opensInMinutes: Int?
    let multiplier: Double?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case provider, model, multiplier, reason
        case opensAtDisplay = "opens_at_display"
        case opensInMinutes = "opens_in_minutes"
    }
}

private struct IneligibleWire: Decodable {
    let provider: String
    let reasons: [String]?
}

private struct CandidateWire: Decodable {
    let provider: String
    let model: String
    let score: Double
    let launcherCommand: String?
    let quotaHeadroom: Double?
    let reasons: [String]
    let warnings: [String]
    let launchPlan: LaunchPlanWire?
    let effort: String?
    /// Present when the provider is multi-account: which account the router
    /// selected. Cortex used to drop it, so two accounts looked like one route.
    let account: AccountWire?
    let eligible: Bool?
    let penalties: [String]?
    let statusSource: String?
    let statusAgeMinutes: Double?
    let timeMultiplier: Double?

    enum CodingKeys: String, CodingKey {
        case provider, model, score, reasons, warnings, effort, account, eligible, penalties
        case launcherCommand = "launcher_command"
        case quotaHeadroom = "quota_headroom_pct"
        case launchPlan = "launch_plan"
        case statusSource = "status_source"
        case statusAgeMinutes = "status_age_min"
        case timeMultiplier = "time_multiplier"
    }
}

private struct AccountWire: Decodable {
    let id: String?
    let alias: String?
    let identity: String?
}

private struct LaunchPlanWire: Decodable {
    let schemaVersion: Int
    let launcherId: String
    let harness: String
    let executable: String
    let arguments: [String]
    let environment: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case launcherId = "launcher_id"
        case harness, executable, arguments, environment
    }
}
