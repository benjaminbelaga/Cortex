import Foundation
import Domain

/// Settings contain references only. A missing managed key never falls back to another account.
public enum APIAccountCredentials {
    public static func probe(providerId: String, config: ProviderAccountConfig,
                             credentials: any CredentialRepository = KeychainCredentialRepository.shared) -> any UsageProbe {
        guard let key = key(providerId: providerId, config: config, credentials: credentials) else {
            return MissingCredentialProbe()
        }
        return probe(providerId: providerId, apiKey: key)
    }

    /// The copyable key of one account, resolved through the SAME references
    /// the probe uses (managed Keychain item, OpenCode Go pool slot, Command
    /// Code CLI slot). nil when the provider has no copyable key — a caller
    /// must never invent one. Values stay in-process: callers hand the result
    /// to a concealed pasteboard, never to a log.
    public static func key(providerId: String, config: ProviderAccountConfig,
                           credentials: any CredentialRepository = KeychainCredentialRepository.shared,
                           homeDirectory: String = NSHomeDirectory()) -> String? {
        let key: String?
        if let reference = config.probeConfig["credentialKey"] {
            key = credentials.get(forKey: reference)
        } else if providerId == "opencode-go", let slot = config.probeConfig["externalSlot"] {
            key = OpenCodeCredentialLoader(homeDirectory: homeDirectory).loadPool().first { $0.slot == slot }?.key
        } else if providerId == "ollama", let slot = config.probeConfig["externalSlot"] {
            key = OpenCodeCredentialLoader.ollamaCloud(homeDirectory: homeDirectory).loadPool().first { $0.slot == slot }?.key
        } else if providerId == "commandcode", let slot = config.probeConfig["externalSlot"] {
            key = CommandCodeCredentialLoader(homeDirectory: homeDirectory).loadPool().first { $0.slot == slot }?.key
        } else {
            key = nil
        }
        guard let key, !key.isEmpty else { return nil }
        return key
    }

    public static func probe(providerId: String, apiKey: String) -> any UsageProbe {
        switch providerId {
        case "opencode-go": return OpenCodeAPIUsageProbe(apiKey: apiKey)
        case "commandcode": return CommandCodeUsageProbe(apiKey: apiKey)
        case "ollama": return OllamaCloudUsageProbe(apiKey: apiKey)
        default: return MissingCredentialProbe()
        }
    }

    /// Adopt installed CLI slots once; future removals are not undone on launch.
    public static func importLocalAccounts(settings: JSONSettingsRepository) {
        for provider in ["opencode-go", "commandcode"] {
            guard !settings.hasImportedAPIAccounts(forProvider: provider) else { continue }
            var entries: [(String, String)] = []
            if provider == "opencode-go" {
                entries = OpenCodeCredentialLoader().loadPool().enumerated().map {
                    ($0.element.slot, $0.element.label ?? "Account \($0.offset + 1)")
                }
            } else {
                entries = CommandCodeCredentialLoader().loadPool().enumerated().map {
                    ($0.element.slot, $0.element.label ?? "Account \($0.offset + 1)")
                }
            }
            for (slot, label) in entries {
                let id = "imported-" + slot
                guard !settings.accounts(forProvider: provider).contains(where: { $0.accountId == id }) else { continue }
                settings.addAccount(.init(accountId: id, label: label,
                    probeConfig: ["externalSlot": slot, "source": "native", "accountUUID": UUID().uuidString]),
                    forProvider: provider)
            }
            if !entries.isEmpty { settings.setImportedAPIAccounts(forProvider: provider) }
        }
    }
}

private struct MissingCredentialProbe: UsageProbe {
    func isAvailable() async -> Bool { false }
    func probe() async throws -> UsageSnapshot { throw ProbeError.authenticationRequired }
}
