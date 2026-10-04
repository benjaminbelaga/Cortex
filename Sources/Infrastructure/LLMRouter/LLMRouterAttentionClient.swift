import Domain
import Foundation

/// The single invocation path both clients below share: resolve the binary, run
/// the argv once, and never hand a failed or blank stdout to a decoder.
///
/// It is a literal copy of what `LLMRouterSnapshotClient` /
/// `LLMRouterSuggestionClient` already do, so a caller sees the same failure for
/// every router command: an unresolved binary is a launch failure, a timeout is
/// explicit, and a cancellation stays cancellable.
private enum RouterCommandInvocation {
    /// Runs one router command and returns its stdout.
    ///
    /// - Throws: `RouterQuotaIssue` when there is no binary to run, when the
    ///   runner reports a launch failure or a timeout, and when the command
    ///   produced nothing to decode; `CancellationError` when it was cancelled.
    static func run(
        _ runner: any LLMRouterCommandRunning,
        executableResolver: @Sendable () -> String?,
        arguments: [String],
        timeout: TimeInterval,
        command: String
    ) async throws -> Data {
        // Identical to the sibling clients (behaviour, not just wording): an
        // unresolved binary is a launch failure, never an empty answer.
        guard let executable = executableResolver() else {
            throw RouterQuotaIssue("llm-router executable was not found")
        }

        let data: Data
        do {
            data = try await runner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        } catch let error as ProcessRunError {
            // Reachable for any runner that surfaces a raw `ProcessRunError` (the
            // test double, a future transport). The production
            // `LLMRouterProcessRunner` already maps `ProcessRunError` to a
            // `RouterQuotaIssue` (and, since it now derives the subcommand from
            // argv, names the real command). This mapping repeats the contract
            // with the command this client actually used, so a timeout or launch
            // failure can never be mistaken for an answer — keep it.
            throw mapped(error, command: command)
        }

        // An empty or whitespace-only stdout is NOT an empty result: it is a
        // command that said nothing. Decoding it would invent an empty feed (or
        // an empty mission) out of a failed read.
        guard !isBlank(data) else {
            throw RouterQuotaIssue("llm-router \(command) returned no output")
        }
        return data
    }

    /// `ProcessRunError` → the failures its own runner raises, and a
    /// cancellation that stays a `CancellationError`.
    private static func mapped(_ error: ProcessRunError, command: String) -> Error {
        switch error {
        case let .launchFailed(message):
            return RouterQuotaIssue("llm-router \(command) could not launch: \(message)")
        case let .timedOut(after, tail):
            let suffix = tail.isEmpty ? "" : ": \(tail)"
            return RouterQuotaIssue("llm-router \(command) timed out after \(Int(after))s\(suffix)")
        case .cancelled:
            return CancellationError()
        }
    }

    private static func isBlank(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

/// Read-only client for `llm-router attention --json` — the « À traiter » feed of
/// the Cortex plan (Lot 4).
///
/// The router already knows which of its own decisions are unfinished: a launch
/// that diverged from its recommendation, an account to reconnect, a result to
/// validate, a receipt still awaited. This client exists so Cortex can *show*
/// that queue instead of each surface re-deriving it from quotas. It only reads:
/// no severity, kind or reason is invented here, an item the router sent is
/// always surfaced (even when Cortex does not model its `kind` yet), and a read
/// that failed is a thrown error — never a reassuring empty feed.
///
/// The same list is also embedded by `llm-router status --format json-v2
/// --with-attention`, in the snapshot envelope, as `envelope.attention` (with
/// `envelope.attention_count`). That is the cheap path: a caller that is already
/// paying for one status subprocess gets the feed for free and must not spawn a
/// second `attention` process. This client is for the paths that have no
/// snapshot at hand and for an explicit refresh of the feed; when the snapshot
/// path grows attention support, both seams must yield the same items. (That
/// seam is documented here, deliberately not implemented in this file.)
public struct LLMRouterAttentionClient: Sendable {
    public typealias ExecutableResolver = @Sendable () -> String?

    private let runner: any LLMRouterCommandRunning
    private let executableResolver: ExecutableResolver
    private let timeout: TimeInterval

    public init(
        runner: any LLMRouterCommandRunning = LLMRouterProcessRunner(),
        executableResolver: @escaping ExecutableResolver = LLMRouterSnapshotClient.resolveExecutable,
        timeout: TimeInterval = 15
    ) {
        self.runner = runner
        self.executableResolver = executableResolver
        self.timeout = timeout
    }

    /// Runs `llm-router attention --json` and decodes the « À traiter » feed.
    ///
    /// - Throws: `RouterQuotaIssue` for a missing binary, a non-zero exit, a
    ///   timeout, a truncated read, a blank stdout or an undecodable payload.
    public func attention() async throws -> RouterAttentionFeed {
        let data = try await RouterCommandInvocation.run(
            runner,
            executableResolver: executableResolver,
            arguments: ["attention", "--json"],
            timeout: timeout,
            command: "attention"
        )
        return try Self.parse(data)
    }

    /// Pure decode of an `attention --json` payload — no runner, no I/O.
    ///
    /// An exotic field never fails the whole read: the domain model stays total
    /// so an item the router added is displayed rather than dropped.
    public static func parse(_ data: Data) throws -> RouterAttentionFeed {
        do {
            return try RouterAttentionFeed.parse(data)
        } catch {
            throw RouterQuotaIssue("Invalid llm-router attention JSON: \(error.localizedDescription)")
        }
    }
}

/// Read-only client for `llm-router mission inspect <id>` — the mission
/// inspector of the Cortex plan (Lot 4).
///
/// A mission has three distinct stages — recommandé → exécuté → vérifié — and
/// the router is the only authority on them: a recommendation is not an
/// execution, and a process that exited 0 is not a validated result. This client
/// exists so the inspector can display that chain exactly as the router reports
/// it (including its gaps: no recommendation, no receipt, no evaluation). It
/// never infers a missing stage and never upgrades an unknown into a success.
///
/// An unknown mission is an error, not an empty inspection: the router exits
/// non-zero for it, so the read throws instead of rendering a mission with every
/// field blanked — which would look like a real, empty mission.
public struct LLMRouterMissionInspector: Sendable {
    public typealias ExecutableResolver = @Sendable () -> String?

    private let runner: any LLMRouterCommandRunning
    private let executableResolver: ExecutableResolver
    private let timeout: TimeInterval

    public init(
        runner: any LLMRouterCommandRunning = LLMRouterProcessRunner(),
        executableResolver: @escaping ExecutableResolver = LLMRouterSnapshotClient.resolveExecutable,
        timeout: TimeInterval = 15
    ) {
        self.runner = runner
        self.executableResolver = executableResolver
        self.timeout = timeout
    }

    /// Runs `llm-router mission inspect <id>` and decodes the mission chain.
    ///
    /// - Throws: `RouterQuotaIssue` for an empty id, a missing binary, a
    ///   non-zero exit (the router's answer for an unknown mission), a timeout,
    ///   a blank stdout or an undecodable payload.
    public func inspect(missionId: String) async throws -> MissionInspection {
        let trimmed = missionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RouterQuotaIssue("A mission id is required to inspect a mission")
        }
        let data = try await RouterCommandInvocation.run(
            runner,
            executableResolver: executableResolver,
            arguments: ["mission", "inspect", trimmed],
            timeout: timeout,
            command: "mission inspect"
        )
        return try Self.parse(data)
    }

    /// Pure decode of a `mission inspect` payload — no runner, no I/O.
    ///
    /// Every stage is optional in the router's contract: an absent
    /// `recommended`, `result` or `metrics` block is an honest gap, so the
    /// decode stays total instead of failing the whole inspection.
    public static func parse(_ data: Data) throws -> MissionInspection {
        do {
            return try MissionInspection.parse(data)
        } catch {
            throw RouterQuotaIssue("Invalid llm-router mission JSON: \(error.localizedDescription)")
        }
    }
}
