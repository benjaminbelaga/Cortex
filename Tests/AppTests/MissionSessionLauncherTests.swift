import Foundation
import Testing
@testable import Cortex
@testable import Infrastructure

@Suite("Mission session launcher")
struct MissionSessionLauncherTests {
    @Test("Claude and Codex account enrollment stay isolated from current logins")
    func accountEnrollmentIsIsolated() {
        let claude = AccountConnectRunner.connectCommand(
            provider: .claude, alias: "STUDIO", identity: "studio@example.com"
        )
        #expect(claude.contains("CLAUDE_CONFIG_DIR=\"$HOME/.claude-accounts/studio\""))
        #expect(claude.contains("llm-router account add claude"))
        #expect(!claude.contains("logout"))

        let codex = AccountConnectRunner.connectCommand(
            provider: .codex, alias: "STUDIO", identity: "studio@example.com"
        )
        #expect(codex.contains("CODEX_HOME=\"$HOME/.codex-accounts/studio\""))
        #expect(codex.contains("chmod 600"))
        #expect(codex.contains("llm-router account add codex"))
        #expect(!codex.contains("logout"))
    }
    @Test("maps existing launchers to the canonical yy harness")
    func mapsHarness() {
        #expect(MissionSessionLauncher.harness(for: candidate("claude-bedrock think")) == "claude")
        #expect(MissionSessionLauncher.harness(for: candidate("codex")) == "codex")
        #expect(MissionSessionLauncher.harness(for: candidate("kimi")) == "kimi")
    }

    @Test("structured launch plan quotes argv and routes environment through env")
    func structuredLaunchPlanIsShellSafe() {
        let plan = MissionLaunchPlan(
            schemaVersion: 1,
            launcherId: "codex",
            harness: "codex",
            executable: "codex",
            arguments: ["--profile", "Studio Team"],
            environment: ["CODEX_HOME": "/tmp/codex studio"]
        )
        let command = MissionSessionLauncher.launchCommand(for: candidate("codex", plan: plan))
        #expect(command == "/usr/bin/env CODEX_HOME='/tmp/codex studio' 'codex' '--profile' 'Studio Team'")
    }

    @Test("an environment-bearing launch command actually runs under the configured shells")
    func environmentLaunchRunsUnderRealShells() async throws {
        for shell in ["/bin/bash", "/bin/zsh"] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cortex-launch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("out.txt")
            let plan = MissionLaunchPlan(
                schemaVersion: 1,
                launcherId: "sh",
                harness: "claude",
                executable: "/bin/sh",
                arguments: ["-c", "printf %s \"$CORTEX_TEST\" > \"$CORTEX_OUT\""],
                environment: ["CORTEX_TEST": "demo-42", "CORTEX_OUT": output.path]
            )
            let command = MissionSessionLauncher.launchCommand(for: candidate("sh", plan: plan))
            let result = try await BoundedProcessRunner().run(
                executable: shell,
                arguments: ["-c", "exec \(command)"]
            )
            #expect(result.exitStatus == 0, "\(shell) exited \(result.exitStatus): \(result.stderrTail())")
            #expect(try String(contentsOf: output, encoding: .utf8) == "demo-42")
        }
    }

    @Test("a bare assignment after exec is not runnable — the regression this fix closes")
    func bareAssignmentAfterExecFails() async throws {
        let result = try await BoundedProcessRunner().run(
            executable: "/bin/bash",
            arguments: ["-c", "exec CORTEX_TEST='demo' /usr/bin/true"]
        )
        #expect(result.exitStatus == 127)
    }

    @Test("invalid environment names are dropped instead of breaking the command")
    func invalidEnvironmentNamesAreDropped() {
        #expect(MissionSessionLauncher.isValidEnvironmentName("OK_1"))
        #expect(!MissionSessionLauncher.isValidEnvironmentName("1BAD"))
        #expect(!MissionSessionLauncher.isValidEnvironmentName("GOOD-name"))
        let plan = MissionLaunchPlan(
            schemaVersion: 1,
            launcherId: "codex",
            harness: "codex",
            executable: "codex",
            arguments: [],
            environment: ["1BAD": "x", "GOOD-name": "y", "OK_1": "z"]
        )
        #expect(MissionSessionLauncher.launchCommand(for: candidate("codex", plan: plan))
            == "/usr/bin/env OK_1='z' 'codex'")
    }

    @Test("the bounded runner drains a multi-megabyte stdout without hanging")
    func boundedRunnerDrainsLargeOutput() async throws {
        var options = BoundedProcessRunner.Options()
        options.timeout = 30
        options.maxBytesPerStream = 8 * 1024 * 1024
        let result = try await BoundedProcessRunner().run(
            executable: "/bin/bash",
            arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' 'x'"],
            options: options
        )
        #expect(result.exitStatus == 0)
        #expect(result.stdout.count == 3_000_000)
    }

    @Test("mission text cannot inject shell syntax into the session name")
    func sanitizesMissionSlug() {
        #expect(MissionSessionLauncher.slug("fix'; rm -rf danger") == "fix-rm-rf-danger")
    }

    private func candidate(
        _ launcher: String,
        plan: MissionLaunchPlan? = nil,
        effort: String? = nil,
        account: MissionAccount? = nil
    ) -> MissionCandidate {
        MissionCandidate(
            provider: "test",
            model: "test",
            score: 1,
            launcherCommand: launcher,
            quotaHeadroomPercent: nil,
            reasons: [],
            warnings: [],
            launchPlan: plan,
            effort: effort,
            account: account
        )
    }
}
