import Foundation

/// Identity + credential state returned by `bl auth status --output json`.
///
/// Alibaba/Bailian has no email in its console session — the only honest
/// authenticated principal the CLI exposes is the **workspace** the API key is
/// bound to (`api_key.base_url` host, e.g. `ws-hhugyjljove6wldy`), with the
/// masked console token as a fallback. Both are read back from the tool; a
/// value is never invented. `authenticated == false` is a *valid* reply
/// distinct from a probe failure (`nil`).
public struct AlibabaAuthStatus: Sendable, Equatable, Decodable {
    public struct APIKey: Sendable, Equatable, Decodable {
        public let source: String?
        public let masked: String?
        public let baseURL: String?

        enum CodingKeys: String, CodingKey {
            case source, masked
            case baseURL = "base_url"
        }

        public init(source: String? = nil, masked: String? = nil, baseURL: String? = nil) {
            self.source = source
            self.masked = masked
            self.baseURL = baseURL
        }
    }

    public struct Console: Sendable, Equatable, Decodable {
        public let source: String?
        public let masked: String?
        public let region: String?
        public let site: String?

        public init(source: String? = nil, masked: String? = nil, region: String? = nil, site: String? = nil) {
            self.source = source
            self.masked = masked
            self.region = region
            self.site = site
        }
    }

    public let authenticated: Bool
    public let config: String?
    public let apiKey: APIKey?
    public let console: Console?

    enum CodingKeys: String, CodingKey {
        case authenticated, config, console
        case apiKey = "api_key"
    }

    public init(
        authenticated: Bool,
        config: String? = nil,
        apiKey: APIKey? = nil,
        console: Console? = nil
    ) {
        self.authenticated = authenticated
        self.config = config
        self.apiKey = apiKey
        self.console = console
    }

    /// The workspace id, parsed from the model base URL host
    /// (`ws-xxxx.ap-southeast-1.maas.aliyuncs.com` → `ws-xxxx`). nil when the
    /// URL is absent or not a workspace-scoped host — never a guess.
    public var workspaceId: String? {
        guard let host = apiKey?.baseURL.flatMap(URL.init(string:))?.host else { return nil }
        let first = host.split(separator: ".").first.map(String.init)
        guard let first, first.hasPrefix("ws-") else { return nil }
        return first
    }

    /// The read-back principal: workspace id first (account-scoped, stable),
    /// else the masked console token. nil when neither exists — an
    /// authenticated reply with no identifiable principal stays unverified
    /// rather than fabricating an identity.
    public var principal: String? {
        if let workspaceId { return workspaceId }
        if let masked = console?.masked, !masked.isEmpty { return masked }
        return nil
    }

    /// Project to a Domain `VerifiedIdentity`. `verifiedAt` is `now`, never
    /// carried from the wire — enrolment time matters.
    public func verifiedIdentity(at date: Date = Date()) -> VerifiedIdentity? {
        guard authenticated, let principal else { return nil }
        return VerifiedIdentity(
            email: principal,
            orgId: workspaceId,
            orgName: console?.site,
            verifiedAt: date,
            method: .alibabaConsole
        )
    }
}
