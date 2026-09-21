import Testing
@testable import ClaudeBar
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

    @Test("structured launch plan quotes argv and environment")
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
        #expect(command == "CODEX_HOME='/tmp/codex studio' 'codex' '--profile' 'Studio Team'")
    }

    @Test("mission text cannot inject shell syntax into the session name")
    func sanitizesMissionSlug() {
        #expect(MissionSessionLauncher.slug("fix'; rm -rf danger") == "fix-rm-rf-danger")
    }

    private func candidate(_ launcher: String, plan: MissionLaunchPlan? = nil) -> MissionCandidate {
        MissionCandidate(
            provider: "test",
            model: "test",
            score: 1,
            launcherCommand: launcher,
            quotaHeadroomPercent: nil,
            reasons: [],
            warnings: [],
            launchPlan: plan
        )
    }
}
