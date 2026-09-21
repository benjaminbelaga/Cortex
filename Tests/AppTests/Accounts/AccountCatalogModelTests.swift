import Testing
import Foundation
import Domain
import Infrastructure
@testable import ClaudeBar

/// D tranche — the catalogue façade: `follow`/`enrolNew` route through the
/// verified `AccountEnrolmentService` (never a blind terminal launch), path
/// collisions surface as user-readable errors WITHOUT starting an enrolment,
/// and integrations activate through the injected hook only.
@Suite("AccountCatalogModel")
@MainActor
struct AccountCatalogModelTests {

    // MARK: - Scripted collaborators

    private final class ScriptedAdapter: AccountAdapter, @unchecked Sendable {
        let providerId: String
        let capabilities: AccountCapabilities
        private let lock = NSLock()
        private var enrolCount = 0
        private var lastIntent: EnrolmentIntent?
        let script: [EnrolmentState]

        init(
            providerId: String,
            script: [EnrolmentState] = [],
            capabilities: AccountCapabilities = [.add, .reconnect, .discover]
        ) {
            self.providerId = providerId
            self.capabilities = capabilities
            self.script = script
        }

        func enrolCalls() -> (count: Int, intent: EnrolmentIntent?) {
            lock.withLock { (enrolCount, lastIntent) }
        }

        func enrol(intent: EnrolmentIntent) -> AsyncStream<EnrolmentState> {
            lock.withLock {
                enrolCount += 1
                lastIntent = intent
            }
            return AsyncStream { continuation in
                Task { [script] in
                    for state in script {
                        if Task.isCancelled { break }
                        continuation.yield(state)
                    }
                    continuation.finish()
                }
            }
        }

        func reconnect(account: AccountDescriptor) -> AsyncStream<EnrolmentState> {
            AsyncStream { continuation in
                Task { [script] in
                    for state in script { continuation.yield(state) }
                    continuation.finish()
                }
            }
        }

        func verifyIdentity(profile: ProfileReference) async throws -> VerifiedIdentity? { nil }
        func discover() async -> [DiscoveredProfile] { [] }
    }

    private struct StubResolver: ProfileResolving {
        var proposal: Result<ProfileReference, ProfileResolutionError>

        func candidateProfiles(
            forProvider providerId: String,
            homeDirectory: String,
            userPaths: [String]
        ) -> [DiscoveredProfile] { [] }

        func proposePath(
            forProvider providerId: String,
            label: String,
            homeDirectory: String,
            ownedPaths: [String]
        ) -> Result<ProfileReference, ProfileResolutionError> {
            proposal
        }
    }

    private struct NeverAuthenticating: ProfileIdentityValidating {
        func authenticatedEmail(
            forProvider providerId: String,
            profilePath: String
        ) async -> String? { nil }
    }

    private final class FakeSettings: MultiAccountSettingsRepository, @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: Set<String> = []
        private var configured: [ProviderAccountConfig] = []

        func isEnabled(forProvider id: String) -> Bool { lock.withLock { enabled.contains(id) } }
        func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool {
            lock.withLock { enabled.contains(id) }
        }
        func setEnabled(_ value: Bool, forProvider id: String) {
            lock.withLock {
                if value { enabled.insert(id) } else { enabled.remove(id) }
            }
        }
        func customCardURL(forProvider id: String) -> String? { nil }
        func setCustomCardURL(_ url: String?, forProvider id: String) {}
        func accounts(forProvider id: String) -> [ProviderAccountConfig] {
            lock.withLock { configured }
        }
        func addAccount(_ config: ProviderAccountConfig, forProvider id: String) {
            lock.withLock { configured.append(config) }
        }
        func removeAccount(accountId: String, forProvider id: String) {
            lock.withLock { configured.removeAll { $0.accountId == accountId } }
        }
        func updateAccount(_ config: ProviderAccountConfig, forProvider id: String) {}
        func activeAccountId(forProvider id: String) -> String? { nil }
        func setActiveAccountId(_ accountId: String?, forProvider id: String) {}
    }

    // MARK: - Fixtures

    private func makeModel(
        adapterScript: [EnrolmentState] = [],
        proposal: Result<ProfileReference, ProfileResolutionError> =
            .success(.claudeConfigDir("/tmp/cortex-catalog/.claude-studio")),
        settings: FakeSettings = FakeSettings()
    ) -> (AccountCatalogModel, ScriptedAdapter, FakeSettings) {
        let claude = ScriptedAdapter(providerId: "claude", script: adapterScript)
        let codex = ScriptedAdapter(providerId: "codex", script: [])
        let service = AccountEnrolmentService(claudeAdapter: claude, codexAdapter: codex)
        let model = AccountCatalogModel(
            enrolmentService: service,
            discovery: AccountDiscoveryService(
                resolver: StubResolver(proposal: proposal),
                validator: NeverAuthenticating()
            ),
            resolver: StubResolver(proposal: proposal),
            settingsRepository: settings,
            homeDirectory: "/tmp/cortex-catalog-home"
        ) { _ in }
        return (model, claude, settings)
    }

    private func descriptor(_ providerId: String = "claude") -> AccountDescriptor {
        AccountDescriptor(
            providerId: providerId,
            label: "T",
            profile: .claudeConfigDir("/tmp/cortex-catalog/.claude"),
            source: .native
        )
    }

    // MARK: - Tests

    @Test("follow() routes a discovered profile through the verified enrolment service")
    func followRoutesThroughService() async throws {
        let d = descriptor()
        let (model, adapter, _) = makeModel(adapterScript: [
            .profileDetected(d),
            .quotaPending(d),
        ])
        let proposal = AccountProposal(
            providerId: "claude",
            profile: .claudeConfigDir("/tmp/cortex-catalog/.claude-studio"),
            canonicalPath: "/tmp/cortex-catalog/.claude-studio",
            email: "studio@example.com"
        )

        model.follow(proposal)
        // Drain the scripted stream.
        try await Task.sleep(for: .milliseconds(100))

        let calls = adapter.enrolCalls()
        #expect(calls.count == 1)
        #expect(calls.intent?.descriptor.profile
            == .claudeConfigDir("/tmp/cortex-catalog/.claude-studio"))
        #expect(calls.intent?.expectedIdentityEmail == "studio@example.com",
                "the sweep's read-back identity becomes the expected identity (mismatch fails closed)")
        #expect(!model.states.isEmpty)
        if case .quotaPending = model.states.values.first ?? .cancelled(nil) {} else {
            Issue.record("expected the last scripted state to be mirrored")
        }
    }

    @Test("enrolNew with a colliding path surfaces a readable error and NEVER enrols")
    func collisionNeverEnrols() async throws {
        let (model, adapter, _) = makeModel(
            proposal: .failure(.profileCollision(path: "/tmp/cortex-catalog/.claude-studio"))
        )

        model.enrolNew(providerId: "claude", label: "studio", expectedEmail: nil)
        try await Task.sleep(for: .milliseconds(50))

        #expect(adapter.enrolCalls().count == 0, "no enrolment may start on a proposal failure")
        #expect(model.proposalError?.contains("possède déjà") == true)
        #expect(model.states.isEmpty)
    }

    @Test("enrolNew with an empty label is a no-op")
    func emptyLabelNoOp() async throws {
        let (model, adapter, _) = makeModel()
        model.enrolNew(providerId: "claude", label: "   ", expectedEmail: nil)
        #expect(adapter.enrolCalls().count == 0)
    }

    @Test("integrations activate only through the injected hook")
    func activationThroughHook() {
        var activated: [String] = []
        let claude = ScriptedAdapter(providerId: "claude")
        let model = AccountCatalogModel(
            enrolmentService: AccountEnrolmentService(
                claudeAdapter: claude,
                codexAdapter: ScriptedAdapter(providerId: "codex")
            ),
            discovery: AccountDiscoveryService(
                resolver: StubResolver(proposal: .success(.none)),
                validator: NeverAuthenticating()
            ),
            resolver: StubResolver(proposal: .success(.none)),
            settingsRepository: FakeSettings(),
            homeDirectory: "/tmp"
        ) { activated.append($0) }

        model.activate("qwen-api")
        model.activate("bedrock")

        #expect(activated == ["qwen-api", "bedrock"])
        // La section « connexions » EST le catalogue filtré — jamais une
        // seconde liste qui dériverait de lui (plan Cortex modulaire).
        let integrations = model.integrationDescriptors.map(\.id)
        #expect(integrations == ProviderCatalog.all.filter { $0.category == .integration }.map(\.id),
                "only category .integration descriptors appear in the connections section")
        #expect(integrations.contains("qwen-api") && integrations.contains("bedrock") && integrations.contains("local"))
    }

    @Test("isActiveIntegration reads the explicit isEnabled key (never silently on)")
    func integrationStateFromSettings() {
        let settings = FakeSettings()
        settings.setEnabled(true, forProvider: "local")
        let (model, _, _) = makeModel(settings: settings)

        #expect(model.isActiveIntegration("local"))
        #expect(!model.isActiveIntegration("qwen-api"))
        #expect(!model.isActiveIntegration("bedrock"))
    }
}
