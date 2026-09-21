import Foundation
import Domain

/// Minimal authenticated identity returned by `claude auth status --json`.
public struct ClaudeAuthenticatedAccount: Sendable, Equatable, Decodable {
    public let loggedIn: Bool
    public let email: String?
}

/// Bounded, read-only validation seam for first-run account discovery.
/// Async since upstream v0.4.9x made `CLIExecutor.execute` async — probes
/// must never block the cooperative pool.
public protocol ClaudeAccountStatusValidating: Sendable {
    func authenticatedAccount(configDirectory: String) async -> ClaudeAuthenticatedAccount?
}

/// Validates a candidate with the CLI command supported by current Claude Code.
/// `claude auth list` is intentionally not used: it is not a supported command.
public struct ClaudeCLIAccountStatusValidator: ClaudeAccountStatusValidating {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func authenticatedAccount(configDirectory: String) async -> ClaudeAuthenticatedAccount? {
        let executor = DefaultCLIExecutor(
            environmentExclusions: ["CLAUDE_CODE_OAUTH_TOKEN"],
            environmentAdditions: ["CLAUDE_CONFIG_DIR": configDirectory]
        )
        guard let binary = executor.locate("claude"),
              let result = try? await executor.execute(
                binary: binary,
                args: ["auth", "status", "--json"],
                input: nil,
                timeout: timeout,
                workingDirectory: nil,
                autoResponses: [:]
              ),
              result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let account = try? JSONDecoder().decode(ClaudeAuthenticatedAccount.self, from: data),
              account.loggedIn else {
            return nil
        }
        return account
    }
}

/// Discovers isolated Claude configuration directories on the first run only.
/// Existing settings are authoritative and returned untouched.
public struct ClaudeAccountDiscovery {
    private let fileManager: FileManager
    private let validator: any ClaudeAccountStatusValidating

    public init(
        fileManager: FileManager = .default,
        validator: any ClaudeAccountStatusValidating = ClaudeCLIAccountStatusValidator()
    ) {
        self.fileManager = fileManager
        self.validator = validator
    }

    public func discover(
        homeDirectory: String = NSHomeDirectory(),
        existing: [ProviderAccountConfig]
    ) async -> [ProviderAccountConfig] {
        guard existing.isEmpty else { return existing }

        var candidates: [(accountId: String, label: String, configDirectory: String)] = []
        let defaultJSON = (homeDirectory as NSString).appendingPathComponent(".claude.json")
        if fileManager.fileExists(atPath: defaultJSON) {
            candidates.append(("default", "Default", homeDirectory))
        }

        let contents = (try? fileManager.contentsOfDirectory(atPath: homeDirectory))?.sorted() ?? []
        for item in contents where item.hasPrefix(".claude-") {
            let configDirectory = (homeDirectory as NSString).appendingPathComponent(item)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: configDirectory, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.fileExists(
                    atPath: (configDirectory as NSString).appendingPathComponent(".claude.json")
                  ) else { continue }
            let rawId = String(item.dropFirst(".claude-".count))
            let accountId = rawId.lowercased()
            guard !accountId.isEmpty else { continue }
            candidates.append((accountId, rawId.capitalized, configDirectory))
        }

        var seen = Set<String>()
        var discovered: [ProviderAccountConfig] = []
        for candidate in candidates {
            guard seen.insert(candidate.accountId).inserted else { continue }
            guard let authenticated = await validator.authenticatedAccount(
                configDirectory: candidate.configDirectory
            ) else { continue }
            discovered.append(ProviderAccountConfig(
                accountId: candidate.accountId,
                label: candidate.label,
                email: authenticated.email,
                probeConfig: ["claudeConfigDir": candidate.configDirectory]
            ))
        }
        return discovered
    }
}
