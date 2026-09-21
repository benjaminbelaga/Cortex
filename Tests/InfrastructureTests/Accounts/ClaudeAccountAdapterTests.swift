import Foundation
import Testing
import Domain
@testable import Infrastructure

@Suite("ClaudeAccountAdapter")
struct ClaudeAccountAdapterTests {

    // MARK: - Test fixtures

    private static func fixtureDescriptor(
        email: String? = nil,
        profilePath: String = "/tmp/claudebar-test/profile"
    ) -> AccountDescriptor {
        AccountDescriptor(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            providerId: "claude", label: "Personal",
            profile: .claudeConfigDir(profilePath),
            source: .router,
            verifiedIdentity: email.map {
                VerifiedIdentity(
                    email: $0, orgId: nil, orgName: nil,
                    verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    method: .claudeAuthStatus
                )
            }
        )
    }

    /// Reference-typed actor-based stub. Swift 6 strict concurrency forbids
    /// mutating a struct's stored property from inside an `async` method's
    /// body, and NSLock is unavailable from async contexts. An `actor`
    /// satisfies `Sendable` (compatible with the protocol) without any
    /// unsafeSendable escape hatch.
    private actor StubProbe: ClaudeAuthStatusProbing {
        let responses: [ClaudeAuthStatus?]
        private var index = 0

        init(responses: [ClaudeAuthStatus?]) { self.responses = responses }

        func authStatus(configDirectory: String) async -> ClaudeAuthStatus? {
            let idx = min(index, responses.count - 1)
            index += 1
            return responses[idx]
        }
    }

    private actor StubLauncher: TerminalLoginLaunching {
        let launched: Bool
        private var loginCalls = 0
        private var reconnectCalls = 0

        init(launched: Bool = true) { self.launched = launched }

        func launchLoginShell(profile: String) async -> Bool {
            loginCalls += 1
            return launched
        }
        func launchReconnectShell(profile: String) async -> Bool {
            reconnectCalls += 1
            return launched
        }

        func loginCallsNow() -> Int { loginCalls }
        func reconnectCallsNow() -> Int { reconnectCalls }
    }

    private static func drain(_ stream: AsyncStream<EnrolmentState>) async -> [EnrolmentState] {
        var out: [EnrolmentState] = []
        for await state in stream { out.append(state) }
        return out
    }

    // MARK: - Happy paths

    @Test("Login succeeds — fresh enrol polls → identity confirmed → quota pending")
    func enrolSucceeds() async {
        let probe = StubProbe(responses: [
            nil,
            ClaudeAuthStatus(loggedIn: true, email: "personal@example.com"),
        ])
        let launcher = StubLauncher()
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "personal@example.com",
            targetSource: .router
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        #expect(states.count >= 5)
        #expect(await launcher.loginCallsNow() == 1)
        guard case .profileDetected = states.first else {
            Issue.record("first state should be .profileDetected, got \(String(describing: states.first))")
            return
        }
        let lastTwo = Array(states.suffix(2))
        if case let .identityConfirmed(_, identity) = lastTwo.first {
            #expect(identity.email == "personal@example.com")
        } else {
            Issue.record("expected identityConfirmed near end, got \(String(describing: lastTwo.first))")
        }
        if case .quotaPending = lastTwo.last {} else {
            Issue.record("expected terminal .quotaPending, got \(String(describing: lastTwo.last))")
        }
    }

    @Test("Already-authed account takes the fast pre-check path")
    func enrolFastPath() async {
        let probe = StubProbe(responses: [
            ClaudeAuthStatus(loggedIn: true, email: "pre@example.com"),
        ])
        let launcher = StubLauncher()
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "pre@example.com",
            targetSource: .router
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        #expect(await launcher.loginCallsNow() == 0, "Fast path must skip terminal launch")
        #expect(states.count == 3)
        if case .identityConfirmed = states[1] {} else {
            Issue.record("states[1] should be identityConfirmed, got \(states[1])")
        }
    }

    // MARK: - Failure paths

    @Test("Identity mismatch → failed(identityMismatch) on slow path")
    func enrolIdentityMismatch() async {
        // First probe returns nil → triggers launch + poll path. Second
        // probe returns authed but a different email → mismatch emits in the
        // poll loop (after the terminal was launched).
        let probe = StubProbe(responses: [
            nil,
            ClaudeAuthStatus(loggedIn: true, email: "stranger@example.com"),
        ])
        let launcher = StubLauncher()
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "personal@example.com",
            targetSource: .router
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        guard let last = states.last else {
            Issue.record("no states"); return
        }
        if case let .failed(_, error) = last {
            guard case let .identityMismatch(expected, actual) = error else {
                Issue.record("expected identityMismatch, got \(error)"); return
            }
            #expect(expected == "personal@example.com")
            #expect(actual == "stranger@example.com")
        } else {
            Issue.record("expected terminal failed, got \(last)")
        }
        #expect(await launcher.loginCallsNow() == 1)
    }

    @Test("Identity mismatch on fast path — already-authed, different email")
    func enrolIdentityMismatchFastPath() async {
        let probe = StubProbe(responses: [
            ClaudeAuthStatus(loggedIn: true, email: "stranger@example.com"),
        ])
        let launcher = StubLauncher()
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "personal@example.com",
            targetSource: .router
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        guard let last = states.last else {
            Issue.record("no states"); return
        }
        if case let .failed(_, error) = last {
            guard case let .identityMismatch(expected, actual) = error else {
                Issue.record("expected identityMismatch, got \(error)"); return
            }
            #expect(expected == "personal@example.com")
            #expect(actual == "stranger@example.com")
        } else {
            Issue.record("expected terminal failed, got \(last)")
        }
        #expect(await launcher.loginCallsNow() == 0, "Fast path must short-circuit before terminal launch")
    }

    @Test("Profile collision → failed(profileCollision)")
    func enrolProfileCollision() async {
        let probe = StubProbe(responses: [nil])
        let launcher = StubLauncher()
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            profileCollisionDetector: { _ in true },
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            targetSource: .router
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        guard case let .failed(_, error) = states.last else {
            Issue.record("expected failed at end"); return
        }
        if case let .profileCollision(path) = error {
            #expect(path == "/tmp/claudebar-test/profile")
        } else {
            Issue.record("expected profileCollision, got \(error)")
        }
        #expect(await launcher.loginCallsNow() == 0, "Collision must short-circuit before terminal launch")
    }

    @Test("No local path → failed(dependencyMissing)")
    func enrolNoProfilePath() async {
        struct Probe: ClaudeAuthStatusProbing {
            func authStatus(configDirectory: String) async -> ClaudeAuthStatus? { nil }
        }
        struct Launcher: TerminalLoginLaunching {
            func launchLoginShell(profile: String) async -> Bool { false }
            func launchReconnectShell(profile: String) async -> Bool { false }
        }
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: Probe(),
            terminalLauncher: Launcher()
        )
        let descriptor = AccountDescriptor(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            providerId: "claude", label: "x",
            profile: .none,
            source: .router
        )
        let intent = EnrolmentIntent(descriptor: descriptor, targetSource: .router)
        let states = await Self.drain(adapter.enrol(intent: intent))
        guard case let .failed(_, error) = states.last else {
            Issue.record("expected failed"); return
        }
        if case let .dependencyMissing(tool) = error {
            #expect(tool == "claude")
        } else {
            Issue.record("expected dependencyMissing, got \(error)")
        }
    }

    @Test("Poll never returns authed → failed(timeout)")
    func enrolTimeout() async {
        let probe = StubProbe(responses: [nil])
        let launcher = StubLauncher()
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.02
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            targetSource: .router
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        guard case let .failed(_, error) = states.last else {
            Issue.record("expected failed at end"); return
        }
        if case let .timeout(after) = error {
            #expect(after > 0 && after <= 0.05, "timeout should be ~0.02s, got \(after)")
        } else {
            Issue.record("expected timeout, got \(error)")
        }
    }

    // MARK: - Reconnect

    @Test("Reconnect explicit — terminal launched with reconnect reason")
    func reconnectRunsLoginShell() async {
        let probe = StubProbe(responses: [
            ClaudeAuthStatus(loggedIn: true, email: "personal@example.com"),
        ])
        let launcher = StubLauncher()
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let account = Self.fixtureDescriptor(email: "personal@example.com")
        let states = await Self.drain(adapter.reconnect(account: account))
        #expect(await launcher.reconnectCallsNow() == 1)
        let hasExplicit = states.contains { state in
            if case let .authRequired(_, reason) = state, reason == .explicitReconnect {
                return true
            }
            return false
        }
        #expect(hasExplicit)
    }

    // MARK: - verifyIdentity

    @Test("verifyIdentity returns nil for non-claude profile")
    func verifyIdentityWrongProfile() async throws {
        struct Probe: ClaudeAuthStatusProbing {
            func authStatus(configDirectory: String) async -> ClaudeAuthStatus? {
                ClaudeAuthStatus(loggedIn: true, email: "x@y.fr")
            }
        }
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: Probe(),
            terminalLauncher: StubLauncher()
        )
        let v = try await adapter.verifyIdentity(profile: .routerAlias("WORK"))
        #expect(v == nil)
    }

    @Test("verifyIdentity returns identity when authed + email present")
    func verifyIdentityOK() async throws {
        struct Probe: ClaudeAuthStatusProbing {
            func authStatus(configDirectory: String) async -> ClaudeAuthStatus? {
                ClaudeAuthStatus(
                    loggedIn: true,
                    email: "ben@example.com",
                    orgId: "org_42",
                    orgName: "Acme",
                    subscriptionType: "pro"
                )
            }
        }
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: Probe(),
            terminalLauncher: StubLauncher()
        )
        let v = try await adapter.verifyIdentity(profile: .claudeConfigDir("/tmp/x"))
        #expect(v != nil)
        #expect(v?.email == "ben@example.com")
        #expect(v?.orgId == "org_42")
        #expect(v?.orgName == "Acme")
        #expect(v?.method == .claudeAuthStatus)
        // subscriptionType is intentionally NOT projected onto VerifiedIdentity —
        // the Domain type has no such field. The probe still parses it from
        // `claude auth status --json`; the adapter drops it on the floor
        // through `verifiedIdentity(at:)`.
    }

    @Test("verifyIdentity returns nil when not logged in")
    func verifyIdentityLoggedOut() async throws {
        struct Probe: ClaudeAuthStatusProbing {
            func authStatus(configDirectory: String) async -> ClaudeAuthStatus? {
                ClaudeAuthStatus(loggedIn: false, email: nil)
            }
        }
        let adapter = ClaudeAccountAdapter(
            authStatusProbe: Probe(),
            terminalLauncher: StubLauncher()
        )
        let v = try await adapter.verifyIdentity(profile: .claudeConfigDir("/tmp/x"))
        #expect(v == nil)
    }
}
