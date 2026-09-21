import Foundation

/// Identity shape returned by `claude auth status --json`. The "richer than
/// `ClaudeAuthenticatedAccount`" superset is what the enrolment pipeline needs
/// (plan PR C, step §ClaudeAccountAdapter) — `loggedIn` alone is enough for
/// discovery, but enrolment also wants `orgId`/`orgName`/`subscriptionType` so
/// `VerifiedIdentity` carries them through.
///
/// All fields after `loggedIn` are nullable: the JSON omits them when the
/// underlying CLI does not surface them (older CLI versions, partial auth).
/// `init(from:)` is permissive — a missing key decodes to `nil`, never throws.
public struct ClaudeAuthStatus: Sendable, Equatable, Decodable {
    public let loggedIn: Bool
    public let email: String?
    public let orgId: String?
    public let orgName: String?
    public let subscriptionType: String?

    public init(
        loggedIn: Bool,
        email: String? = nil,
        orgId: String? = nil,
        orgName: String? = nil,
        subscriptionType: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.email = email
        self.orgId = orgId
        self.orgName = orgName
        self.subscriptionType = subscriptionType
    }

    /// Project to a Domain `VerifiedIdentity`. The `verifiedAt` timestamp is
    /// `now`, NEVER carried from the wire — the moment of enrolment matters,
    /// not the moment the CLI reported identity.
    public func verifiedIdentity(at date: Date = Date()) -> VerifiedIdentity? {
        guard loggedIn, let email else { return nil }
        return VerifiedIdentity(
            email: email,
            orgId: orgId,
            orgName: orgName,
            verifiedAt: date,
            method: .claudeAuthStatus
        )
    }
}
