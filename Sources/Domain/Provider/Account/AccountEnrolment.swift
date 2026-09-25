import Foundation

/// Why auth is needed for a profile. Surfaced verbatim by adapters; rendered by
/// the enrolment sheet's `.authRequired` row to pick a message ("Vous n'avez
/// jamais authentifié ce profil" vs "jeton expiré, reconnectez-vous").
public enum AuthReason: String, Sendable, Equatable, Codable {
    /// First enrolment for this profile — no credentials on disk yet.
    case neverAuthenticated
    /// The tool reported its refresh/session token as no longer valid.
    case refreshTokenExpired
    /// The provider returned 401/revoked — credentials are gone server-side.
    case credentialsRevoked
    /// The user pressed "Reconnecter" — every prior cause collapses here.
    case explicitReconnect
}

/// Granular signal emitted while a login subprocess is running. The sheet maps
/// each stage to a chip ("Lancement du terminal", "En attente du navigateur",
/// "Lecture de l'identité"). The list is intentionally short; finer-grained
/// states belong on the adapter, not the domain.
public enum LoginStage: String, Sendable, Equatable, Codable {
    case launching
    case waitingForUser
    case pollingIdentity
}

/// Typed failures surfaced by the enrolment pipeline. The sheet renders by
/// `case` and reads `isRecoverable` to decide whether to show "Réessayer".
///
/// The `Equatable` implementation is structural (no payload capture of `String`
/// truncation surprises); cases that carry `String` use the raw value verbatim.
public enum EnrolmentError: Error, Sendable, Equatable {
    case dependencyMissing(tool: String)
    case loginFailed(exitCode: Int32, stderrTail: String)
    case identityMismatch(expected: String?, actual: String)
    case profileCollision(path: String)
    case registryRejected(reason: String)
    case timeout(afterSeconds: TimeInterval)
    case cancelled
    case underlying(String)

    /// True when retrying the same flow might succeed (transient cause).
    /// False for hard contradictions (identity mismatch, occupied dir) and
    /// explicit cancels — those need a different action.
    public var isRecoverable: Bool {
        switch self {
        case .dependencyMissing, .loginFailed, .timeout, .registryRejected, .underlying:
            return true
        case .identityMismatch, .profileCollision, .cancelled:
            return false
        }
    }
}

/// A single frame in the enrolment state machine. Each case carries the
/// descriptor it refers to (so the consumer can correlate to the right row
/// even when several enrolments run concurrently) plus the minimum payload
/// the UI needs to render that row.
///
/// Terminal states: `.identityConfirmed` / `.quotaReceived` (success),
/// `.failed`, `.cancelled`. `.quotaReceived` is preferred over `.quotaPending`
/// as the visible terminal success state — a "connected but waiting for first
/// snapshot" account is still enrolled, the sheet just shows a "quota en
/// attente" chip.
public enum EnrolmentState: Sendable, Equatable {
    /// Resolver found a candidate profile; ready to enrol if the user accepts.
    case profileDetected(AccountDescriptor)
    /// Profile exists locally but auth is missing/expired; the sheet must offer
    /// a "Lancer la connexion" CTA.
    case authRequired(AccountDescriptor, reason: AuthReason)
    /// A login subprocess is running; UI renders the `LoginStage` chip.
    case loginInProgress(AccountDescriptor, stage: LoginStage)
    /// Tool returned a verified identity that matches (or, when no expected
    /// identity was supplied, that just exists). Account is enrolled.
    case identityConfirmed(AccountDescriptor, identity: VerifiedIdentity)
    /// Identity verified + persisted; first quota snapshot not yet observed.
    /// The user sees "Connected · quotas pending".
    case quotaPending(AccountDescriptor)
    /// First quota snapshot observed. Steady state — the row joins the menu.
    case quotaReceived(AccountDescriptor, observedAt: Date)
    /// Terminal failure with the typed `EnrolmentError`.
    case failed(AccountDescriptor, error: EnrolmentError)
    /// Terminal cancel. May carry a descriptor (if known at cancel time) or
    /// `nil` for early cancels (no profile ever picked).
    case cancelled(AccountDescriptor?)
}

/// Which operations an adapter can perform. Drives the catalogue UI: a button
/// only appears when the underlying capability is supported (e.g. `+ Ajouter`
/// hides if `.add` is missing; "Reconnecter" hides if `.reconnect` is missing).
///
/// Bits chosen so any future capability slots in at a high bit; the union
/// `allAdapters` constant (in test) saturates to `(1<<7) - 1`.
public struct AccountCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public static let discover          = Self(rawValue: 1 << 0)
    public static let add               = Self(rawValue: 1 << 1)
    public static let reconnect         = Self(rawValue: 1 << 2)
    public static let readQuota         = Self(rawValue: 1 << 3)
    public static let readCost          = Self(rawValue: 1 << 4)
    public static let checkAvailability = Self(rawValue: 1 << 5)
    public static let listObservations  = Self(rawValue: 1 << 6)

    public init(rawValue: Int) { self.rawValue = rawValue }
}

/// Per-tool-family adapter contract. Implementations live in `Infrastructure/`
/// (ClaudeAccountAdapter, CodexAccountAdapter). RouterRegistrar is a thin
/// helper, not an adapter — `.router` mode delegates through the existing
/// `LLMRouterSnapshotClient` rather than driving a subprocess itself.
public protocol AccountAdapter: Sendable {
    /// Stable identifier this adapter serves (`"claude"`, `"codex"`, …).
    var providerId: String { get }
    /// Bit-set of supported operations; the catalogue UI consumes it directly.
    var capabilities: AccountCapabilities { get }
    /// Drive an enrolment run. The stream yields ordered `EnrolmentState`
    /// frames; `.failed(...)` or `.cancelled(...)` MUST be the last frame.
    /// The consumer (the enrolment service) renders these verbatim.
    func enrol(intent: EnrolmentIntent) -> AsyncStream<EnrolmentState>
    /// Re-authenticate an already-tracked account. Same frame sequence as
    /// `enrol`, but the descriptor is fixed and discovery is skipped.
    func reconnect(account: AccountDescriptor) -> AsyncStream<EnrolmentState>
    /// One-shot identity probe, no state emitted. Used by Refresh/Reconnect
    /// to confirm the tool is logged in before talking to the router.
    func verifyIdentity(profile: ProfileReference) async throws -> VerifiedIdentity?
}

/// What the user wants when kicking off enrolment. Encodes the descriptor
/// (resolved profile + label), the optional identity expectation (for
/// mismatch detection at `.identityConfirmed`), and the target source
/// (router vs autonomous).
public struct EnrolmentIntent: Sendable, Equatable {
    public let descriptor: AccountDescriptor
    public let expectedIdentityEmail: String?
    public let targetSource: AccountSource

    public init(
        descriptor: AccountDescriptor,
        expectedIdentityEmail: String? = nil,
        targetSource: AccountSource
    ) {
        self.descriptor = descriptor
        self.expectedIdentityEmail = expectedIdentityEmail
        self.targetSource = targetSource
    }
}
