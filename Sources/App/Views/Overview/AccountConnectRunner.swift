import AppKit
import Foundation
import Infrastructure

/// Launches a GUIDED web account connect sequence (E2E verdict: `cswap add`
/// alone captures the CURRENT CLI account, so it can never connect a second
/// one; headless bot tokens lack the usage scope permanently, HTTP 403
/// `user:profile`). The sequence runs in an isolated CLAUDE_CONFIG_DIR so the
/// live credential is never touched: login → cswap add → list. iTerm hosts it
/// because `claude login` needs a browser round-trip; clipboard is the degraded
/// mode when iTerm/TCC is unavailable.
///
/// PR C removes `connectCurrent()` (hardcoded account alias — the bug from
/// the Q1 audit). The typed state machine + multi-account support now lives
/// in `AccountEnrolmentService` and `ClaudeAccountAdapter` /
/// `CodexAccountAdapter`. The connect(...) below is kept for the URL-paste
/// sheet that does NOT go through enrolment (legacy recoverable); PR D will
/// rewire its call sites.
enum AccountConnectRunner {
    enum Provider: String, CaseIterable, Sendable {
        case claude
        case codex

        var displayName: String { rawValue.capitalized }
    }

    struct Result: Sendable {
        let succeeded: Bool
        /// Short single-line message surfaced inline in the row.
        let message: String
    }

    static func connect(provider: Provider, alias: String, identity: String?) async -> Result {
        let sequence = connectCommand(provider: provider, alias: alias, identity: identity)
        let launch = await TerminalCommandLauncher.open(
            sequence,
            successMessage: "Terminal ouvert — login et vérification en cours"
        )
        return Result(succeeded: launch.launched, message: launch.message)
    }

    static func connectCommand(provider: Provider, alias: String, identity: String?) -> String {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let slug = String(
            normalizedAlias.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
                .split(separator: "-", omittingEmptySubsequences: true)
                .joined(separator: "-")
        )
        let safeSlug = slug.isEmpty ? "account" : slug
        let aliasArg = shellQuote(normalizedAlias)
        let identityArg = identity.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : shellQuote(trimmed)
        }
        let identityFlag = identityArg.map { " --identity \($0)" } ?? ""
        let loginEmail = identityArg ?? "''"
        let verifiedIdentity = identityArg ?? "''"

        switch provider {
        case .claude:
            let profile = "$HOME/.claude-accounts/\(safeSlug)"
            return "mkdir -p \"\(profile)\""
                + " && (CLAUDE_CONFIG_DIR=\"\(profile)\" claude auth status 2>/dev/null | grep -q '\\\"loggedIn\\\": true'"
                + " || CLAUDE_CONFIG_DIR=\"\(profile)\" claude auth login --claudeai --email \(loginEmail) )"
                + " && CLAUDE_CONFIG_DIR=\"\(profile)\" cswap add --alias \(aliasArg)"
                + " && llm-router account add claude --alias \(aliasArg)\(identityFlag)"
                + " --auth-state connected --launcher-profile \(aliasArg)"
                + " --auth-home \"\(profile)\" --verified-identity \(verifiedIdentity)"
                + " && cswap list --token-status"
        case .codex:
            let profile = "$HOME/.codex-accounts/\(safeSlug)"
            return "mkdir -p \"\(profile)\" && chmod 700 \"\(profile)\""
                + " && CODEX_HOME=\"\(profile)\" codex login"
                + " && (test ! -f \"\(profile)/auth.json\" || chmod 600 \"\(profile)/auth.json\")"
                + " && llm-router account add codex --alias \(aliasArg)\(identityFlag)"
                + " --auth-state connected --codex-home \"\(profile)\""
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

}
