import Testing
import Foundation
import Domain
@testable import Infrastructure

/// Pins the `bailianProfile` projection: the descriptor round-trips through the
/// legacy `ProviderAccountConfig` storage shape without loss, and the key is
/// cleared when the profile is not a bailian one (no stale key survives).
@Suite("Bailian profile projection")
struct BailianProfileProjectionTests {

    @Test("bailianProfile round-trips through ProviderAccountConfig")
    func roundTrip() {
        let descriptor = AccountDescriptor(
            providerId: "qwen", label: "Token Plan",
            profile: .bailianProfile("cortex-monitor"), source: .native
        )
        let config = ProviderAccountConfig.from(descriptor: descriptor, accountId: "default")
        #expect(config.probeConfig["bailianProfile"] == "cortex-monitor")
        let readBack = config.descriptor(providerId: "qwen")
        #expect(readBack.profile == .bailianProfile("cortex-monitor"))
        #expect(readBack.source == .native)
        #expect(readBack.uuid == descriptor.uuid)
    }

    @Test("Switching to a non-bailian profile clears the stale key")
    func clearsStaleKey() {
        let first = ProviderAccountConfig.from(
            descriptor: AccountDescriptor(
                providerId: "qwen", label: "Token Plan",
                profile: .bailianProfile("cortex-monitor"), source: .native),
            accountId: "default"
        )
        let switched = ProviderAccountConfig.from(
            descriptor: AccountDescriptor(
                providerId: "qwen", label: "Token Plan",
                profile: .routerAlias("QWEN"), source: .router),
            accountId: "default",
            preserving: first.probeConfig
        )
        #expect(switched.probeConfig["bailianProfile"] == nil)
        #expect(switched.probeConfig["routerAlias"] == "QWEN")
        #expect(switched.descriptor(providerId: "qwen").profile == .routerAlias("QWEN"))
    }

    @Test("localPath is nil for a bailian profile (it is a name, not a directory)")
    func localPathIsNil() {
        #expect(ProfileReference.bailianProfile("x").localPath == nil)
        #expect(ProfileReference.bailianProfile("x").bailianProfileName == "x")
        #expect(ProfileReference.none.bailianProfileName == nil)
    }
}
