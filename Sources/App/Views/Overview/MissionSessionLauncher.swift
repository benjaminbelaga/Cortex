import AppKit
import Domain
import Foundation
import Infrastructure

/// Registers a real isolated mission through `yy mission`, then opens the
/// router-selected launcher in the returned linked worktree. No raw tmux
/// mutation and no canonical-checkout write path live in Cortex.
enum MissionSessionLauncher {
    struct Result: Sendable {
        let succeeded: Bool
        let message: String
        let command: String
    }

    private struct MissionPayload: Decodable {
        struct Repository: Decodable { let root: String }
        let missionId: String
        let sessionId: String
        let repository: Repository

        enum CodingKeys: String, CodingKey {
            case missionId = "mission_id"
            case sessionId = "session_id"
            case repository
        }
    }

    static func launch(candidate: MissionCandidate, mission: String, repoPath: String) async -> Result {
        await Task.detached(priority: .userInitiated) {
            do {
                let payload = try registerMission(
                    harness: harness(for: candidate),
                    mission: mission,
                    repoPath: repoPath
                )
                let command = resumeCommand(payload: payload, candidate: candidate)
                let launch = await TerminalCommandLauncher.open(
                    command,
                    successMessage: "Mission yy ouverte — exécution en cours"
                )
                if launch.launched {
                    AppLog.ui.info("registered mission \(payload.missionId) opened via \(candidate.provider)")
                    return Result(succeeded: true, message: launch.message, command: command)
                }
                return Result(
                    succeeded: false,
                    message: "Mission créée — \(launch.message)",
                    command: command
                )
            } catch {
                AppLog.ui.error("yy mission launcher failed: \(error.localizedDescription)")
                return Result(succeeded: false, message: error.localizedDescription, command: "")
            }
        }.value
    }

    static func harness(for candidate: MissionCandidate) -> String {
        if let harness = candidate.launchPlan?.harness { return harness }
        if candidate.launcherCommand.hasPrefix("codex") { return "codex" }
        if candidate.launcherCommand.hasPrefix("kimi") { return "kimi" }
        return "claude"
    }

    static func slug(_ mission: String) -> String {
        let folded = mission.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = folded.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .prefix(6)
            .joined(separator: "-")
        return collapsed.isEmpty ? "new" : String(collapsed.prefix(48))
    }

    private static func registerMission(
        harness: String,
        mission: String,
        repoPath: String
    ) throws -> MissionPayload {
        let yy = BinaryLocator.findInCommonPaths("yy")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/yy").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: yy)
        process.arguments = [
            "mission", harness, slug(mission),
            "--repo", repoPath,
            "--objective", mission,
            "--print-only",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw RouterQuotaIssue("yy mission failed: \(detail)")
        }
        do {
            return try JSONDecoder().decode(MissionPayload.self, from: data)
        } catch {
            throw RouterQuotaIssue("yy mission returned invalid JSON")
        }
    }

    private static func resumeCommand(payload: MissionPayload, candidate: MissionCandidate) -> String {
        "cd \(shellQuote(payload.repository.root))"
            + " && export YOYAKU_MISSION_ID=\(shellQuote(payload.missionId))"
            + " YOYAKU_MISSION_SESSION_ID=\(shellQuote(payload.sessionId))"
            + " && exec \(launchCommand(for: candidate))"
    }

    static func launchCommand(for candidate: MissionCandidate) -> String {
        guard let plan = candidate.launchPlan, plan.schemaVersion == 1 else {
            return candidate.launcherCommand
        }
        let environment = plan.environment.sorted { $0.key < $1.key }.map {
            "\($0.key)=\(shellQuote($0.value))"
        }
        let argv = ([plan.executable] + plan.arguments).map(shellQuote).joined(separator: " ")
        return ([environment.joined(separator: " "), argv]
            .filter { !$0.isEmpty })
            .joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

}
