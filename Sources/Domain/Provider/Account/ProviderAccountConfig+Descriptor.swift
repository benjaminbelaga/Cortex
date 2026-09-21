import Foundation
import CryptoKit

/// Lossless projection between the stable `AccountDescriptor` and the legacy
/// `ProviderAccountConfig` JSON storage shape. The descriptor's extra fields ride
/// inside `probeConfig` (all strings), so the on-disk format is unchanged and
/// `JSONSettingsRepository` — which passes `probeConfig` through verbatim — keeps
/// any keys it does not understand. `accountId` stays the storage key; the UUID
/// is the identity.
public extension ProviderAccountConfig {
    enum DescriptorKeys {
        public static let claudeConfigDir = "claudeConfigDir"
        public static let codexHome = "codexHome"
        public static let routerAlias = "routerAlias"
        public static let uuid = "accountUUID"
        public static let source = "source"
        public static let visibility = "visibility"
        public static let sortOrder = "sortOrder"
        public static let verifiedEmail = "verifiedEmail"
        public static let verifiedOrgId = "verifiedOrgId"
        public static let verifiedOrgName = "verifiedOrgName"
        public static let verifiedAt = "verifiedAt"
        public static let verifiedBy = "verifiedBy"
    }

    /// Reads a descriptor from this config. `source` defaults to `.router` when a
    /// router alias is present and `.native` otherwise, matching the migration
    /// rule, so a pre-descriptor account is interpreted consistently.
    func descriptor(providerId: String) -> AccountDescriptor {
        let pc = probeConfig
        let storedSource = pc[DescriptorKeys.source].flatMap(AccountSource.init(rawValue:))
        let source = storedSource
            ?? (pc[DescriptorKeys.routerAlias] != nil ? .router : .native)

        let profile: ProfileReference
        if let codex = pc[DescriptorKeys.codexHome] {
            profile = .codexHome(codex)
        } else if let claude = pc[DescriptorKeys.claudeConfigDir] {
            profile = .claudeConfigDir(claude)
        } else if let alias = pc[DescriptorKeys.routerAlias] {
            profile = .routerAlias(alias)
        } else {
            profile = .none
        }

        let uuid = pc[DescriptorKeys.uuid].flatMap(UUID.init(uuidString:))
            ?? UUID(uuidString: accountId) ?? stableLegacyUUID(providerId: providerId)
        let visibility = pc[DescriptorKeys.visibility]
            .flatMap(AccountVisibility.init(rawValue:)) ?? .visible
        let sortOrder = pc[DescriptorKeys.sortOrder].flatMap(Int.init) ?? 0

        var identity: VerifiedIdentity?
        if let email = pc[DescriptorKeys.verifiedEmail],
           let atString = pc[DescriptorKeys.verifiedAt],
           let at = ISO8601DateFormatter().date(from: atString),
           let method = pc[DescriptorKeys.verifiedBy]
            .flatMap(IdentityVerificationMethod.init(rawValue:)) {
            identity = VerifiedIdentity(
                email: email,
                orgId: pc[DescriptorKeys.verifiedOrgId],
                orgName: pc[DescriptorKeys.verifiedOrgName],
                verifiedAt: at,
                method: method
            )
        }

        return AccountDescriptor(
            uuid: uuid,
            providerId: providerId,
            label: label,
            profile: profile,
            source: source,
            visibility: visibility,
            verifiedIdentity: identity,
            sortOrder: sortOrder
        )
    }

    /// Stable legacy identity until the next write persists the descriptor UUID.
    private func stableLegacyUUID(providerId: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(providerId)/\(accountId)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        let text = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
        return UUID(uuidString: text)!
    }

    /// Builds a config from a descriptor, preserving `email`/`organization` and
    /// any probeConfig keys not owned by the descriptor projection.
    static func from(
        descriptor: AccountDescriptor,
        accountId: String,
        email: String? = nil,
        organization: String? = nil,
        preserving existing: [String: String] = [:]
    ) -> ProviderAccountConfig {
        var pc = existing
        // Clear the profile keys this projection owns, then set the current one.
        pc[DescriptorKeys.claudeConfigDir] = nil
        pc[DescriptorKeys.codexHome] = nil
        // routerAlias is preserved when it is the profile; otherwise cleared.
        switch descriptor.profile {
        case let .claudeConfigDir(path):
            pc[DescriptorKeys.claudeConfigDir] = path
        case let .codexHome(path):
            pc[DescriptorKeys.codexHome] = path
        case let .routerAlias(alias):
            pc[DescriptorKeys.routerAlias] = alias
        case .none:
            break
        }
        pc[DescriptorKeys.uuid] = descriptor.uuid.uuidString
        pc[DescriptorKeys.source] = descriptor.source.rawValue
        pc[DescriptorKeys.visibility] = descriptor.visibility.rawValue
        pc[DescriptorKeys.sortOrder] = String(descriptor.sortOrder)

        if let identity = descriptor.verifiedIdentity {
            pc[DescriptorKeys.verifiedEmail] = identity.email
            pc[DescriptorKeys.verifiedOrgId] = identity.orgId
            pc[DescriptorKeys.verifiedOrgName] = identity.orgName
            pc[DescriptorKeys.verifiedAt] = ISO8601DateFormatter().string(from: identity.verifiedAt)
            pc[DescriptorKeys.verifiedBy] = identity.method.rawValue
        }

        return ProviderAccountConfig(
            accountId: accountId,
            label: descriptor.label,
            email: email ?? descriptor.verifiedIdentity?.email,
            organization: organization,
            probeConfig: pc
        )
    }
}
