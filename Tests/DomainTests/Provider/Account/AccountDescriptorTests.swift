import Testing
import Foundation
@testable import Domain

/// Pins the lossless projection between `AccountDescriptor` and the
/// `ProviderAccountConfig` JSON storage shape, and that a label is free text
/// carrying no identity.
@Suite("AccountDescriptor projection")
struct AccountDescriptorTests {

    @Test("Round-trips through probeConfig without loss")
    func roundTripLossless() {
        let identity = VerifiedIdentity(
            email: "work@example.com",
            orgId: "org-1",
            orgName: "Example",
            verifiedAt: Date(timeIntervalSince1970: 1_700_000_000), // whole seconds
            method: .claudeAuthStatus
        )
        let original = AccountDescriptor(
            uuid: UUID(),
            providerId: "claude",
            label: "Work",
            profile: .claudeConfigDir("/Users/x/.claude-work"),
            source: .native,
            visibility: .hidden,
            verifiedIdentity: identity,
            sortOrder: 3
        )

        let config = ProviderAccountConfig.from(descriptor: original, accountId: "work")
        let restored = config.descriptor(providerId: "claude")

        #expect(restored == original)
    }

    @Test("Router alias profile survives the round-trip")
    func routerAliasRoundTrip() {
        let original = AccountDescriptor(
            providerId: "claude",
            label: "PERSONAL",
            profile: .routerAlias("PERSONAL"),
            source: .router,
            sortOrder: 1
        )
        let config = ProviderAccountConfig.from(descriptor: original, accountId: "personal")
        let restored = config.descriptor(providerId: "claude")
        #expect(restored == original)
    }

    @Test("Renaming the label keeps the uuid and profile")
    func renameKeepsIdentity() {
        var descriptor = AccountDescriptor(
            providerId: "codex",
            label: "Old",
            profile: .codexHome("/Users/x/.codex-a"),
            source: .native
        )
        let uuid = descriptor.uuid
        let config = ProviderAccountConfig.from(descriptor: descriptor, accountId: "a")

        descriptor.label = "New"
        let renamed = ProviderAccountConfig.from(descriptor: descriptor, accountId: "a")
        let restored = renamed.descriptor(providerId: "codex")

        #expect(restored.uuid == uuid)
        #expect(restored.profile == .codexHome("/Users/x/.codex-a"))
        #expect(restored.label == "New")
        // The pre-rename config still points at the same uuid + profile.
        #expect(config.descriptor(providerId: "codex").uuid == uuid)
    }

    @Test("A pre-descriptor config defaults source from the router alias")
    func legacyConfigDefaultsSource() {
        let withAlias = ProviderAccountConfig(
            accountId: "personal", label: "PERSONAL", probeConfig: ["routerAlias": "PERSONAL"]
        )
        #expect(withAlias.descriptor(providerId: "claude").source == .router)

        let nativeOnly = ProviderAccountConfig(
            accountId: "work", label: "Work", probeConfig: ["claudeConfigDir": "/p"]
        )
        #expect(nativeOnly.descriptor(providerId: "claude").source == .native)
    }
}
