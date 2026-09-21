import Foundation
import Domain

/// Enrolment adapter for Codex accounts keyed by an isolated `CODEX_HOME`. The
/// adapter mirrors `ClaudeAccountAdapter`'s shape and state machine, with the
/// profile-side path going through `ProfileReference.codexHome(...)` instead
/// of `claudeConfigDir(...)` and the email-conflict check running on Codex-
/// emitted JSON.
///
/// The probe protocol differs (`CodexAuthStatusProbing` vs `ClaudeAuthStatusProbing`)
/// because the wire format is different — but the consumer-visible state set
/// stays identical (`EnrolmentState`), so the enrolment service treats the
/// two adapters uniformly via `AccountAdapter`.
public struct CodexAccountAdapter: AccountAdapter, Sendable {
    public let providerId = "codex"
    public let capabilities: AccountCapabilities = [
        .discover, .add, .reconnect, .readQuota,
    ]

    public let authStatusProbe: any CodexAuthStatusProbing
    public let terminalLauncher: any CodexTerminalLoginLaunching
    public let profileCollisionDetector: @Sendable (String) -> Bool
    public let pollInterval: Duration
    public let pollTimeout: TimeInterval
    public let now: @Sendable () -> Date

    public init(
        authStatusProbe: any CodexAuthStatusProbing,
        terminalLauncher: any CodexTerminalLoginLaunching,
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
        guard case let .codexHome(path) = profile else { return nil }
        guard let status = await authStatusProbe.authStatus(codexHome: path) else {
            return nil
        }
        return status.verifiedIdentity(at: now())
    }

    // MARK: - Runners (static, dependency-injected for testability)

    private static func runEnrolment(
        intent: EnrolmentIntent,
        probe: any CodexAuthStatusProbing,
        launcher: any CodexTerminalLoginLaunching,
        collisionDetector: @Sendable (String) -> Bool,
        pollInterval: Duration,
        pollTimeout: TimeInterval,
        clock: @escaping @Sendable () -> Date,
        continuation: AsyncStream<EnrolmentState>.Continuation
    ) async {
        let descriptor = intent.descriptor
        let homePath = descriptor.profile.localPath ?? ""

        if homePath.isEmpty {
            continuation.yield(.failed(descriptor, error: .dependencyMissing(tool: "codex")))
            return
        }
        if collisionDetector(homePath) {
            continuation.yield(
                .failed(descriptor, error: .profileCollision(path: homePath))
            )
            return
        }

        continuation.yield(.profileDetected(descriptor))

        // Pre-check fast path
        if let initial = await probe.authStatus(codexHome: homePath),
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
                descriptor: descriptor,
                identity: identity,
                continuation: continuation
            )
            return
        }

        // Slow path
        continuation.yield(.authRequired(descriptor, reason: .neverAuthenticated))
        continuation.yield(.loginInProgress(descriptor, stage: .launching))
        _ = await launcher.launchLoginShell(codexHome: homePath)
        continuation.yield(.loginInProgress(descriptor, stage: .waitingForUser))

        await pollForIdentity(
            intent: intent,
            probe: probe,
            homePath: homePath,
            pollInterval: pollInterval,
            pollTimeout: pollTimeout,
            clock: clock,
            continuation: continuation
        )
    }

    private static func runReconnect(
        account: AccountDescriptor,
        intent: EnrolmentIntent,
        probe: any CodexAuthStatusProbing,
        launcher: any CodexTerminalLoginLaunching,
        collisionDetector: @Sendable (String) -> Bool,
        pollInterval: Duration,
        pollTimeout: TimeInterval,
        clock: @escaping @Sendable () -> Date,
        continuation: AsyncStream<EnrolmentState>.Continuation
    ) async {
        let homePath = account.profile.localPath ?? ""
        if homePath.isEmpty || collisionDetector(homePath) {
            continuation.yield(
                .failed(account, error: .dependencyMissing(tool: "codex"))
            )
            return
        }

        continuation.yield(.authRequired(account, reason: .explicitReconnect))
        continuation.yield(.loginInProgress(account, stage: .launching))
        _ = await launcher.launchReconnectShell(codexHome: homePath)
        continuation.yield(.loginInProgress(account, stage: .waitingForUser))

        await pollForIdentity(
            intent: intent,
            probe: probe,
            homePath: homePath,
            pollInterval: pollInterval,
            pollTimeout: pollTimeout,
            clock: clock,
            continuation: continuation
        )
    }

    private static func pollForIdentity(
        intent: EnrolmentIntent,
        probe: any CodexAuthStatusProbing,
        homePath: String,
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
                continuation.yield(.cancelled(descriptor))
                return
            }

            if Task.isCancelled {
                continuation.yield(.cancelled(descriptor))
                return
            }

            guard let status = await probe.authStatus(codexHome: homePath) else {
                continue
            }
            guard status.loggedIn else { continue }
            guard let identity = status.verifiedIdentity(at: clock()) else {
                continue
            }

            if yieldMismatchIfPresent(
                intent: intent,
                identity: identity,
                descriptor: descriptor,
                continuation: continuation
            ) {
                return
            }

            yieldIdentity(
                descriptor: descriptor,
                identity: identity,
                continuation: continuation
            )
            return
        }
        continuation.yield(.cancelled(descriptor))
    }

    private static func yieldIdentity(
        descriptor: AccountDescriptor,
        identity: VerifiedIdentity,
        continuation: AsyncStream<EnrolmentState>.Continuation
    ) {
        continuation.yield(.identityConfirmed(descriptor, identity: identity))
        continuation.yield(.quotaPending(descriptor))
    }

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
