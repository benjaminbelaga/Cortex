import Foundation
import Domain

/// Enrolment adapter for Alibaba/Bailian accounts, keyed by a `bl` config
/// profile (`~/.bailian/config.json` top-level key). Unlike Claude/Codex there
/// is no isolated directory: the profile is a NAME, and identity is the
/// workspace principal read back from `bl auth status --output json`.
///
/// The state machine mirrors `CodexAccountAdapter` exactly
/// (`profileDetected → authRequired → loginInProgress → identityConfirmed →
/// quotaPending`, with `.failed`/`.cancelled` terminal), so the enrolment
/// service and every row's "Connecter" button treat it uniformly through the
/// `AccountAdapter` protocol. The one asymmetry: the interactive login is
/// `bl auth login --console` (browser) rather than a token paste.
public struct AlibabaAccountAdapter: AccountAdapter, Sendable {
    public let providerId = "qwen"
    public let capabilities: AccountCapabilities = [
        .add, .reconnect, .readQuota,
    ]

    public let authStatusProbe: any AlibabaAuthStatusProbing
    public let terminalLauncher: any AlibabaTerminalLoginLaunching
    /// Console site the login is scoped to. `international` is the site the
    /// existing `QwenPlanUsageProbe` and the documented rail already use; a
    /// China-mainland workspace is configured by changing this at the seams.
    public let consoleSite: String
    public let pollInterval: Duration
    public let pollTimeout: TimeInterval
    public let now: @Sendable () -> Date

    public init(
        authStatusProbe: any AlibabaAuthStatusProbing,
        terminalLauncher: any AlibabaTerminalLoginLaunching,
        consoleSite: String = "international",
        pollInterval: Duration = .seconds(2),
        pollTimeout: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStatusProbe = authStatusProbe
        self.terminalLauncher = terminalLauncher
        self.consoleSite = consoleSite
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.now = now
    }

    // MARK: - AccountAdapter

    public func enrol(intent: EnrolmentIntent) -> AsyncStream<EnrolmentState> {
        let probe = authStatusProbe
        let launcher = terminalLauncher
        let site = consoleSite
        let interval = pollInterval
        let timeout = pollTimeout
        let clock = now
        return AsyncStream { continuation in
            let task = Task {
                await Self.runLogin(
                    intent: intent,
                    probe: probe,
                    launcher: launcher,
                    site: site,
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
        let site = consoleSite
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
                await Self.runLogin(
                    intent: intent,
                    probe: probe,
                    launcher: launcher,
                    site: site,
                    pollInterval: interval,
                    pollTimeout: timeout,
                    clock: clock,
                    continuation: continuation,
                    isReconnect: true
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func verifyIdentity(profile: ProfileReference) async throws -> VerifiedIdentity? {
        guard case let .bailianProfile(name) = profile else { return nil }
        guard let status = await authStatusProbe.authStatus(profile: name) else { return nil }
        return status.verifiedIdentity(at: now())
    }

    // MARK: - Runner (static, dependency-injected for testability)

    private static func runLogin(
        intent: EnrolmentIntent,
        probe: any AlibabaAuthStatusProbing,
        launcher: any AlibabaTerminalLoginLaunching,
        site: String,
        pollInterval: Duration,
        pollTimeout: TimeInterval,
        clock: @escaping @Sendable () -> Date,
        continuation: AsyncStream<EnrolmentState>.Continuation,
        isReconnect: Bool = false
    ) async {
        let descriptor = intent.descriptor
        guard let profile = descriptor.profile.bailianProfileName, !profile.isEmpty else {
            continuation.yield(.failed(descriptor, error: .dependencyMissing(tool: "bl")))
            return
        }

        if isReconnect {
            continuation.yield(.authRequired(descriptor, reason: .explicitReconnect))
        } else {
            continuation.yield(.profileDetected(descriptor))

            // Fast pre-check: an already-authenticated profile skips the terminal.
            if let initial = await probe.authStatus(profile: profile),
               let identity = initial.verifiedIdentity(at: clock()) {
                if yieldMismatchIfPresent(
                    intent: intent, identity: identity,
                    descriptor: descriptor, continuation: continuation
                ) { return }
                yieldIdentity(descriptor: descriptor, identity: identity, continuation: continuation)
                return
            }
            continuation.yield(.authRequired(descriptor, reason: .neverAuthenticated))
        }

        continuation.yield(.loginInProgress(descriptor, stage: .launching))
        if isReconnect {
            _ = await launcher.launchReconnectShell(profile: profile, site: site)
        } else {
            _ = await launcher.launchLoginShell(profile: profile, site: site)
        }
        continuation.yield(.loginInProgress(descriptor, stage: .waitingForUser))

        await pollForIdentity(
            intent: intent,
            probe: probe,
            profile: profile,
            pollInterval: pollInterval,
            pollTimeout: pollTimeout,
            clock: clock,
            continuation: continuation
        )
    }

    private static func pollForIdentity(
        intent: EnrolmentIntent,
        probe: any AlibabaAuthStatusProbing,
        profile: String,
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
                continuation.yield(.failed(descriptor, error: .timeout(afterSeconds: pollTimeout)))
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

            guard let status = await probe.authStatus(profile: profile) else { continue }
            guard let identity = status.verifiedIdentity(at: clock()) else { continue }

            if yieldMismatchIfPresent(
                intent: intent, identity: identity,
                descriptor: descriptor, continuation: continuation
            ) { return }
            yieldIdentity(descriptor: descriptor, identity: identity, continuation: continuation)
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
              !expectedRaw.isEmpty else { return false }
        if identity.email.lowercased() == expectedRaw { return false }
        continuation.yield(.failed(descriptor, error: .identityMismatch(
            expected: intent.expectedIdentityEmail, actual: identity.email
        )))
        return true
    }
}
