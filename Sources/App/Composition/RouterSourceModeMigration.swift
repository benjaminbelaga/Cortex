import Foundation
import Domain
import Infrastructure

/// **RouterSourceModeMigration** — décide du mode de source PAR DÉFAUT selon
/// ce que la machine sait réellement servir, une fois, sans jamais écraser un
/// choix utilisateur.
///
/// - Registre llm-router présent (comptes déclarés) → défaut `.router` : les
///   lignes Claude/Codex continuent de lire le snapshot partagé, exactement
///   comme avant l'introduction du mode autonome.
/// - Pas de registre (installation vierge) → défaut `.autonomous` : les sondes
///   natives suffisent, et les lignes STRICTEMENT routeur (kimi, qwen, glm,
///   minimax, qwen-api, bedrock, local) ne sont pas suivies d'office — elles
///   restent activables depuis le catalogue `+`.
///
/// Le choix explicite (`providers.<id>.sourceMode`, `providers.<id>.isEnabled`)
/// gagne toujours : cette migration n'écrit que sur une clé absente.
public struct RouterSourceModeMigration: Sendable {

    public static let registryPath = "~/.config/llm-router/registry.yaml"

    /// Vrai quand un registre llm-router non vide est présent.
    public static func routerRegistryPresent(
        registryPath: String = registryPath,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Bool {
        let expanded = (registryPath as NSString).expandingTildeInPath
        guard fileExists(expanded), let text = readFile(expanded) else { return false }
        return text.contains("accounts:")
    }

    /// Mode par défaut de la composition pour les providers bi-mode.
    public static func defaultSourceMode(
        registryPath: String = registryPath,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> QuotaSourceMode {
        routerRegistryPresent(registryPath: registryPath, fileExists: fileExists, readFile: readFile)
            ? .router
            : .autonomous
    }

    /// Idempotent. Sur une machine sans routeur, coupe le SUIVI des lignes
    /// strictement routeur **si et seulement si** la clé `isEnabled` est
    /// absente (un choix explicite, vrai ou faux, est préservé — même contrat
    /// que `CortexApp.seedCuratedProviderDefaultsIfNeeded`).
    public static func applyFreshInstallDefaultsIfNeeded(
        settingsRepository: any ProviderSettingsRepository,
        registryPresent: Bool
    ) {
        guard !registryPresent else {
            AppLog.providers.debug("router registry present — default roster untouched")
            return
        }
        for id in ProviderCatalog.routerOnlyIDs {
            let absent = settingsRepository.isEnabled(forProvider: id, defaultValue: true)
                != settingsRepository.isEnabled(forProvider: id, defaultValue: false)
            guard absent else { continue }
            settingsRepository.setEnabled(false, forProvider: id)
            AppLog.providers.info(
                "Fresh install: router-only provider \(id) left unfollowed (activate it from the + catalogue)"
            )
        }
    }
}
