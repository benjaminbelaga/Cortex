import Foundation
import Domain

/// Probe seam for `bl auth status --output json`. Tests inject a stub that
/// returns canned `AlibabaAuthStatus`; production wires `AlibabaAuthStatusCLIProbe`
/// which shells out through `BoundedProcessRunner`.
///
/// Return semantics:
/// - `nil` = the probe could not run (binary missing, JSON malformed, I/O
///           cancelled, non-zero exit). Distinct from a clean "not
///           authenticated" reply.
/// - some  = the JSON parsed. `authenticated=false` is a *valid* reply.
public protocol AlibabaAuthStatusProbing: Sendable {
    func authStatus(profile: String) async -> AlibabaAuthStatus?
}

/// Production probe. Runs `bl auth status --output json` scoped to the named
/// config profile (`--config`), parses the JSON, and returns `nil` on any
/// non-zero exit / parse failure / cancellation.
///
/// `bl` is a Node CLI shipped as a launcher script; a cold start measures
/// ~15 s on Ben's Mac, so the deadline is generous but bounded (the console
/// call path learned the same lesson — see the Alibaba quota rail).
public struct AlibabaAuthStatusCLIProbe: AlibabaAuthStatusProbing {
    public let binary: String
    public let timeout: TimeInterval

    public init(binary: String = "bl", timeout: TimeInterval = 30) {
        self.binary = binary
        self.timeout = timeout
    }

    public func authStatus(profile: String) async -> AlibabaAuthStatus? {
        guard let executable = BinaryLocator.findInCommonPaths(binary)
            ?? BinaryLocator.which(binary) else { return nil }
        var arguments = ["auth", "status", "--output", "json"]
        // `default` means "the active profile": passing `--config default`
        // would demand a profile literally named `default` and fail closed on
        // a machine that only has a named one.
        if !profile.isEmpty, profile != "default" {
            arguments += ["--config", profile]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = BinaryLocator.shellPath()
        let result: ProcessRunResult
        do {
            result = try await BoundedProcessRunner().run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                options: .init(timeout: timeout, maxBytesPerStream: 1 << 20, terminationGrace: 1)
            )
        } catch {
            AppLog.probes.debug("bl auth status probe failed: \(error.localizedDescription)")
            return nil
        }
        guard result.exitStatus == 0 else { return nil }
        do {
            return try JSONDecoder().decode(AlibabaAuthStatus.self, from: result.stdout)
        } catch {
            AppLog.probes.debug("bl auth status parse failed: \(error)")
            return nil
        }
    }
}

/// Terminal-launcher seam for the Alibaba interactive login flow. The
/// production App-layer implementation lives in
/// `Sources/App/Accounts/AppleScriptTerminalLoginLauncher.swift` (same launch
/// plumbing as Claude/Codex; only the shell command differs).
public protocol AlibabaTerminalLoginLaunching: Sendable {
    func launchLoginShell(profile: String, site: String) async -> Bool
    func launchReconnectShell(profile: String, site: String) async -> Bool
}
