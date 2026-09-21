import Foundation

/// Décision du reconciler pour un compte natif (Claude/Codex découvert) face
/// aux comptes router enregistrés. Trois issues possibles :
/// - `linkAlias(routerAccount)` : le compte natif matche un compte router par
///                                 identité vérifiée ; l'alias router est lié
///                                 au profil natif, les deux sondent désormais
///                                 le même utilisateur.
/// - `conflict(routerAccounts, conflictingEmails)` : une même identité vérifiée
///                                 pointe vers PLUS D'UN compte router OU plus
///                                 d'un profil natif. La fusion automatique est
///                                 interdite — l'utilisateur tranche depuis le
///                                 sheet `+`. `conflictingEmails` est un
///                                 `Set<String>` (un email = une identité en
///                                 conflit), pas un doublon par compte.
/// - `addStandalone` : aucune correspondance ; le profil natif est ajouté
///                     comme un compte autonome, sans alias router.
public enum AccountReconciliationDecision: Sendable, Equatable {
    case linkAlias(routerAccount: RouterAccountSummary)
    case conflict(routerAccounts: [RouterAccountSummary], conflictingEmails: Set<String>)
    case addStandalone
}

/// Résumé minimum qu'un compte router doit exposer au reconciler. Il vit en
/// Domain (pas d'import Infrastructure) pour permettre une composition sans
/// boucle. La couche App fournit une projection depuis le snapshot
/// `LLMRouterSnapshotClient`.
public struct RouterAccountSummary: Sendable, Equatable, Hashable {
    public let accountId: String
    public let alias: String
    public let verifiedEmail: String?

    public init(accountId: String, alias: String, verifiedEmail: String?) {
        self.accountId = accountId
        self.alias = alias
        self.verifiedEmail = verifiedEmail
    }
}

/// Profil natif à reconciler (sortie de `ProfileResolver` /
/// `AccountDiscoveryService`, après lecture de l'identité vérifiée par
/// `ProfileIdentityValidating`).
public struct NativeProfileCandidate: Sendable, Equatable {
    public let canonicalPath: String
    public let verifiedEmail: String?

    public init(canonicalPath: String, verifiedEmail: String?) {
        self.canonicalPath = canonicalPath
        self.verifiedEmail = verifiedEmail
    }
}

/// **Email-only** (`rules/60` + decision 2026-09-14). Décision pour UN profil
/// natif vs le roster router :
/// - Email vérifié (lowercase) — clé unique. Deux profils natifs au même
///   email, OU un profil natif matchant deux comptes router au même email,
///   produisent un `conflict`. Aucun n'est fusionné silencieusement.
/// - Pas d'email vérifié (`nil`) — pas de match possible, profil ajouté seul.
///   Le dedup par chemin (entre `auth_home` du roster et `canonicalPath` du
///   profil) est laissé au backlog hors-mission (patch llm-router pour émettre
///   `auth_home` au wire compte ; voir plan §Décision verrouillée).
public struct AccountReconciler: Sendable {

    public init() {}

    public func decide(
        candidate: NativeProfileCandidate,
        routerAccounts: [RouterAccountSummary]
    ) -> AccountReconciliationDecision {
        guard let raw = candidate.verifiedEmail?.lowercased(), !raw.isEmpty else {
            return .addStandalone
        }
        let matches = routerAccounts.filter { account in
            guard let email = account.verifiedEmail?.lowercased() else { return false }
            return email == raw
        }
        if matches.count == 1, let only = matches.first {
            return .linkAlias(routerAccount: only)
        }
        if matches.count > 1 {
            return .conflict(
                routerAccounts: matches,
                conflictingEmails: Set(matches.compactMap { $0.verifiedEmail?.lowercased() })
            )
        }
        return .addStandalone
    }

    /// Pass d'enrôlement d'un batch natif. Pour chaque candidat avec email
    /// vérifié, vérifie qu'aucun AUTRE candidat du batch ne partage le même
    /// email — sinon ce candidat devient `conflict`. Les collisions intra-batch
    /// sont un signe de mauvaise configuration multi-compte (rare ; signalé
    /// explicitement, jamais résolu).
    public func reconcileBatch(
        candidates: [NativeProfileCandidate],
        routerAccounts: [RouterAccountSummary]
    ) -> [AccountReconciliationDecision] {
        let emailCounts = Dictionary(grouping: candidates) { $0.verifiedEmail?.lowercased() }
            .filter { $0.key != nil && !($0.key?.isEmpty ?? true) }
            .mapValues { $0.count }
        return candidates.map { candidate in
            let email = candidate.verifiedEmail?.lowercased()
            let isCollisionInBatch = (email.flatMap { emailCounts[$0] } ?? 0) > 1
            let perCandidate = decide(candidate: candidate, routerAccounts: routerAccounts)
            if isCollisionInBatch, case .linkAlias(let router) = perCandidate {
                // L'email match un alias router mais le batch lui-même en compte
                // plusieurs → on remonte le conflit au lieu de fusionner.
                let emails: Set<String> = Set(
                    candidates.compactMap { $0.verifiedEmail?.lowercased() }
                        .filter { $0 == email }
                )
                return .conflict(routerAccounts: [router], conflictingEmails: emails)
            }
            return perCandidate
        }
    }
}
