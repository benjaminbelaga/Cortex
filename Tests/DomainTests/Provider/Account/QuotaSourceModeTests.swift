import Testing
import Foundation
@testable import Domain

/// Pins the source-mode policy: a `.router` request degrades to `.autonomous`
/// ONLY when the router is actually unreachable; a `.autonomous` request is
/// honoured regardless of router availability; the configured value rides alone
/// until router state forces a demotion.
@Suite("QuotaSourceMode")
struct QuotaSourceModeTests {

    private func account(probe: [String: String]) -> ProviderAccountConfig {
        ProviderAccountConfig(
            accountId: "a", label: "l", probeConfig: probe
        )
    }

    @Test("`.router` is honoured when the router is reachable")
    func routerRequestHonouredWhenAvailable() {
        let resolver = QuotaSourceResolver()
        let resolved = resolver.resolve(
            providerId: "claude",
            accounts: [account(probe: ["providers.claude.sourceMode": "router"])],
            routerAvailable: true
        )
        #expect(resolved.configured == .router)
        #expect(resolved.effective == .router)
        #expect(resolved.degradedTo == nil)
    }

    @Test("`.router` degrades to `.autonomous` when the router is unavailable")
    func routerRequestDegradesWhenUnavailable() {
        let resolver = QuotaSourceResolver()
        let resolved = resolver.resolve(
            providerId: "claude",
            accounts: [account(probe: ["providers.claude.sourceMode": "router"])],
            routerAvailable: false
        )
        #expect(resolved.configured == .router)
        #expect(resolved.effective == .autonomous)
        #expect(resolved.degradedTo == .autonomous)
    }

    @Test("`.autonomous` is independent of router availability")
    func autonomousRequestIgnoresRouter() {
        let resolver = QuotaSourceResolver()
        let routerOn = resolver.resolve(
            providerId: "claude",
            accounts: [account(probe: ["providers.claude.sourceMode": "autonomous"])],
            routerAvailable: true
        )
        let routerOff = resolver.resolve(
            providerId: "claude",
            accounts: [account(probe: ["providers.claude.sourceMode": "autonomous"])],
            routerAvailable: false
        )
        #expect(routerOn.effective == .autonomous)
        #expect(routerOn.degradedTo == nil)
        #expect(routerOff.effective == .autonomous)
        #expect(routerOff.degradedTo == nil)
    }

    @Test("No override uses the global default")
    func globalDefaultWhenNoOverride() {
        let resolver = QuotaSourceResolver()
        let resolved = resolver.resolve(
            providerId: "codex", accounts: [], routerAvailable: false,
            globalDefault: .router
        )
        #expect(resolved.configured == .router)
        #expect(resolved.effective == .autonomous) // router unavailable
        #expect(resolved.degradedTo == .autonomous)
    }

    @Test("Unknown override value falls back to the global default")
    func unknownOverrideFallsBack() {
        let resolver = QuotaSourceResolver()
        let resolved = resolver.resolve(
            providerId: "claude",
            accounts: [account(probe: ["providers.claude.sourceMode": "bogus"])],
            routerAvailable: true, globalDefault: .autonomous
        )
        #expect(resolved.configured == .autonomous)
        #expect(resolved.effective == .autonomous)
    }

    @Test("Installed fresh: every provider defaults to `.autonomous`")
    func freshInstallDefaultsToAutonomous() {
        let resolver = QuotaSourceResolver()
        for id in ["claude", "codex", "bedrock", "local"] {
            let resolved = resolver.resolve(providerId: id, accounts: [], routerAvailable: true)
            #expect(resolved.configured == .autonomous)
            #expect(resolved.effective == .autonomous)
            #expect(resolved.degradedTo == nil)
        }
    }
}
