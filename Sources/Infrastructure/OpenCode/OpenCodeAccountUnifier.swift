import Foundation
import Domain

/// Moves OpenCode Go (or Ollama Cloud, with the `ollama_pool` loader) accounts
/// that Cortex stored in its own Keychain onto the
/// shared failover pool, so every Go key lives in ONE place (auth.json slot +
/// failover SSOT) and also feeds opencode's rotation.
///
/// Per Keychain-backed account: if its key already sits in a pool slot, the
/// account is re-pointed at that slot (`externalSlot`); if another Cortex
/// account already shows that slot, this one is a duplicate and is dropped from
/// the roster; otherwise the key is enrolled into the pool first. The Keychain
/// item itself is never deleted here (reported as orphan for a deliberate
/// cleanup). Runs inside Cortex, so reading its own Keychain items never
/// prompts. Keys stay in-process; outcomes carry labels and slots only.
public enum OpenCodeAccountUnifier {
    public enum Action: Equatable, Sendable {
        case repointed(slot: String)
        case enrolled(slot: String)
        case duplicateRemoved(slot: String)
        case missingKey
    }

    public struct Outcome: Equatable, Sendable {
        public let accountId: String
        public let label: String
        public let action: Action
        /// Keychain reference left in place after the move (nil when none).
        public let orphanedCredentialKey: String?
    }

    public static func unify(
        settings: any MultiAccountSettingsRepository,
        credentials: any CredentialRepository,
        loader: OpenCodeCredentialLoader = OpenCodeCredentialLoader(),
        providerId: String = "opencode-go",
        apply: Bool
    ) throws -> [Outcome] {
        try unify(settings: settings, credentials: credentials,
                  pool: OpenCodeFailoverPool(loader: loader), providerId: providerId, apply: apply)
    }

    /// Same move for any failover pool (OpenCode Go, Ollama Cloud, Command Code).
    public static func unify(
        settings: any MultiAccountSettingsRepository,
        credentials: any CredentialRepository,
        pool: any FailoverKeyPool,
        providerId: String,
        apply: Bool
    ) throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for config in settings.accounts(forProvider: providerId) {
            guard let reference = config.probeConfig["credentialKey"] else { continue }
            guard let key = credentials.get(forKey: reference), !key.isEmpty else {
                outcomes.append(.init(accountId: config.accountId, label: config.label,
                                      action: .missingKey, orphanedCredentialKey: nil))
                continue
            }
            let existing = pool.slot(holding: key)
            let shownElsewhere = existing.map { slot in
                settings.accounts(forProvider: providerId).contains {
                    $0.accountId != config.accountId && $0.probeConfig["externalSlot"] == slot
                }
            } ?? false

            let action: Action
            if let slot = existing, shownElsewhere {
                action = .duplicateRemoved(slot: slot)
                if apply { settings.removeAccount(accountId: config.accountId, forProvider: providerId) }
            } else {
                let slot: String
                if let existing {
                    slot = existing
                } else if apply {
                    slot = try pool.enroll(label: config.label, key: key)
                } else {
                    slot = pool.previewSlot(for: config.label)
                }
                action = existing == nil ? .enrolled(slot: slot) : .repointed(slot: slot)
                if apply {
                    var probe = config.probeConfig
                    probe["credentialKey"] = nil
                    probe["externalSlot"] = slot
                    settings.updateAccount(.init(accountId: config.accountId, label: config.label,
                                                 email: config.email, organization: config.organization,
                                                 probeConfig: probe), forProvider: providerId)
                }
            }
            outcomes.append(.init(accountId: config.accountId, label: config.label,
                                  action: action, orphanedCredentialKey: reference))
        }
        return outcomes
    }
}
