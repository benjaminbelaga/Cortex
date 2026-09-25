import Foundation
import Domain

/// English labels for every typed enrolment state and error (D — catalogue).
/// One switch per surface, localization at the last moment: views never
/// string-match states, and new enum cases fail to compile here instead of
/// silently rendering an empty row.
enum CatalogStrings {

    // MARK: - Enrolment states

    static func title(for state: EnrolmentState) -> String {
        switch state {
        case .profileDetected: return "Profile detected"
        case .authRequired: return "Connection required"
        case .loginInProgress: return "Connecting…"
        case .identityConfirmed: return "Identity confirmed"
        case .quotaPending: return "Connected · quotas pending"
        case .quotaReceived: return "Tracked account"
        case .failed: return "Enrolment failed"
        case .cancelled: return "Cancelled"
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
            return IdentityMasking.mask(identity.email) ?? "identity verified"
        case .quotaPending:
            return "First reading not received yet — the state is valid, not an error."
        case .quotaReceived(_, let observedAt):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "First reading received \(formatter.localizedString(for: observedAt, relativeTo: Date()))"
        case .failed(_, let error):
            return detail(for: error)
        case .cancelled:
            return "Nothing was saved."
        }
    }

    // MARK: - Typed errors

    static func title(for error: EnrolmentError) -> String {
        switch error {
        case .dependencyMissing(let tool): return "Tool not found: \(tool)"
        case .loginFailed: return "Connection failed"
        case .identityMismatch: return "Identity differs from expected"
        case .profileCollision: return "Another account already owns this folder"
        case .registryRejected: return "Router registration refused"
        case .timeout: return "Timed out"
        case .cancelled: return "Cancelled"
        case .underlying: return "Unexpected error"
        }
    }

    static func detail(for error: EnrolmentError) -> String? {
        switch error {
        case .dependencyMissing(let tool):
            return "Install \(tool) and try again."
        case .loginFailed(_, let stderrTail):
            return stderrTail.isEmpty ? "The connection command failed." : stderrTail
        case .identityMismatch(let expected, let actual):
            var line = "Re-read identity: \(IdentityMasking.mask(actual) ?? actual)."
            if let expected {
                line += " Expected: \(IdentityMasking.mask(expected) ?? expected)."
            }
            return line + " Nothing was saved — keep the re-read identity by retrying without input."
        case .profileCollision(let path):
            return path
        case .registryRejected(let reason):
            return reason
        case .timeout(let seconds):
            return "No response after \(Int(seconds))s. Logging in may still work — try again."
        case .cancelled:
            return nil
        case .underlying(let message):
            return message
        }
    }

    // MARK: - Sub-payloads

    static func reasonLabel(_ reason: AuthReason) -> String {
        switch reason {
        case .neverAuthenticated: return "Never connected"
        case .refreshTokenExpired: return "Session expired"
        case .credentialsRevoked: return "Credentials revoked"
        case .explicitReconnect: return "Reconnect requested"
        }
    }

    static func stageLabel(_ stage: LoginStage) -> String {
        switch stage {
        case .launching: return "Opening terminal…"
        case .waitingForUser: return "Waiting for your login in the terminal"
        case .pollingIdentity: return "Reading verified identity…"
        }
    }

    // MARK: - Sections

    static let accountsSectionTitle = "Add account"
    static let connectionsSectionTitle = "Add a connection"
    static let searchAction = "Find accounts"
    static let followAction = "Follow"
    static let newAccountAction = "Create account"
    static let activateAction = "Enable"
    static let activeLabel = "Enabled"
}
