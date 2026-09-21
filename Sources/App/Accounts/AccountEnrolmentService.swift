import Foundation
import Domain
import Infrastructure

/// **AccountEnrolmentService** — the single façade that the catalogue UI,
/// settings screen, and per-account Reconnect buttons dispatch through. It
/// owns the lifetime of one enrolment at a time (per providerId) and exposes
/// the latest observed state via `@Observable` so SwiftUI renders it
/// without a polling bridge.
///
@MainActor
@Observable
public final class AccountEnrolmentService {

    /// One slot per active enrolment, keyed by descriptor `uuid`. The UI
    /// reads this directly to render the right row's state.
    public private(set) var states: [UUID: EnrolmentState] = [:]

    /// Adapters indexed by providerId. Constructed with the Claude and Codex
    /// adapters by default; new tools plug in here.
    private let adaptersByProvider: [String: any AccountAdapter]

    private let onVerified: @MainActor (AccountDescriptor) async throws -> Date?

    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Test/contract visibility: whether a live task slot still exists for
    /// `uuid`. False after every stream exit path (completion, cancellation).
    public func hasActiveTask(for uuid: UUID) -> Bool {
        tasks.keys.contains(uuid)
    }

    public init(
        claudeAdapter: any AccountAdapter = ClaudeAccountAdapter(
            authStatusProbe: ClaudeAuthStatusCLIProbe(),
            terminalLauncher: AppleScriptTerminalLoginLauncher()
        ),
        onVerified: @escaping @MainActor (AccountDescriptor) async throws -> Date? = { _ in nil },
        codexAdapter: any AccountAdapter = CodexAccountAdapter(
            authStatusProbe: CodexAuthStatusRPCProbe(),
            terminalLauncher: AppleScriptTerminalLoginLauncher()
        )
    ) {
        self.onVerified = onVerified
        var adapters: [String: any AccountAdapter] = [:]
        adapters[claudeAdapter.providerId] = claudeAdapter
        adapters[codexAdapter.providerId] = codexAdapter
        self.adaptersByProvider = adapters
    }

    /// Adopt a single descriptor `uuid` with the latest state.
    private func update(uuid: UUID, state: EnrolmentState) {
        states[uuid] = state
    }

    /// Begin enrolment. The returned `AsyncStream` yields states as they are
    /// produced by the adapter; the service updates `states[uuid]` on every
    /// frame so the UI sees them in real time. Cancellation is exposed via
    /// `cancel(uuid:)`.
    public func enrol(intent: EnrolmentIntent) -> AsyncStream<EnrolmentState> {
        guard let adapter = adaptersByProvider[intent.descriptor.providerId] else {
            return AsyncStream { continuation in
                let s: EnrolmentState = .failed(
                    intent.descriptor,
                    error: .dependencyMissing(tool: intent.descriptor.providerId)
                )
                continuation.yield(s)
                continuation.finish()
            }
        }
        let uuid = intent.descriptor.uuid
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                let stream = adapter.enrol(intent: intent)
                for await state in stream {
                    guard !Task.isCancelled else { break }
                    if case let .identityConfirmed(descriptor, identity) = state {
                        var verified = descriptor
                        verified.verifiedIdentity = identity
                        do {
                            self?.update(uuid: uuid, state: state)
                            continuation.yield(state)
                            let pending = EnrolmentState.quotaPending(verified)
                            self?.update(uuid: uuid, state: pending)
                            continuation.yield(pending)
                            if let observed = try await self?.onVerified(verified) {
                                let ready = EnrolmentState.quotaReceived(verified, observedAt: observed)
                                self?.update(uuid: uuid, state: ready)
                                continuation.yield(ready)
                            }
                        } catch {
                            let failed = EnrolmentState.failed(verified, error: .underlying(error.localizedDescription))
                            self?.update(uuid: uuid, state: failed)
                            continuation.yield(failed)
                        }
                        break
                    }
                    self?.update(uuid: uuid, state: state)
                    continuation.yield(state)
                }
                continuation.finish()
                // Contract (review critique 2026-09-16): the task table is
                // cleaned on EVERY exit path — completion and cancellation
                // alike — so a finished enrolment never leaves an orphan task
                // slot that `cancel(uuid:)` could later cancel pointlessly.
                self?.finishTask(uuid: uuid)
            }
            self.tasks[uuid] = task
        }
    }

    /// Removes the finished/cancelled task slot for `uuid`.
    private func finishTask(uuid: UUID) {
        tasks.removeValue(forKey: uuid)
    }

    /// Reconnect an already-tracked account. Same semantics as `enrol`, but
    /// uses the adapter's reconnect flow.
    public func reconnect(account: AccountDescriptor) -> AsyncStream<EnrolmentState> {
        guard let adapter = adaptersByProvider[account.providerId] else {
            return AsyncStream { continuation in
                let s: EnrolmentState = .failed(
                    account,
                    error: .dependencyMissing(tool: account.providerId)
                )
                continuation.yield(s)
                continuation.finish()
            }
        }
        let uuid = account.uuid
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                let stream = adapter.reconnect(account: account)
                for await state in stream {
                    guard !Task.isCancelled else { break }
                    if case let .identityConfirmed(descriptor, identity) = state {
                        var verified = descriptor
                        verified.verifiedIdentity = identity
                        do {
                            self?.update(uuid: uuid, state: state)
                            continuation.yield(state)
                            let pending = EnrolmentState.quotaPending(verified)
                            self?.update(uuid: uuid, state: pending)
                            continuation.yield(pending)
                            if let observed = try await self?.onVerified(verified) {
                                let ready = EnrolmentState.quotaReceived(verified, observedAt: observed)
                                self?.update(uuid: uuid, state: ready)
                                continuation.yield(ready)
                            }
                        } catch {
                            let failed = EnrolmentState.failed(verified, error: .underlying(error.localizedDescription))
                            self?.update(uuid: uuid, state: failed)
                            continuation.yield(failed)
                        }
                        break
                    }
                    self?.update(uuid: uuid, state: state)
                    continuation.yield(state)
                }
                continuation.finish()
                self?.finishTask(uuid: uuid)
            }
            self.tasks[uuid] = task
        }
    }

    /// Cancel the in-flight enrolment for `uuid`. The adapter's poll loop
    /// sees `Task.isCancelled` and yields `.cancelled(descriptor)` at next
    /// iteration; the service clears the task slot.
    public func cancel(uuid: UUID) {
        tasks[uuid]?.cancel()
        tasks.removeValue(forKey: uuid)
    }

    /// Drop the tracked state for `uuid` (e.g. when the user closes the
    /// sheet after a successful run, the UI calls this to free memory).
    public func forget(uuid: UUID) {
        states.removeValue(forKey: uuid)
    }

    /// One-shot identity verification for an already-tracked account. Useful
    /// for the catalogue UI's Refresh button (verify before showing
    /// "Reconnexion requise").
    public func verifyIdentity(profile: ProfileReference) async -> VerifiedIdentity? {
        let providerId: String
        switch profile {
        case .codexHome: providerId = "codex"
        case .claudeConfigDir: providerId = "claude"
        default: return nil
        }
        if let claude = adaptersByProvider[providerId] {
            do {
                return try await claude.verifyIdentity(profile: profile)
            } catch {
                return nil
            }
        }
        return nil
    }
}
