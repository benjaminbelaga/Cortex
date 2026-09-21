import Foundation
import Domain

/// Settings contain references only. A missing managed key never falls back to another account.
public enum APIAccountCredentials {
    public static func probe(providerId: String, config: ProviderAccountConfig,
                             credentials: any CredentialRepository = KeychainCredentialRepository.shared) -> any UsageProbe {
        let key: String?
        if let reference = config.probeConfig["credentialKey"] {
            key = credentials.get(forKey: reference)
        } else if providerId == "opencode-go", let slot = config.probeConfig["externalSlot"] {
            key = OpenCodeCredentialLoader().loadPool().first { $0.slot == slot }?.key
        } else if providerId == "commandcode", config.probeConfig["externalSlot"] == "cli" {
            key = CommandCodeCredentialLoader().loadAPIKey()
        } else {
            key = nil
        }
        guard let key, !key.isEmpty else { return MissingCredentialProbe() }
        return probe(providerId: providerId, apiKey: key)
    }

    public static func probe(providerId: String, apiKey: String) -> any UsageProbe {
        switch providerId {
        case "opencode-go": return OpenCodeAPIUsageProbe(apiKey: apiKey)
        case "commandcode": return CommandCodeUsageProbe(apiKey: apiKey)
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
            } else if CommandCodeCredentialLoader().loadAPIKey() != nil {
                entries = [("cli", "Account 1")]
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
