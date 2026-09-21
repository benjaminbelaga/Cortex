import Foundation
import Testing
import Domain
@testable import Infrastructure

@Suite("CodexAccountAdapter")
struct CodexAccountAdapterTests {

    private static func fixtureDescriptor(
        email: String? = nil,
        codexHome: String = "/tmp/claudebar-test/.codex"
    ) -> AccountDescriptor {
        AccountDescriptor(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
            providerId: "codex", label: "Personal",
            profile: .codexHome(codexHome),
            source: .native,
            verifiedIdentity: email.map {
                VerifiedIdentity(
                    email: $0, orgId: nil, orgName: nil,
                    verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    method: .codexAppServer
                )
            }
        )
    }

    private actor StubProbe: CodexAuthStatusProbing {
        let responses: [CodexAuthStatus?]
        private var index = 0

        init(responses: [CodexAuthStatus?]) { self.responses = responses }

        func authStatus(codexHome: String) async -> CodexAuthStatus? {
            let idx = min(index, responses.count - 1)
            index += 1
            return responses[idx]
        }
    }

    private actor StubLauncher: CodexTerminalLoginLaunching {
        let launched: Bool
        private var loginCalls = 0
        private var reconnectCalls = 0

        init(launched: Bool = true) { self.launched = launched }

        func launchLoginShell(codexHome: String) async -> Bool {
            loginCalls += 1
            return launched
        }
        func launchReconnectShell(codexHome: String) async -> Bool {
            reconnectCalls += 1
            return launched
        }

        func loginCallsNow() -> Int { loginCalls }
        func reconnectCallsNow() -> Int { reconnectCalls }
    }

    private static func drain(_ stream: AsyncStream<EnrolmentState>) async -> [EnrolmentState] {
        var out: [EnrolmentState] = []
        for await s in stream { out.append(s) }
        return out
    }

    // MARK: - Happy path

    @Test("Login succeeds — slow path polls → identityConfirmed → quotaPending")
    func enrolSucceedsSlowPath() async {
        let probe = StubProbe(responses: [
            nil,
            CodexAuthStatus(loggedIn: true, email: "personal@y.fr", planType: "plus"),
        ])
        let launcher = StubLauncher()
        let adapter = CodexAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "personal@y.fr",
            targetSource: .native
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
            #expect(identity.email == "personal@y.fr")
            #expect(identity.method == .codexAppServer)
        } else {
            Issue.record("expected identityConfirmed near end, got \(String(describing: lastTwo.first))")
        }
        if case .quotaPending = lastTwo.last {} else {
            Issue.record("expected terminal .quotaPending, got \(String(describing: lastTwo.last))")
        }
    }

    @Test("Already-authed — fast pre-check path skips terminal")
    func enrolFastPath() async {
        let probe = StubProbe(responses: [
            CodexAuthStatus(loggedIn: true, email: "pre@y.fr", planType: "pro"),
        ])
        let launcher = StubLauncher()
        let adapter = CodexAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "pre@y.fr",
            targetSource: .native
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        #expect(await launcher.loginCallsNow() == 0)
        #expect(states.count == 3)
        if case .identityConfirmed = states[1] {} else {
            Issue.record("states[1] should be identityConfirmed, got \(states[1])")
        }
    }

    // MARK: - Failure paths

    @Test("Identity mismatch on slow path → failed(identityMismatch)")
    func enrolIdentityMismatch() async {
        let probe = StubProbe(responses: [
            nil,
            CodexAuthStatus(loggedIn: true, email: "stranger@example.com"),
        ])
        let launcher = StubLauncher()
        let adapter = CodexAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "personal@y.fr",
            targetSource: .native
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        guard let last = states.last, case let .failed(_, error) = last else {
            Issue.record("expected terminal failed")
            return
        }
        if case let .identityMismatch(expected, actual) = error {
            #expect(expected == "personal@y.fr")
            #expect(actual == "stranger@example.com")
        } else {
            Issue.record("expected identityMismatch, got \(error)")
        }
    }

    @Test("Profile collision → failed(profileCollision)")
    func enrolCollision() async {
        let probe = StubProbe(responses: [nil])
        let launcher = StubLauncher()
        let adapter = CodexAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            profileCollisionDetector: { _ in true },
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let intent = EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            targetSource: .native
        )
        let states = await Self.drain(adapter.enrol(intent: intent))
        guard case let .failed(_, error) = states.last else {
            Issue.record("expected failed"); return
        }
        if case let .profileCollision(path) = error {
            #expect(path == "/tmp/claudebar-test/.codex")
        } else {
            Issue.record("expected profileCollision, got \(error)")
        }
        #expect(await launcher.loginCallsNow() == 0)
    }

    @Test("No codexHome → failed(dependencyMissing)")
    func enrolNoPath() async {
        struct Probe: CodexAuthStatusProbing {
            func authStatus(codexHome: String) async -> CodexAuthStatus? { nil }
        }
        struct Launcher: CodexTerminalLoginLaunching {
            func launchLoginShell(codexHome: String) async -> Bool { false }
            func launchReconnectShell(codexHome: String) async -> Bool { false }
        }
        let adapter = CodexAccountAdapter(
            authStatusProbe: Probe(),
            terminalLauncher: Launcher()
        )
        let descriptor = AccountDescriptor(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!,
            providerId: "codex", label: "x",
            profile: .none,
            source: .native
        )
        let states = await Self.drain(adapter.enrol(intent: EnrolmentIntent(
            descriptor: descriptor, targetSource: .native
        )))
        guard case let .failed(_, error) = states.last else {
            Issue.record("expected failed"); return
        }
        if case let .dependencyMissing(tool) = error {
            #expect(tool == "codex")
        } else {
            Issue.record("expected dependencyMissing(codex), got \(error)")
        }
    }

    @Test("Poll never returns authed → failed(timeout)")
    func enrolTimeout() async {
        let probe = StubProbe(responses: [nil])
        let launcher = StubLauncher()
        let adapter = CodexAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.02
        )
        let states = await Self.drain(adapter.enrol(intent: EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            targetSource: .native
        )))
        guard case let .failed(_, error) = states.last else {
            Issue.record("expected failed"); return
        }
        if case let .timeout(after) = error {
            #expect(after > 0 && after <= 0.05, "timeout should be ~0.02s, got \(after)")
        } else {
            Issue.record("expected timeout, got \(error)")
        }
    }

    // MARK: - Reconnect

    @Test("Reconnect explicit — reconnect shell called with explicitReconnect")
    func reconnectRunsReconnect() async {
        let probe = StubProbe(responses: [
            CodexAuthStatus(loggedIn: true, email: "personal@y.fr"),
        ])
        let launcher = StubLauncher()
        let adapter = CodexAccountAdapter(
            authStatusProbe: probe,
            terminalLauncher: launcher,
            pollInterval: .milliseconds(1),
            pollTimeout: 0.5
        )
        let account = Self.fixtureDescriptor(email: "personal@y.fr")
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

    @Test("verifyIdentity on .codexHome returns identity when authed")
    func verifyIdentityCodex() async throws {
        struct Probe: CodexAuthStatusProbing {
            func authStatus(codexHome: String) async -> CodexAuthStatus? {
                CodexAuthStatus(loggedIn: true, email: "p@y.fr", planType: "pro", accountId: "acct_1")
            }
        }
        let adapter = CodexAccountAdapter(
            authStatusProbe: Probe(),
            terminalLauncher: StubLauncher()
        )
        let v = try await adapter.verifyIdentity(profile: .codexHome("/tmp/x"))
        #expect(v?.email == "p@y.fr")
        #expect(v?.method == .codexAppServer)
    }

    @Test("verifyIdentity returns nil for non-codex profile")
    func verifyIdentityWrongProfile() async throws {
        struct Probe: CodexAuthStatusProbing {
            func authStatus(codexHome: String) async -> CodexAuthStatus? { nil }
        }
        let adapter = CodexAccountAdapter(
            authStatusProbe: Probe(),
            terminalLauncher: StubLauncher()
        )
        let v = try await adapter.verifyIdentity(profile: .routerAlias("WORK"))
        #expect(v == nil)
    }
}
