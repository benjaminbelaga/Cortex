import Foundation

/// Identity shape returned by Codex app-server's `account/read`. Parallel to
/// `ClaudeAuthStatus` (PR C, §CodexAccountAdapter) — `loggedIn`/`email`/
/// `planType` are the minimum the enrolment pipeline consumes. Additional
/// fields (`account_id`, `subscriptionActive`, etc.) are added when the
/// wire schema lands; the adapter ignores unknown keys.
///
/// All fields after `loggedIn` are nullable: the wire schema omits them when
/// the account does not have them (e.g. pre-billing-readiness).
public struct CodexAuthStatus: Sendable, Equatable, Decodable {
    public let loggedIn: Bool
    public let email: String?
    public let planType: String?
    public let accountId: String?

    public init(
        loggedIn: Bool,
        email: String? = nil,
        planType: String? = nil,
        accountId: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.email = email
        self.planType = planType
        self.accountId = accountId
    }

    /// Project to a Domain `VerifiedIdentity`. The `verifiedAt` timestamp is
    /// `now`, NEVER carried from the wire — enrolment time matters, not the
    /// time the CLI reported the identity.
    public func verifiedIdentity(at date: Date = Date()) -> VerifiedIdentity? {
        guard loggedIn, let email else { return nil }
        return VerifiedIdentity(
            email: email,
            orgId: nil,
            orgName: nil,
            verifiedAt: date,
            method: .codexAppServer
        )
    }
}
