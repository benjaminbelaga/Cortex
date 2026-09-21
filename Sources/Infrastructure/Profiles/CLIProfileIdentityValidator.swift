import Foundation
import Domain

/// Production identity validator for the account catalogue's discovery sweep
/// (`AccountDiscoveryService`). Reads back the authenticated email from an
/// isolated profile through each tool's OFFICIAL read-only status surface —
/// `claude auth status --json` under `CLAUDE_CONFIG_DIR`, and the Codex
/// app-server `account/read` RPC under `CODEX_HOME`. Never writes, never
/// copies tokens, never falls back to the global profile.
public struct CLIProfileIdentityValidator: ProfileIdentityValidating {
    private let claude: ClaudeCLIAccountStatusValidator
    private let codex: any CodexAuthStatusProbing

    public init(
        claude: ClaudeCLIAccountStatusValidator = ClaudeCLIAccountStatusValidator(),
        codex: any CodexAuthStatusProbing = CodexAuthStatusRPCProbe()
    ) {
        self.claude = claude
        self.codex = codex
    }

    public func authenticatedEmail(
        forProvider providerId: String,
        profilePath: String
    ) async -> String? {
        switch providerId {
        case "claude":
            return await claude.authenticatedAccount(configDirectory: profilePath)?.email
        case "codex":
            return await codex.authStatus(codexHome: profilePath)?.email
        default:
            // Unknown tool family: no fabricated identity, no probe — the
            // profile simply does not surface as authenticated.
            return nil
        }
    }
}
