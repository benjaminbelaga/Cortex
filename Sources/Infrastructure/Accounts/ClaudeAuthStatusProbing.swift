import Foundation
import Domain

/// Probe seam for `claude auth status --json`. Tests inject a stub that
/// returns canned `ClaudeAuthStatus` values; production wires
/// `ClaudeAuthStatusCLIProbe` which shells out through `BoundedProcessRunner`.
///
/// Return semantics:
/// - `nil`   = the probe could not run (binary missing, JSON malformed, I/O
///             cancelled). Distinct from a clean "not logged in" reply.
/// - some    = the JSON was parsed. `loggedIn=false` is a *valid* reply
///             distinct from `nil` — the CLI spoke, the answer is no.
public protocol ClaudeAuthStatusProbing: Sendable {
    func authStatus(configDirectory: String) async -> ClaudeAuthStatus?
}

/// Production probe. Runs `claude auth status --json` with
/// `CLAUDE_CONFIG_DIR=<dir>` injected via env, parses the JSON, and returns
/// `nil` on any non-zero exit / parse failure / cancellation.
///
/// `BoundedProcessRunner` already handles backpressure, truncation, and
/// deadline — a 5 s cap is plenty for a synchronous JSON reply.
public struct ClaudeAuthStatusCLIProbe: ClaudeAuthStatusProbing {
    public let binary: String
    public let timeout: TimeInterval

    public init(
        binary: String = "claude",
        timeout: TimeInterval = 5
    ) {
        self.binary = binary
        self.timeout = timeout
    }

    public func authStatus(configDirectory: String) async -> ClaudeAuthStatus? {
        guard let executable = BinaryLocator.which(binary) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = BinaryLocator.shellPath()
        environment["CLAUDE_CONFIG_DIR"] = ClaudeProfileLocation.customDirectory(configDirectory)
        let runner = BoundedProcessRunner()
        let result: ProcessRunResult
        do {
            result = try await runner.run(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                environment: environment,
                options: .init(timeout: timeout, maxBytesPerStream: 1 << 20, terminationGrace: 1)
            )
        } catch {
            AppLog.probes.debug(
                "claude auth status probe failed: \(error.localizedDescription)"
            )
            return nil
        }
        guard result.exitStatus == 0 else { return nil }
        do {
            return try JSONDecoder().decode(ClaudeAuthStatus.self, from: result.stdout)
        } catch {
            AppLog.probes.debug("claude auth status parse failed: \(error)")
            return nil
        }
    }
}

/// Terminal-launcher seam for the interactive login flow. The user is in the
/// driver's seat at this point — the adapter polls the auth status in the
/// background and decides when to surface `.identityConfirmed`/`.failed`.
///
/// `Bool` return = whether the terminal was successfully spawned. A `false`
/// does NOT abort enrolment — it just means the user has to relaunch the
/// command themselves (the sheet degrades to a "Copié dans le presse-papier"
/// hint).
///
/// The protocol lives in Infrastructure; the AppKit-backed production
/// implementation lives in `Sources/App/Accounts/AppleScriptTerminalLoginLauncher.swift`
/// where the App layer's `TerminalCommandLauncher` (a UIKit concept) is in scope.
public protocol TerminalLoginLaunching: Sendable {
    func launchLoginShell(profile: String) async -> Bool
    func launchReconnectShell(profile: String) async -> Bool
}
