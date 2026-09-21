import Foundation

/// Small, credential-free projection of Ben's shared harness runtime. It keeps
/// operational facts next to usage without making Cortex another state owner:
/// agentctl, Claude hooks, and the canonical shared skill tree remain SSOT.
public struct LLMRuntimeSnapshot: Sendable, Equatable {
    public let activeMissions: Int?
    public let configuredHooks: Int
    public let sharedSkills: Int

    public init(activeMissions: Int?, configuredHooks: Int, sharedSkills: Int) {
        self.activeMissions = activeMissions
        self.configuredHooks = configuredHooks
        self.sharedSkills = sharedSkills
    }
}

public enum LLMRuntimeInspector {
    public static func read() async -> LLMRuntimeSnapshot {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return LLMRuntimeSnapshot(
                activeMissions: await activeMissionCount(),
                configuredHooks: hookCount(
                    at: home.appendingPathComponent(".claude/settings.json")
                ),
                sharedSkills: skillCount(
                    at: home.appendingPathComponent(".claude/skills", isDirectory: true)
                )
            )
        }.value
    }

    public static func missionCount(from data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let missions = root["missions"] as? [[String: Any]] else { return nil }
        return missions.count
    }

    public static func configuredHookCount(from data: Data) -> Int {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return 0 }
        return hooks.values.reduce(0) { total, value in
            guard let entries = value as? [Any] else { return total }
            return total + entries.count
        }
    }

    private static func activeMissionCount() async -> Int? {
        await Task.detached(priority: .utility) { () -> Int? in
            let candidates = [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/agentctl").path,
                "/opt/homebrew/bin/agentctl",
                "/usr/local/bin/agentctl",
            ]
            guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
                return nil
            }
            return await runAgentctlMissionList(executable: executable)
        }.value
    }

    /// Runs `agentctl mission list --status active` through the shared
    /// `BoundedProcessRunner`.
    ///
    /// This used to call `waitUntilExit()` with no upper bound: an agentctl that
    /// blocks (dead interpreter, held DB lock) left the child alive forever and
    /// every refresh stacked another one — 17 orphans over 10 days, each holding
    /// a Python interpreter, observed 2026-09-19. The runner gives the child a
    /// deadline and reaps it, and it drains output concurrently so a large
    /// response cannot deadlock on a full pipe.
    static func runAgentctlMissionList(executable: String) async -> Int? {
        await runAgentctlMissionListWithDeadline(
            executable: executable,
            arguments: ["mission", "list", "--status", "active"],
            timeoutSeconds: 10
        )
    }

    /// Testable core: same bounded path with an injectable command and deadline.
    static func runAgentctlMissionListWithDeadline(
        executable: String, arguments: [String], timeoutSeconds: TimeInterval
    ) async -> Int? {
        let runner = BoundedProcessRunner()
        let result = try? await runner.run(
            executable: executable,
            arguments: arguments,
            options: .init(timeout: timeoutSeconds, maxBytesPerStream: 4 * 1024 * 1024)
        )
        guard let result, result.exitStatus == 0 else { return nil }
        return missionCount(from: result.stdout)
    }

    private static func hookCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return configuredHookCount(from: data)
    }

    private static func skillCount(at directory: URL) -> Int {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return children.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
        }.count
    }
}
