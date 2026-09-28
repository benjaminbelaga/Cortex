import Foundation
import Infrastructure

/// App-layer production implementation of `TerminalLoginLaunching` (Claude)
/// and `CodexTerminalLoginLaunching` (Codex). Wraps `TerminalCommandLauncher.open`
/// (a UIKit concept) with per-tool shell invocations that respect the user's
/// shell conventions (PATH, env).
///
/// The shell commands mirror `AccountConnectRunner.connect(...)` minus the
/// side-effecting router/cswap steps — those are driven by `RouterRegistrar`
/// AFTER `identityConfirmed` is reached.
public struct AppleScriptTerminalLoginLauncher:
    TerminalLoginLaunching,
    CodexTerminalLoginLaunching,
    AlibabaTerminalLoginLaunching
{
    public init() {}

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // MARK: - Alibaba (bl)

    /// `bl` writes its console session into the named config profile
    /// (`~/.bailian/config.json` → `--config <name>`). The site decides which
    /// console is opened (international vs China mainland).
    public func launchLoginShell(profile: String, site: String) async -> Bool {
        let cmd = "bl auth login --console --console-site " + Self.quote(site)
            + (profile == "default" ? "" : " --config " + Self.quote(profile))
        let result = await TerminalCommandLauncher.open(
            cmd,
            successMessage: "Terminal ouvert · connectez-vous puis revenez"
        )
        return result.launched
    }

    public func launchReconnectShell(profile: String, site: String) async -> Bool {
        await launchLoginShell(profile: profile, site: site)
    }

    // MARK: - Claude

    public func launchLoginShell(profile: String) async -> Bool {
        let prefix = ClaudeProfileLocation.customDirectory(profile).map { "CLAUDE_CONFIG_DIR=" + Self.quote($0) + " " } ?? "env -u CLAUDE_CONFIG_DIR "
        let cmd = prefix + "claude auth login --claudeai"
        let result = await TerminalCommandLauncher.open(
            cmd,
            successMessage: "Terminal ouvert · connectez-vous puis revenez"
        )
        return result.launched
    }

    public func launchReconnectShell(profile: String) async -> Bool {
        let prefix = ClaudeProfileLocation.customDirectory(profile).map { "CLAUDE_CONFIG_DIR=" + Self.quote($0) + " " } ?? "env -u CLAUDE_CONFIG_DIR "
        let cmd = prefix + "claude auth login --claudeai"
        let result = await TerminalCommandLauncher.open(
            cmd,
            successMessage: "Terminal ouvert · reconnectez-vous puis revenez"
        )
        return result.launched
    }

    // MARK: - Codex

    public func launchLoginShell(codexHome: String) async -> Bool {
        let cmd = "CODEX_HOME=" + Self.quote(codexHome) + " codex login"
        let result = await TerminalCommandLauncher.open(
            cmd,
            successMessage: "Terminal ouvert · connectez-vous puis revenez"
        )
        return result.launched
    }

    public func launchReconnectShell(codexHome: String) async -> Bool {
        let cmd = "CODEX_HOME=" + Self.quote(codexHome) + " codex login"
        let result = await TerminalCommandLauncher.open(
            cmd,
            successMessage: "Terminal ouvert · reconnectez-vous puis revenez"
        )
        return result.launched
    }
}
