import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

/// Pins the reconciling discovery sweep: each validation is time-bounded,
/// cancellation stops it early, an explicitly rejected profile is never
/// re-proposed, and a new profile is proposed even when accounts already exist
/// (the old early-return-on-existing behaviour is gone).
@Suite("AccountDiscoveryService")
struct AccountDiscoveryServiceTests {

    // Paths under a non-existent, symlink-free root so realpath is identity.
    private static func candidate(_ name: String) -> DiscoveredProfile {
        let path = "/opt/cortex-test/\(name)"
        return DiscoveredProfile(
            providerId: "claude", profile: .claudeConfigDir(path), canonicalPath: path
        )
    }

    private struct StubResolver: ProfileResolving {
        let candidates: [DiscoveredProfile]
        func candidateProfiles(forProvider: String, homeDirectory: String, userPaths: [String]) -> [DiscoveredProfile] {
            candidates
        }
        func proposePath(forProvider: String, label: String, homeDirectory: String, ownedPaths: [String]) -> Result<ProfileReference, ProfileResolutionError> {
            .failure(.unsupportedProvider(forProvider))
        }
    }

    private struct StubValidator: ProfileIdentityValidating {
        let emails: [String: String]      // canonicalPath -> email (absent = not authed)
        let delay: Duration?
        func authenticatedEmail(forProvider providerId: String, profilePath: String) async -> String? {
            if let delay { try? await Task.sleep(for: delay) }
            return emails[profilePath]
        }
    }

    /// Deterministic validator for the cancellation test (review critique
    /// 2026-09-16): signals the moment it is entered, then parks on an async
    /// latch until the test releases it. No fixed sleep, no wall-clock race —
    /// the old 200 ms sleep was the flake (sig `ed9e22ba0b42136d`).
    private actor LatchValidator: ProfileIdentityValidating {
        private var entryCount = 0
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var parked: [CheckedContinuation<String?, Never>] = []

        func authenticatedEmail(
            forProvider providerId: String, profilePath: String
        ) async -> String? {
            entryCount += 1
            for w in entryWaiters { w.resume() }
            entryWaiters.removeAll()
            return await withCheckedContinuation { c in
                parked.append(c)
            }
        }

        /// Suspends until at least one validation call is parked inside.
        func awaitFirstEntry() async {
            if entryCount > 0 { return }
            await withCheckedContinuation { c in
                entryWaiters.append(c)
            }
        }

        /// Lets every parked call return `nil` so cancellation can propagate.
        func releaseAll() {
            for c in parked { c.resume(returning: nil) }
            parked.removeAll()
        }
    }

    @Test("Authenticated candidates are proposed, unauthenticated dropped")
    func proposesAuthenticatedOnly() async {
        let service = AccountDiscoveryService(
            resolver: StubResolver(candidates: [Self.candidate("a"), Self.candidate("b")]),
            validator: StubValidator(emails: ["/opt/cortex-test/a": "a@x.com"], delay: nil)
        )
        let proposals = await service.discover(
            forProvider: "claude", homeDirectory: "/opt", existing: []
        )
        #expect(proposals.map(\.canonicalPath) == ["/opt/cortex-test/a"])
        #expect(proposals.first?.email == "a@x.com")
    }

    @Test("A slow validator is bounded by the per-candidate timeout")
    func perCandidateTimeout() async {
        let service = AccountDiscoveryService(
            resolver: StubResolver(candidates: [Self.candidate("a")]),
            validator: StubValidator(emails: ["/opt/cortex-test/a": "a@x.com"], delay: .seconds(10))
        )
        let start = Date()
        let proposals = await service.discover(
            forProvider: "claude", homeDirectory: "/opt", existing: [],
            perCandidateTimeout: 0.3, totalBudget: 5
        )
        #expect(proposals.isEmpty) // timed out before the email arrived
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("Cancellation stops the sweep early (deterministic latch — no fixed sleep)")
    func cancellationStopsEarly() async throws {
        let validator = LatchValidator()
        let service = AccountDiscoveryService(
            resolver: StubResolver(candidates: [Self.candidate("a"), Self.candidate("b")]),
            validator: validator
        )
        let task = Task {
            await service.discover(
                forProvider: "claude", homeDirectory: "/opt", existing: [],
                perCandidateTimeout: 10, totalBudget: 30
            )
        }
        // Wait until a validation is genuinely in flight — no startup race.
        await validator.awaitFirstEntry()
        task.cancel()
        // Unblock the parked call so the cancellation can propagate through
        // the task group instead of racing a 10 s sleep.
        await validator.releaseAll()
        let start = Date()
        let proposals = await task.value
        #expect(proposals.isEmpty)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("A rejected profile is never re-proposed")
    func rejectedNotReproposed() async {
        let rejected = AccountDescriptor(
            providerId: "claude", label: "old", profile: .claudeConfigDir("/opt/cortex-test/a"),
            source: .native, visibility: .rejected
        )
        let service = AccountDiscoveryService(
            resolver: StubResolver(candidates: [Self.candidate("a"), Self.candidate("b")]),
            validator: StubValidator(
                emails: ["/opt/cortex-test/a": "a@x.com", "/opt/cortex-test/b": "b@x.com"], delay: nil
            )
        )
        let proposals = await service.discover(
            forProvider: "claude", homeDirectory: "/opt", existing: [rejected]
        )
        #expect(proposals.map(\.canonicalPath) == ["/opt/cortex-test/b"])
    }

    @Test("A new profile is proposed even when accounts already exist")
    func proposesNewDespiteExisting() async {
        let owned = AccountDescriptor(
            providerId: "claude", label: "tracked", profile: .claudeConfigDir("/opt/cortex-test/a"),
            source: .native
        )
        let service = AccountDiscoveryService(
            resolver: StubResolver(candidates: [Self.candidate("a"), Self.candidate("b")]),
            validator: StubValidator(
                emails: ["/opt/cortex-test/a": "a@x.com", "/opt/cortex-test/b": "b@x.com"], delay: nil
            )
        )
        let proposals = await service.discover(
            forProvider: "claude", homeDirectory: "/opt", existing: [owned]
        )
        // 'a' is already tracked; only the new 'b' is proposed.
        #expect(proposals.map(\.canonicalPath) == ["/opt/cortex-test/b"])
    }
}
