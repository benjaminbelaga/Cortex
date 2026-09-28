import Foundation
import Testing
import Domain
@testable import Infrastructure

@Suite("AlibabaAccountAdapter")
struct AlibabaAccountAdapterTests {

    private static func fixtureDescriptor(
        profile: String = "cortex-monitor",
        verified: String? = nil
    ) -> AccountDescriptor {
        AccountDescriptor(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-00000000A11B")!,
            providerId: "qwen", label: "Token Plan",
            profile: .bailianProfile(profile),
            source: .native,
            verifiedIdentity: verified.map {
                VerifiedIdentity(
                    email: $0, orgId: nil, orgName: nil,
                    verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    method: .alibabaConsole
                )
            }
        )
    }

    private static func workspaceStatus(_ id: String = "ws-hhugyjljove6wldy") -> AlibabaAuthStatus {
        AlibabaAuthStatus(
            authenticated: true, config: "cortex-monitor",
            apiKey: .init(source: "config", masked: "sk-w…QvzE",
                          baseURL: "https://\(id).ap-southeast-1.maas.aliyuncs.com"),
            console: .init(source: "config", masked: "890b…3402",
                           region: "ap-southeast-1", site: "international")
        )
    }

    private actor StubProbe: AlibabaAuthStatusProbing {
        let responses: [AlibabaAuthStatus?]
        private var index = 0
        init(responses: [AlibabaAuthStatus?]) { self.responses = responses }
        func authStatus(profile: String) async -> AlibabaAuthStatus? {
            let idx = min(index, responses.count - 1)
            index += 1
            return responses[idx]
        }
    }

    private actor StubLauncher: AlibabaTerminalLoginLaunching {
        let launched: Bool
        private var loginCalls = 0
        private var reconnectCalls = 0
        private var lastSite: String?
        init(launched: Bool = true) { self.launched = launched }
        func launchLoginShell(profile: String, site: String) async -> Bool {
            loginCalls += 1; lastSite = site; return launched
        }
        func launchReconnectShell(profile: String, site: String) async -> Bool {
            reconnectCalls += 1; lastSite = site; return launched
        }
        func loginCallsNow() -> Int { loginCalls }
        func reconnectCallsNow() -> Int { reconnectCalls }
        func lastSiteNow() -> String? { lastSite }
    }

    private static func drain(_ stream: AsyncStream<EnrolmentState>) async -> [EnrolmentState] {
        var out: [EnrolmentState] = []
        for await s in stream { out.append(s) }
        return out
    }

    // MARK: - Happy paths

    @Test("Login succeeds — slow path polls → identityConfirmed → quotaPending")
    func enrolSucceedsSlowPath() async {
        let probe = StubProbe(responses: [nil, Self.workspaceStatus()])
        let launcher = StubLauncher()
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: probe, terminalLauncher: launcher,
            pollInterval: .milliseconds(1), pollTimeout: 0.5
        )
        let states = await Self.drain(adapter.enrol(intent: EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "ws-hhugyjljove6wldy",
            targetSource: .native
        )))
        #expect(await launcher.loginCallsNow() == 1)
        guard case .profileDetected = states.first else {
            Issue.record("first state should be .profileDetected, got \(String(describing: states.first))")
            return
        }
        let lastTwo = Array(states.suffix(2))
        if case let .identityConfirmed(_, identity) = lastTwo.first {
            #expect(identity.email == "ws-hhugyjljove6wldy")
            #expect(identity.method == .alibabaConsole)
            #expect(identity.orgId == "ws-hhugyjljove6wldy")
        } else {
            Issue.record("expected identityConfirmed near end, got \(String(describing: lastTwo.first))")
        }
        if case .quotaPending = lastTwo.last {} else {
            Issue.record("expected terminal .quotaPending, got \(String(describing: lastTwo.last))")
        }
    }

    @Test("Already-authenticated — fast pre-check skips the terminal")
    func enrolFastPath() async {
        let probe = StubProbe(responses: [Self.workspaceStatus()])
        let launcher = StubLauncher()
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: probe, terminalLauncher: launcher,
            pollInterval: .milliseconds(1), pollTimeout: 0.5
        )
        let states = await Self.drain(adapter.enrol(intent: EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(), targetSource: .native
        )))
        #expect(await launcher.loginCallsNow() == 0)
        #expect(states.contains { if case .identityConfirmed = $0 { return true } else { return false } })
    }

    @Test("Console site is threaded into the launched login command")
    func siteIsThreaded() async {
        let probe = StubProbe(responses: [nil, Self.workspaceStatus()])
        let launcher = StubLauncher()
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: probe, terminalLauncher: launcher,
            consoleSite: "domestic",
            pollInterval: .milliseconds(1), pollTimeout: 0.5
        )
        _ = await Self.drain(adapter.enrol(intent: EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(), targetSource: .native
        )))
        #expect(await launcher.lastSiteNow() == "domestic")
    }

    // MARK: - Reconnect

    @Test("Reconnect — no profileDetected, launches reconnect, succeeds")
    func reconnectSucceeds() async {
        let probe = StubProbe(responses: [nil, Self.workspaceStatus()])
        let launcher = StubLauncher()
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: probe, terminalLauncher: launcher,
            pollInterval: .milliseconds(1), pollTimeout: 0.5
        )
        let states = await Self.drain(adapter.reconnect(account: Self.fixtureDescriptor()))
        #expect(await launcher.reconnectCallsNow() == 1)
        #expect(await launcher.loginCallsNow() == 0)
        #expect(!states.contains { if case .profileDetected = $0 { return true } else { return false } })
        if case .authRequired(_, let reason) = states.first {
            #expect(reason == .explicitReconnect)
        } else {
            Issue.record("reconnect should start with .authRequired(.explicitReconnect)")
        }
    }

    // MARK: - Failure modes

    @Test("Identity mismatch fails closed")
    func identityMismatch() async {
        let probe = StubProbe(responses: [Self.workspaceStatus("ws-OTHER")])
        let launcher = StubLauncher()
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: probe, terminalLauncher: launcher,
            pollInterval: .milliseconds(1), pollTimeout: 0.5
        )
        let states = await Self.drain(adapter.enrol(intent: EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(),
            expectedIdentityEmail: "ws-hhugyjljove6wldy", targetSource: .native
        )))
        if case .failed(_, let error) = states.last {
            guard case .identityMismatch(let expected, let actual) = error else {
                Issue.record("expected identityMismatch, got \(error)"); return
            }
            #expect(expected == "ws-hhugyjljove6wldy")
            #expect(actual == "ws-OTHER")
        } else {
            Issue.record("expected terminal .failed, got \(String(describing: states.last))")
        }
    }

    @Test("Poll timeout surfaces a typed failure, never a false success")
    func pollTimeout() async {
        let probe = StubProbe(responses: [nil, nil, nil])
        let launcher = StubLauncher()
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: probe, terminalLauncher: launcher,
            pollInterval: .milliseconds(1), pollTimeout: 0.01
        )
        let states = await Self.drain(adapter.enrol(intent: EnrolmentIntent(
            descriptor: Self.fixtureDescriptor(), targetSource: .native
        )))
        if case .failed(_, let error) = states.last {
            if case .timeout = error {} else { Issue.record("expected .timeout, got \(error)") }
        } else {
            Issue.record("expected terminal .failed(.timeout), got \(String(describing: states.last))")
        }
    }

    @Test("A profile name outside the bailian shape is refused")
    func wrongProfileKind() async {
        let probe = StubProbe(responses: [Self.workspaceStatus()])
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: probe, terminalLauncher: StubLauncher(),
            pollInterval: .milliseconds(1), pollTimeout: 0.5
        )
        let wrong = AccountDescriptor(
            providerId: "qwen", label: "x", profile: .none, source: .native
        )
        let states = await Self.drain(adapter.enrol(intent: EnrolmentIntent(
            descriptor: wrong, targetSource: .native
        )))
        if case .failed(_, let error) = states.last {
            guard case .dependencyMissing(let tool) = error else {
                Issue.record("expected dependencyMissing, got \(error)"); return
            }
            #expect(tool == "bl")
        } else {
            Issue.record("expected terminal .failed, got \(String(describing: states.last))")
        }
    }

    @Test("verifyIdentity reads back the workspace principal")
    func verifyIdentityReadsBack() async throws {
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: StubProbe(responses: [Self.workspaceStatus()]),
            terminalLauncher: StubLauncher()
        )
        let identity = try await adapter.verifyIdentity(profile: .bailianProfile("cortex-monitor"))
        #expect(identity?.email == "ws-hhugyjljove6wldy")
        #expect(identity?.method == .alibabaConsole)
    }

    @Test("verifyIdentity returns nil for a non-bailian profile")
    func verifyIdentityWrongKind() async throws {
        let adapter = AlibabaAccountAdapter(
            authStatusProbe: StubProbe(responses: [Self.workspaceStatus()]),
            terminalLauncher: StubLauncher()
        )
        let identity = try await adapter.verifyIdentity(profile: .codexHome("/tmp/x"))
        #expect(identity == nil)
    }
}
