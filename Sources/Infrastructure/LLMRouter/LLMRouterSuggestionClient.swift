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

public struct MissionCandidate: Sendable, Equatable, Identifiable {
    public var id: String { "\(provider):\(model)" }
    public let provider: String
    public let model: String
    public let score: Double
    public let launcherCommand: String
    public let quotaHeadroomPercent: Double?
    public let reasons: [String]
    public let warnings: [String]
    public let launchPlan: MissionLaunchPlan?
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
            throw RouterQuotaIssue("Décris d’abord la mission")
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
                }
            )
        }
        guard !candidates.isEmpty else {
            throw RouterQuotaIssue("Aucune route lançable n’est disponible")
        }
        return MissionSuggestion(
            missionId: wire.missionId,
            taskClass: wire.taskClass,
            candidates: Array(candidates.prefix(3)),
            explanation: wire.explanation,
            warnings: wire.warnings
        )
    }
}

private struct SuggestionWire: Decodable {
    let missionId: String
    let taskClass: String
    let recommended: CandidateWire?
    let alternatives: [CandidateWire]
    let explanation: [String]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case missionId = "mission_id"
        case taskClass = "task_class"
        case recommended, alternatives, explanation, warnings
    }
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

    enum CodingKeys: String, CodingKey {
        case provider, model, score, reasons, warnings
        case launcherCommand = "launcher_command"
        case quotaHeadroom = "quota_headroom_pct"
        case launchPlan = "launch_plan"
    }
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
