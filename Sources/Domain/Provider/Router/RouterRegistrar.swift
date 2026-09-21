import Foundation

/// Where the router registrar wants the account to land — used by the
/// registrar to pick the right `account add` flags. Mirrors
/// `AccountSource` on the Account side; the registrar ONLY sees this when
/// the user has explicitly opted into router-mode via settings.
public enum RouterAccountTarget: String, Sendable, Equatable, Codable {
    case claude
    case codex
}

/// Pure-Domain command constructor for `llm-router account add ...`. Lives
/// in Domain (no I/O) so the registrar's argument assembly is testable
/// without spawning a binary. The Infrastructure layer runs the produced
/// argv via `BoundedProcessRunner` (already battle-tested from PR A).
///
/// `authHome` carries the isolated config dir for Claude (`CLAUDE_CONFIG_DIR`)
/// or Codex (`CODEX_HOME`), depending on `target`.
public struct RouterRegistrationRequest: Sendable, Equatable {
    public let target: RouterAccountTarget
    public let alias: String
    public let authHome: String
    public let verifiedIdentity: VerifiedIdentity

    public init(
        target: RouterAccountTarget,
        alias: String,
        authHome: String,
        verifiedIdentity: VerifiedIdentity
    ) {
        self.target = target
        self.alias = alias
        self.authHome = authHome
        self.verifiedIdentity = verifiedIdentity
    }

    /// Build argv for `llm-router account add <target> --alias ALIAS
    /// --auth-home PATH --verified-identity EMAIL --auth-state connected`.
    /// The `llm-router` README confirms `account add` accepts these flags;
    /// `--auth-state connected` is mandatory on success — the brief audit
    /// (Q1 2026) caught a real bug where a failed login still got
    /// `--auth-state connected` recorded.
    public func arguments() -> [String] {
        switch target {
        case .claude:
            return [
                "account", "add", "claude",
                "--alias", alias,
                "--auth-home", authHome,
                "--verified-identity", verifiedIdentity.email,
                "--auth-state", "connected",
            ]
        case .codex:
            return [
                "account", "add", "codex",
                "--alias", alias,
                "--codex-home", authHome,
                "--verified-identity", verifiedIdentity.email,
                "--auth-state", "connected",
            ]
        }
    }
}

/// Outcome of a successful `llm-router account add` invocation. Parsed from
/// the JSON line the router emits on stderr (`{"result":"ok","alias":...}`).
/// A nil `result` payload means the registrar saw a non-JSON stdout/stderr
/// reply — the caller surfaces the raw stderr tail as a `.registryRejected`
/// error.
public struct RouterRegistrationOutcome: Sendable, Equatable {
    public let alias: String
    public let rawStdout: String
    public let rawStderr: String

    public init(alias: String, rawStdout: String, rawStderr: String) {
        self.alias = alias
        self.rawStdout = rawStdout
        self.rawStderr = rawStderr
    }
}

/// Router-registration seam. Production wires `RouterRegistrarCLI`; tests
/// inject a fake that records the request and returns a canned outcome.
public protocol RouterRegistering: Sendable {
    func register(_ request: RouterRegistrationRequest) async throws -> RouterRegistrationOutcome
}
