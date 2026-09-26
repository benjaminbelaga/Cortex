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
        /// Steps actually proven — "terminal opened" is not "mission running"
        /// (audit V2 §3). A receipt lets the UI stop claiming more than it knows.
        let receipt: [String]

        init(succeeded: Bool, message: String, command: String, receipt: [String] = []) {
            self.succeeded = succeeded
            self.message = message
            self.command = command
            self.receipt = receipt
        }
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
            var receipt: [String] = []
            do {
                let payload = try await registerMission(
                    harness: harness(for: candidate),
                    mission: mission,
                    repoPath: repoPath
                )
                receipt.append("mission \(payload.missionId) registered")
                let command = resumeCommand(payload: payload, candidate: candidate)
                let launch = await TerminalCommandLauncher.open(
                    command,
                    successMessage: "Mission registered — terminal opened (no proof of work yet)"
                )
                guard launch.launched else {
                    return Result(
                        succeeded: false,
                        message: "Mission created — \(launch.message)",
                        command: command,
                        receipt: receipt
                    )
                }
                receipt.append("terminal opened")
                AppLog.ui.info("registered mission \(payload.missionId) opened via \(candidate.provider)")
                return Result(succeeded: true, message: launch.message, command: command, receipt: receipt)
            } catch {
                AppLog.ui.error("yy mission launcher failed: \(error.localizedDescription)")
                return Result(
                    succeeded: false,
                    message: error.localizedDescription,
                    command: "",
                    receipt: receipt
                )
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

    /// Runs `yy mission … --print-only` through the bounded runner: stdout and
    /// stderr are drained from launch, so a chatty child cannot fill the pipe and
    /// hang the caller (the previous `waitUntilExit()`-before-read pattern could
    /// block until the timeout, audit V2-06).
    private static func registerMission(
        harness: String,
        mission: String,
        repoPath: String
    ) async throws -> MissionPayload {
        let yy = BinaryLocator.findInCommonPaths("yy")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/yy").path
        var options = BoundedProcessRunner.Options()
        options.timeout = 20
        options.maxBytesPerStream = 1_048_576
        let result: ProcessRunResult
        do {
            result = try await BoundedProcessRunner().run(
                executable: yy,
                arguments: [
                    "mission", harness, slug(mission),
                    "--repo", repoPath,
                    "--objective", mission,
                    "--print-only",
                ],
                options: options
            )
        } catch {
            throw RouterQuotaIssue("yy mission could not run: \(error)")
        }
        guard result.exitStatus == 0 else {
            let detail = result.stderrTail()
            throw RouterQuotaIssue(
                "yy mission failed: \(detail.isEmpty ? "exit \(result.exitStatus)" : detail)"
            )
        }
        do {
            return try JSONDecoder().decode(MissionPayload.self, from: result.stdout)
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

    /// Environment assignments must survive `exec`: `exec KEY=value cmd` is not a
    /// valid command — bash 3.2 and zsh both answer `command not found` and exit
    /// 127 (verified on this Mac), so a plan with an environment never launched.
    /// Route assignments through `/usr/bin/env`, which is a real executable.
    static func launchCommand(for candidate: MissionCandidate) -> String {
        guard let plan = candidate.launchPlan, plan.schemaVersion == 1 else {
            return candidate.launcherCommand
        }
        let environment = plan.environment
            .filter { isValidEnvironmentName($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value))" }
        let argv = ([plan.executable] + plan.arguments).map(shellQuote).joined(separator: " ")
        guard !environment.isEmpty else { return argv }
        return (["/usr/bin/env"] + environment + [argv]).joined(separator: " ")
    }

    /// POSIX variable names only — anything else cannot be expressed as an
    /// environment assignment and would break the whole command.
    static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

}
