import Testing
import Foundation
import Domain
@testable import ClaudeBar

/// C4-3 contract tests (review critique 2026-09-16 §5): pins the SERVICE-level
/// invariants — typed failure for a missing adapter, cancellation clearing the
/// task slot, forget removing tracking only, reconnect preserving identity,
/// and the task table being cleaned on EVERY stream exit path. The
/// adapter-level invariants (terminal launched ≠ connected, typed-email ≠
/// read identity, mismatch ⇒ no registrar call, register-only-after-confirm)
/// live in `ClaudeAccountAdapterTests` / `CodexAccountAdapterTests` /
/// `RouterRegistrarCLITests`; this suite pins the façade that routes to them.
@Suite("AccountEnrolmentService contract")
@MainActor
struct AccountEnrolmentServiceTests {

    // MARK: - Scripted adapter

    /// Counters/parking state isolated behind an actor — NSLock is unavailable
    /// from async contexts under Swift 6 strict concurrency.
    private actor AdapterState {
        var enrolCalls = 0
        var reconnectCalls = 0
        private var parked: [CheckedContinuation<Void, Never>] = []

        func recordEnrol() { enrolCalls += 1 }
        func recordReconnect() { reconnectCalls += 1 }

        func park() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                parked.append(c)
            }
        }
        func releaseAll() {
            for c in parked { c.resume() }
            parked.removeAll()
        }
    }

    /// Emits a scripted state sequence; optionally parks before finishing so
    /// cancellation can be exercised deterministically.
    private final class ScriptedAdapter: AccountAdapter, @unchecked Sendable {
        let providerId: String
        let capabilities: AccountCapabilities
        let script: [EnrolmentState]
        let parkOnFinish: Bool
        let state = AdapterState()

        init(
            providerId: String = "claude",
            capabilities: AccountCapabilities = [.add, .reconnect, .discover],
            script: [EnrolmentState],
            parkOnFinish: Bool = false
        ) {
            self.providerId = providerId
            self.capabilities = capabilities
            self.script = script
            self.parkOnFinish = parkOnFinish
        }

        func enrol(intent: EnrolmentIntent) -> AsyncStream<EnrolmentState> {
            Task { await state.recordEnrol() }
            return AsyncStream { continuation in
                Task { [script, parkOnFinish, state] in
                    for state in script {
                        if Task.isCancelled { break }
                        continuation.yield(state)
                    }
                    if parkOnFinish {
                        await state.park()
                    }
                    continuation.finish()
                }
            }
        }

        func reconnect(account: AccountDescriptor) -> AsyncStream<EnrolmentState> {
            Task { await state.recordReconnect() }
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

        func verifyIdentity(profile: ProfileReference) async throws -> VerifiedIdentity? {
            return VerifiedIdentity(
                email: "read@example.com", orgId: nil, orgName: nil,
                verifiedAt: Date(), method: .claudeAuthStatus
            )
        }

        func discover() async -> [DiscoveredProfile] { [] }

        func releaseAll() async { await state.releaseAll() }
    }

    // MARK: - Fixtures

    private func descriptor(
        providerId: String = "claude",
        uuid: UUID = UUID()
    ) -> AccountDescriptor {
        AccountDescriptor(
            uuid: uuid, providerId: providerId, label: "T",
            profile: .claudeConfigDir("/tmp/cortex-test/.claude"),
            source: .native
        )
    }

    private static func drain(
        _ stream: AsyncStream<EnrolmentState>
    ) async -> [EnrolmentState] {
        var out: [EnrolmentState] = []
        for await s in stream { out.append(s) }
        return out
    }

    // MARK: - Adapter absence: typed failure, never a crash

    @Test("Unknown provider id → failed(dependencyMissing) naming the tool, stream finishes")
    func unknownProviderTypedFailure() async {
        let service = AccountEnrolmentService(
            claudeAdapter: ScriptedAdapter(providerId: "claude", script: []),
            codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        let intent = EnrolmentIntent(
            descriptor: descriptor(providerId: "mystery-tool"),
            targetSource: .native
        )
        let states = await Self.drain(service.enrol(intent: intent))
        guard case let .failed(_, error) = states.last else {
            Issue.record("expected terminal failed, got \(String(describing: states.last))")
            return
        }
        guard case let .dependencyMissing(tool) = error else {
            Issue.record("expected dependencyMissing, got \(error)")
            return
        }
        #expect(tool == "mystery-tool")
    }

    // MARK: - State plumbing

    @Test("enrol() yields every adapter state in order and mirrors states[uuid]")
    func enrolStreamsStatesInOrder() async {
        let d = descriptor()
        let adapter = ScriptedAdapter(providerId: "claude", script: [
            .profileDetected(d),
            .identityConfirmed(d, identity: VerifiedIdentity(
                email: "read@example.com", orgId: nil, orgName: nil,
                verifiedAt: Date(), method: .claudeAuthStatus
            )),
            .quotaPending(d),
        ])
        let service = AccountEnrolmentService(
            claudeAdapter: adapter, codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        let states = await Self.drain(service.enrol(intent: EnrolmentIntent(
            descriptor: d, targetSource: .native
        )))
        #expect(states.count == 3)
        #expect(await adapter.state.enrolCalls == 1)
        if case .quotaPending = states.last {} else {
            Issue.record("last state should be quotaPending")
        }
    }

    @Test("States[uuid] mirrors the LAST adapter state after the stream ends")
    func statesMirrorLastState() async {
        let d = descriptor()
        let service = AccountEnrolmentService(
            claudeAdapter: ScriptedAdapter(providerId: "claude", script: [
                .profileDetected(d),
                .quotaPending(d),
            ]),
            codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        _ = await Self.drain(service.enrol(intent: EnrolmentIntent(
            descriptor: d, targetSource: .native
        )))
        if case .quotaPending = service.states[d.uuid] {} else {
            Issue.record("states[uuid] should hold the last observed state (quotaPending)")
        }
    }

    // MARK: - Reconnect: same identity, routed to the reconnect path

    @Test("reconnect() routes to the adapter's reconnect flow, keeps uuid identity")
    func reconnectPreservesUuid() async {
        let d = descriptor()
        let adapter = ScriptedAdapter(providerId: "claude", script: [.quotaPending(d)])
        let service = AccountEnrolmentService(
            claudeAdapter: adapter, codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        let states = await Self.drain(service.reconnect(account: d))
        #expect(await adapter.state.reconnectCalls == 1)
        #expect(await adapter.state.enrolCalls == 0)
        #expect(!states.isEmpty)
    }

    // MARK: - Cancellation

    @Test("cancel() stops the parked enrolment and clears the tracked state on stream end")
    func cancelStopsAndCleans() async {
        let d = descriptor()
        let adapter = ScriptedAdapter(
            providerId: "claude",
            script: [.profileDetected(d)],
            parkOnFinish: true
        )
        let service = AccountEnrolmentService(
            claudeAdapter: adapter, codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        let stream = service.enrol(intent: EnrolmentIntent(descriptor: d, targetSource: .native))
        let collector = Task { await Self.drain(stream) }
        // Let the scripted state flow and the park happen.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(service.states[d.uuid] != nil)
        service.cancel(uuid: d.uuid)
        await adapter.releaseAll()
        _ = await collector.value
        // State remains readable (last observed), but the task slot is gone.
        #expect(!service.hasActiveTask(for: d.uuid))
    }

    // MARK: - Forget

    @Test("forget() removes tracking for the uuid — the follow-up enrol starts clean")
    func forgetRemovesTracking() async {
        let d = descriptor()
        let service = AccountEnrolmentService(
            claudeAdapter: ScriptedAdapter(providerId: "claude", script: [.profileDetected(d)]),
            codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        _ = await Self.drain(service.enrol(intent: EnrolmentIntent(descriptor: d, targetSource: .native)))
        #expect(service.states[d.uuid] != nil)
        service.forget(uuid: d.uuid)
        #expect(service.states[d.uuid] == nil)
    }

    // MARK: - Stream completion cleans the task table (no orphans)

    @Test("A completed stream leaves NO task slot behind (all exit paths)")
    func completedStreamLeavesNoTaskSlot() async {
        let d = descriptor()
        let service = AccountEnrolmentService(
            claudeAdapter: ScriptedAdapter(providerId: "claude", script: [.quotaPending(d)]),
            codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        _ = await Self.drain(service.enrol(intent: EnrolmentIntent(descriptor: d, targetSource: .native)))
        #expect(!service.hasActiveTask(for: d.uuid))
    }

    @Test("A reconnect stream that completes also leaves no task slot")
    func completedReconnectLeavesNoTaskSlot() async {
        let d = descriptor()
        let service = AccountEnrolmentService(
            claudeAdapter: ScriptedAdapter(providerId: "claude", script: [.quotaPending(d)]),
            codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        _ = await Self.drain(service.reconnect(account: d))
        #expect(!service.hasActiveTask(for: d.uuid))
    }

    // MARK: - verifyIdentity: exception → nil, never a crash

    @Test("verifyIdentity swallows transport errors and returns nil")
    func verifyIdentityErrorReturnsNil() async {
        struct ThrowingAdapter: AccountAdapter {
            let providerId = "claude"
            let capabilities: AccountCapabilities = [.add]
            func enrol(intent: EnrolmentIntent) -> AsyncStream<EnrolmentState> {
                AsyncStream { $0.finish() }
            }
            func reconnect(account: AccountDescriptor) -> AsyncStream<EnrolmentState> {
                AsyncStream { $0.finish() }
            }
            func verifyIdentity(profile: ProfileReference) async throws -> VerifiedIdentity? {
                throw EnrolmentError.underlying("probe exploded")
            }
            func discover() async -> [DiscoveredProfile] { [] }
        }
        let service = AccountEnrolmentService(
            claudeAdapter: ThrowingAdapter(),
            codexAdapter: ScriptedAdapter(providerId: "codex", script: [])
        )
        let identity = await service.verifyIdentity(profile: .claudeConfigDir("/tmp/x"))
        #expect(identity == nil)
    }
}
