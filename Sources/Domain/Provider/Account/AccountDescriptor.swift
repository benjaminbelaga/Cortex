import Foundation

/// Where an account's identity physically lives on this machine. A label is free
/// text and can change; the profile reference is what the resolver, enrolment and
/// collection all key off, so it must stay stable across a rename.
public enum ProfileReference: Sendable, Equatable {
    /// An isolated Claude config directory (`CLAUDE_CONFIG_DIR`).
    case claudeConfigDir(String)
    /// An isolated Codex home (`CODEX_HOME`).
    case codexHome(String)
    /// An alias in the llm-router registry (router mode).
    case routerAlias(String)
    /// No local profile yet (e.g. a detected-but-unconfirmed candidate).
    case none

    /// The on-disk path this profile points at, when it is a local directory.
    public var localPath: String? {
        switch self {
        case let .claudeConfigDir(path), let .codexHome(path): return path
        case .routerAlias, .none: return nil
        }
    }
}

/// Which subsystem owns an account's quota reading.
public enum AccountSource: String, Sendable, Equatable, Codable {
    /// Quota comes from the shared llm-router snapshot; the registry is authoritative.
    case router
    /// Quota comes from a Cortex-native probe against the account's own profile.
    case native
}

/// Whether the user wants to see an account, has hidden it, or has explicitly
/// rejected a discovery proposal (so it is never re-proposed).
public enum AccountVisibility: String, Sendable, Equatable, Codable {
    case visible
    case hidden
    case rejected
}

/// How an identity was proven. A typed email in a form is NOT proof — only a
/// value read back from the tool counts.
public enum IdentityVerificationMethod: String, Sendable, Equatable, Codable {
    case claudeAuthStatus
    case codexAppServer
    case routerRegistry
}

/// An identity that was actually read back from an authenticated tool.
public struct VerifiedIdentity: Sendable, Equatable, Codable {
    public let email: String
    public let orgId: String?
    public let orgName: String?
    public let verifiedAt: Date
    public let method: IdentityVerificationMethod

    public init(
        email: String,
        orgId: String? = nil,
        orgName: String? = nil,
        verifiedAt: Date,
        method: IdentityVerificationMethod
    ) {
        self.email = email
        self.orgId = orgId
        self.orgName = orgName
        self.verifiedAt = verifiedAt
        self.method = method
    }
}

/// The stable, source-agnostic description of one account Cortex tracks. It is
/// distinct from `ProviderAccountConfig` (the JSON storage shape) and from the
/// live quota/availability observations; the descriptor holds identity and
/// preferences only, never a copied credential or a subscription token.
public struct AccountDescriptor: Sendable, Equatable, Identifiable {
    public let uuid: UUID
    public let providerId: String
    public var label: String
    public var profile: ProfileReference
    public var source: AccountSource
    public var visibility: AccountVisibility
    public var verifiedIdentity: VerifiedIdentity?
    public var sortOrder: Int

    public var id: UUID { uuid }

    public init(
        uuid: UUID = UUID(),
        providerId: String,
        label: String,
        profile: ProfileReference,
        source: AccountSource,
        visibility: AccountVisibility = .visible,
        verifiedIdentity: VerifiedIdentity? = nil,
        sortOrder: Int = 0
    ) {
        self.uuid = uuid
        self.providerId = providerId
        self.label = label
        self.profile = profile
        self.source = source
        self.visibility = visibility
        self.verifiedIdentity = verifiedIdentity
        self.sortOrder = sortOrder
    }
}
