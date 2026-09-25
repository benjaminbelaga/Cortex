import Testing
import Foundation
@testable import Cortex

/// Executes the shell command produced by `AccountConnectRunner.connectCommand`
/// against stub `codex`/`llm-router`/`cswap`/`claude` binaries in an isolated
/// HOME, and asserts the registration step (`llm-router account add`) runs ONLY
/// when every preceding step succeeded. The Codex chain's `&&`/`||` precedence
/// bug let a failed login still register the account — this pins the fixed
/// behaviour (parenthesized `test || chmod`).
@Suite("AccountConnectRunner generated command")
struct AccountConnectRunnerCommandTests {

    private struct RunOutcome {
        let exitCode: Int32
        let calls: String
    }

    /// Writes stub executables that log their argv to `$HOME/calls.log` and exit
    /// with a per-command code from an env var (default 0).
    private func makeSandbox() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("acr-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["codex", "llm-router", "cswap", "claude"] {
            let envKey = tool.uppercased().replacingOccurrences(of: "-", with: "_") + "_EXIT"
            let script = "#!/bin/sh\necho \"\(tool) $*\" >> \"$HOME/calls.log\"\nexit ${\(envKey):-0}\n"
            let url = bin.appendingPathComponent(tool)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
        return home
    }

    private func run(
        _ command: String,
        home: URL,
        env extra: [String: String] = [:]
    ) throws -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var env = [
            "HOME": home.path,
            "PATH": home.appendingPathComponent("bin").path + ":/usr/bin:/bin",
        ]
        for (key, value) in extra { env[key] = value }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let log = home.appendingPathComponent("calls.log")
        let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return RunOutcome(exitCode: process.terminationStatus, calls: calls)
    }

    // MARK: - The bug: a failed Codex login must never register the account.

    @Test("Codex login failure with a stale auth.json does not register")
    func codexLoginFailureWithStaleAuthDoesNotRegister() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent(".codex-accounts/studio")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "stale".write(
            to: profile.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )

        let cmd = AccountConnectRunner.connectCommand(provider: .codex, alias: "STUDIO", identity: nil)
        let outcome = try run(cmd, home: home, env: ["CODEX_EXIT": "1"])

        #expect(outcome.exitCode != 0)
        #expect(outcome.calls.contains("codex login"))
        #expect(!outcome.calls.contains("llm-router account add"))
    }

    @Test("Codex success without auth.json (keychain) still registers")
    func codexSuccessKeychainRegisters() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let cmd = AccountConnectRunner.connectCommand(provider: .codex, alias: "STUDIO", identity: nil)
        let outcome = try run(cmd, home: home)
        #expect(outcome.exitCode == 0)
        #expect(outcome.calls.contains("llm-router account add codex"))
    }

    @Test("Codex success with auth.json tightens permissions and registers")
    func codexSuccessWithAuthRegisters() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent(".codex-accounts/studio")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let authURL = profile.appendingPathComponent("auth.json")
        try "tok".write(to: authURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authURL.path)

        let cmd = AccountConnectRunner.connectCommand(provider: .codex, alias: "STUDIO", identity: nil)
        let outcome = try run(cmd, home: home)
        #expect(outcome.exitCode == 0)
        #expect(outcome.calls.contains("llm-router account add codex"))
        let mode = try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("Claude login failure does not register the account")
    func claudeLoginFailureDoesNotRegister() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let cmd = AccountConnectRunner.connectCommand(
            provider: .claude, alias: "STUDIO", identity: "studio@example.com"
        )
        let outcome = try run(cmd, home: home, env: ["CLAUDE_EXIT": "1"])
        #expect(outcome.exitCode != 0)
        #expect(!outcome.calls.contains("llm-router account add"))
    }

    @Test("Alias with spaces and accents yields a safe slug and quoted alias")
    func aliasWithSpacesAndAccents() {
        let cmd = AccountConnectRunner.connectCommand(
            provider: .claude, alias: "Compte Ephemere", identity: nil
        )
        #expect(cmd.contains(".claude-accounts/compte-ephemere"))
        #expect(cmd.contains("--alias 'COMPTE EPHEMERE'"))
    }

    // MARK: - Declared auth home (router seats)

    @Test("Claude profile override reuses the declared auth home, never mints one")
    func claudeProfileOverrideReusesDeclaredAuthHome() {
        let cmd = AccountConnectRunner.connectCommand(
            provider: .claude, alias: "TECH", identity: "tech@yoyaku.fr",
            profileOverride: "/Users/example/.claude-tech"
        )
        #expect(cmd.contains("CLAUDE_CONFIG_DIR='/Users/example/.claude-tech'"))
        #expect(cmd.contains("--auth-home '/Users/example/.claude-tech'"))
        #expect(!cmd.contains(".claude-accounts"))
    }

    @Test("Codex profile override runs login and registrar in the declared home")
    func codexProfileOverrideRegistersDeclaredHome() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let declared = home.appendingPathComponent(".codex-tech")
        try FileManager.default.createDirectory(at: declared, withIntermediateDirectories: true)

        let cmd = AccountConnectRunner.connectCommand(
            provider: .codex, alias: "TECH", identity: nil, profileOverride: declared.path
        )
        let outcome = try run(cmd, home: home)

        #expect(outcome.exitCode == 0)
        #expect(outcome.calls.contains("llm-router account add codex"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex-accounts/tech").path))
    }
}
