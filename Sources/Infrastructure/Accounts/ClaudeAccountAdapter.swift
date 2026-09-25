import Foundation
import Domain

/// Enrolment adapter for Claude Code accounts keyed by an isolated
/// `CLAUDE_CONFIG_DIR`. One adapter instance handles every Claude account;
/// the per-account identity lives in `EnrolmentIntent.descriptor.profile`.
///
/// The state machine is documented per-`case` in `Sources/Domain/Provider/
/// Account/AccountEnrolment.swift`. The short version:
///   profileDetected → authRequired → loginInProgress → identityConfirmed → quotaPending → quotaReceived
///   ... with `.failed(...)` / `.cancelled(...)` as terminal alternatives.
///
/// Race discipline: the user can cancel at any time. Cancellation propagates
/// through `Task.isCancelled` checked inside the poll loop AND at every state
/// yield. The terminal yield closes the stream; consumers see `cancelled(descriptor)`.
public struct ClaudeAccountAdapter: AccountAdapter, Sendable {
    public let providerId = "claude"
    public let capabilities: AccountCapabilities = [
        .discover, .add, .reconnect, .readQuota,
    ]

    public let authStatusProbe: any ClaudeAuthStatusProbing
    public let terminalLauncher: any TerminalLoginLaunching
    public let profileCollisionDetector: @Sendable (String) -> Bool
    public let pollInterval: Duration
    public let pollTimeout: TimeInterval
    public let now: @Sendable () -> Date

    public init(
        authStatusProbe: any ClaudeAuthStatusProbing,
        terminalLauncher: any TerminalLoginLaunching,
        profileCollisionDetector: @escaping @Sendable (String) -> Bool = { _ in false },
        pollInterval: Duration = .seconds(2),
        pollTimeout: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStatusProbe = authStatusProbe
        self.terminalLauncher = terminalLauncher
        self.profileCollisionDetector = profileCollisionDetector
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.now = now
    }

    // MARK: - AccountAdapter

    public func enrol(intent: EnrolmentIntent) -> AsyncStream<EnrolmentState> {
        let probe = authStatusProbe
        let launcher = terminalLauncher
        let collision = profileCollisionDetector
        let interval = pollInterval
        let timeout = pollTimeout
        let clock = now
        return AsyncStream { continuation in
            let task = Task {
                await Self.runEnrolment(
                    intent: intent,
                    probe: probe,
                    launcher: launcher,
                    collisionDetector: collision,
                    pollInterval: interval,
                    pollTimeout: timeout,
                    clock: clock,
                    continuation: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func reconnect(account: AccountDescriptor) -> AsyncStream<EnrolmentState> {
        let probe = authStatusProbe
        let launcher = terminalLauncher
        let collision = profileCollisionDetector
        let interval = pollInterval
        let timeout = pollTimeout
        let clock = now
        let intent = EnrolmentIntent(
            descriptor: account,
            expectedIdentityEmail: account.verifiedIdentity?.email,
            targetSource: account.source
        )
        return AsyncStream { continuation in
            let task = Task {
                await Self.runReconnect(
                    account: account,
                    intent: intent,
                    probe: probe,
                    launcher: launcher,
                    collisionDetector: collision,
                    pollInterval: interval,
                    pollTimeout: timeout,
                    clock: clock,
                    continuation: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func verifyIdentity(profile: ProfileReference) async throws -> VerifiedIdentity? {
        guard case let .claudeConfigDir(path) = profile else { return nil }
        guard let status = await authStatusProbe.authStatus(configDirectory: path) else {
            return nil
        }
        return status.verifiedIdentity(at: now())
    }

    // MARK: - Runners (static, dependency-injected for testability)

    private static func runEnrolment(
        intent: EnrolmentIntent,
        probe: any ClaudeAuthStatusProbing,
        launcher: any TerminalLoginLaunching,
        collisionDetector: @Sendable (String) -> Bool,
        pollInterval: Duration,
        pollTimeout: TimeInterval,
        clock: @escaping @Sendable () -> Date,
        continuation: AsyncStream<EnrolmentState>.Continuation
    ) async {
        let descriptor = intent.descriptor
        let profilePath = descriptor.profile.localPath ?? ""

        // Pre-flight — both errors emit a single terminal `.failed` and return.
        if profilePath.isEmpty {
            continuation.yield(.failed(descriptor, error: .dependencyMissing(tool: "claude")))
            return
        }
        if collisionDetector(profilePath) {
            continuation.yield(
                .failed(descriptor, error: .profileCollision(path: profilePath))
            )
            return
        }

        continuation.yield(.profileDetected(descriptor))

        // Pre-check: account may already be authenticated — fast path.
        if let initial = await probe.authStatus(configDirectory: profilePath),
           let identity = initial.verifiedIdentity(at: clock())
        {
            if yieldMismatchIfPresent(
                intent: intent,
                identity: identity,
                descriptor: descriptor,
                continuation: continuation
            ) {
                return
            }
            yieldIdentity(
                intent: intent,
                identity: identity,
                descriptor: descriptor,
                continuation: continuation
            )
            return
        }

        // Otherwise: open terminal + poll until identity or timeout/cancel.
        continuation.yield(.authRequired(descriptor, reason: .neverAuthenticated))
        continuation.yield(.loginInProgress(descriptor, stage: .launching))
        guard await launcher.launchLoginShell(profile: profilePath) else {
            continuation.yield(.failed(descriptor, error: .underlying("Could not open the connection terminal.")))
            return
        }
        continuation.yield(.loginInProgress(descriptor, stage: .waitingForUser))

        await pollForIdentity(
            intent: intent,
            probe: probe,
            profilePath: profilePath,
            pollInterval: pollInterval,
            pollTimeout: pollTimeout,
            clock: clock,
            continuation: continuation
        )
    }

    private static func runReconnect(
        account: AccountDescriptor,
        intent: EnrolmentIntent,
        probe: any ClaudeAuthStatusProbing,
        launcher: any TerminalLoginLaunching,
        collisionDetector: @Sendable (String) -> Bool,
        pollInterval: Duration,
        pollTimeout: TimeInterval,
        clock: @escaping @Sendable () -> Date,
        continuation: AsyncStream<EnrolmentState>.Continuation
    ) async {
        let profilePath = account.profile.localPath ?? ""
        if profilePath.isEmpty || collisionDetector(profilePath) {
            continuation.yield(
                .failed(account, error: .dependencyMissing(tool: "claude"))
            )
            return
        }

        continuation.yield(.authRequired(account, reason: .explicitReconnect))
        continuation.yield(.loginInProgress(account, stage: .launching))
        guard await launcher.launchReconnectShell(profile: profilePath) else {
            continuation.yield(.failed(account, error: .underlying("Could not open the connection terminal.")))
            return
        }
        continuation.yield(.loginInProgress(account, stage: .waitingForUser))

        await pollForIdentity(
            intent: intent,
            probe: probe,
            profilePath: profilePath,
            pollInterval: pollInterval,
            pollTimeout: pollTimeout,
            clock: clock,
            continuation: continuation
        )
    }

    private static func pollForIdentity(
        intent: EnrolmentIntent,
        probe: any ClaudeAuthStatusProbing,
        profilePath: String,
        pollInterval: Duration,
        pollTimeout: TimeInterval,
        clock: @escaping @Sendable () -> Date,
        continuation: AsyncStream<EnrolmentState>.Continuation
    ) async {
        let descriptor = intent.descriptor
        let deadline = clock().addingTimeInterval(pollTimeout)
        var emittedPolling = false

        while !Task.isCancelled {
            if clock() >= deadline {
                continuation.yield(
                    .failed(descriptor, error: .timeout(afterSeconds: pollTimeout))
                )
                return
            }

            if !emittedPolling {
                continuation.yield(.loginInProgress(descriptor, stage: .pollingIdentity))
                emittedPolling = true
            }

            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // Cancellation surfaces here
                continuation.yield(.cancelled(descriptor))
                return
            }

            if Task.isCancelled {
                continuation.yield(.cancelled(descriptor))
                return
            }

            guard let status = await probe.authStatus(configDirectory: profilePath) else {
                continue
            }
            guard status.loggedIn else { continue }
            guard let identity = status.verifiedIdentity(at: clock()) else {
                continue
            }

            // Mismatch check
            if yieldMismatchIfPresent(
                intent: intent,
                identity: identity,
                descriptor: descriptor,
                continuation: continuation
            ) {
                return
            }

            yieldIdentity(
                intent: intent,
                identity: identity,
                descriptor: descriptor,
                continuation: continuation
            )
            return
        }
        // Loop exited without yielding — cancelled downstream
        continuation.yield(.cancelled(descriptor))
    }

    private static func yieldIdentity(
        intent: EnrolmentIntent,
        identity: VerifiedIdentity,
        descriptor: AccountDescriptor,
        continuation: AsyncStream<EnrolmentState>.Continuation
    ) {
        continuation.yield(.identityConfirmed(descriptor, identity: identity))
        // The registrar (mode router) or the ClaudeProvider (mode autonomous) is
        // responsible for the first quota refresh that moves us out of
        // `.quotaPending`; the adapter only knows "identity proven". The service
        // layer consumes the stream and decides to flip to quotaReceived once the
        // matching provider's first snapshot lands.
        continuation.yield(.quotaPending(descriptor))
    }

    /// Returns `true` when the identity contradicts the intent's expected
    /// email and the caller should stop right after the yielded `.failed`.
    /// Caller-supplied expectation is lowered to compare; empty/nil means
    /// "no expectation" and the check is a no-op.
    private static func yieldMismatchIfPresent(
        intent: EnrolmentIntent,
        identity: VerifiedIdentity,
        descriptor: AccountDescriptor,
        continuation: AsyncStream<EnrolmentState>.Continuation
    ) -> Bool {
        guard let expectedRaw = intent.expectedIdentityEmail?.lowercased(),
              !expectedRaw.isEmpty else {
            return false
        }
        if identity.email.lowercased() == expectedRaw { return false }
        continuation.yield(
            .failed(
                descriptor,
                error: .identityMismatch(
                    expected: intent.expectedIdentityEmail,
                    actual: identity.email
                )
            )
        )
        return true
    }
}
