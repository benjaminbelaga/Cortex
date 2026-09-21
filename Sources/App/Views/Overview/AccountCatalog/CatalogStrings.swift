import Foundation
import Domain

/// French labels for every typed enrolment state and error (D — catalogue).
/// One switch per surface, localization at the last moment: views never
/// string-match states, and new enum cases fail to compile here instead of
/// silently rendering an empty row.
enum CatalogStrings {

    // MARK: - Enrolment states

    static func title(for state: EnrolmentState) -> String {
        switch state {
        case .profileDetected: return "Profil détecté"
        case .authRequired: return "Connexion requise"
        case .loginInProgress: return "Connexion en cours…"
        case .identityConfirmed: return "Identité confirmée"
        case .quotaPending: return "Connecté · quotas en attente"
        case .quotaReceived: return "Compte suivi"
        case .failed: return "Échec de l'enrôlement"
        case .cancelled: return "Annulé"
        }
    }

    static func detail(for state: EnrolmentState) -> String? {
        switch state {
        case let .profileDetected(descriptor):
            return descriptor.profile.localPath
        case let .authRequired(descriptor, reason):
            return "\(reasonLabel(reason)) — \(descriptor.label)"
        case .loginInProgress(_, let stage):
            return stageLabel(stage)
        case .identityConfirmed(_, let identity):
            return IdentityMasking.mask(identity.email) ?? "identité vérifiée"
        case .quotaPending:
            return "Premier relevé pas encore reçu — l'état est valide, pas une erreur."
        case .quotaReceived(_, let observedAt):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Premier relevé reçu il y a \(formatter.localizedString(for: observedAt, relativeTo: Date()))"
        case .failed(_, let error):
            return detail(for: error)
        case .cancelled:
            return "Rien n'a été enregistré."
        }
    }

    // MARK: - Typed errors

    static func title(for error: EnrolmentError) -> String {
        switch error {
        case .dependencyMissing(let tool): return "Outil introuvable : \(tool)"
        case .loginFailed: return "Échec de la connexion"
        case .identityMismatch: return "Identité différente de celle attendue"
        case .profileCollision: return "Un autre compte possède déjà ce dossier"
        case .registryRejected: return "Enregistrement routeur refusé"
        case .timeout: return "Délai dépassé"
        case .cancelled: return "Annulé"
        case .underlying: return "Erreur inattendue"
        }
    }

    static func detail(for error: EnrolmentError) -> String? {
        switch error {
        case .dependencyMissing(let tool):
            return "Installez \(tool) puis réessayez."
        case .loginFailed(_, let stderrTail):
            return stderrTail.isEmpty ? "La commande de connexion a échoué." : stderrTail
        case .identityMismatch(let expected, let actual):
            var line = "Identité relue : \(IdentityMasking.mask(actual) ?? actual)."
            if let expected {
                line += " Attendue : \(IdentityMasking.mask(expected) ?? expected)."
            }
            return line + " Rien n'a été enregistré — gardez l'identité relue en réessayant sans saisie."
        case .profileCollision(let path):
            return path
        case .registryRejected(let reason):
            return reason
        case .timeout(let seconds):
            return "Aucune réponse après \(Int(seconds)) s. Le login reste possible — réessayez."
        case .cancelled:
            return nil
        case .underlying(let message):
            return message
        }
    }

    // MARK: - Sub-payloads

    static func reasonLabel(_ reason: AuthReason) -> String {
        switch reason {
        case .neverAuthenticated: return "Jamais connecté"
        case .refreshTokenExpired: return "Session expirée"
        case .credentialsRevoked: return "Identifiants révoqués"
        case .explicitReconnect: return "Reconnexion demandée"
        }
    }

    static func stageLabel(_ stage: LoginStage) -> String {
        switch stage {
        case .launching: return "Ouverture du terminal…"
        case .waitingForUser: return "En attente de votre login dans le terminal"
        case .pollingIdentity: return "Lecture de l'identité vérifiée…"
        }
    }

    // MARK: - Sections

    static let accountsSectionTitle = "Ajouter un compte"
    static let connectionsSectionTitle = "Ajouter une connexion"
    static let searchAction = "Rechercher des comptes"
    static let followAction = "Suivre"
    static let newAccountAction = "Créer le compte"
    static let activateAction = "Activer"
    static let activeLabel = "Activée"
}
