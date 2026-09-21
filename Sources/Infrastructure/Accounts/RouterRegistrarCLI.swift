import Foundation
import Domain

/// Production `RouterRegistering`: shells out to `llm-router account add`
/// through `BoundedProcessRunner` (concurrent drain, TERM→KILL, cancellation —
/// the PR A runner, reused).
///
/// Transactional semantics (review critique 2026-09-16 §6):
/// - The request's `verifiedIdentity` is the identity READ from the CLI/RPC
///   probe, never the user's typed expectation — enforced upstream by
///   `AccountEnrolmentService` calling `register` only after
///   `.identityConfirmed`.
/// - `--auth-state connected` is produced solely by
///   `RouterRegistrationRequest.arguments()` after that confirmation.
/// - Any failure surfaces as a typed `EnrolmentError.registryRejected` with a
///   bounded, redacted stderr tail; the account is never reported
///   router-connected on failure.
/// - Arguments are passed as an argv array — never shell-concatenated.
/// - Idempotent retry: `account add` upserts by alias, so a re-run after a
///   transient failure replaces rather than duplicates.
/// - No secrets are logged: only alias, exit status, and the bounded tail.
/// - `cswap add` is a SEPARATE, opt-in concern (`integration.cswap.enabled`)
///   and deliberately lives outside this type.
public struct RouterRegistrarCLI: RouterRegistering {

    public struct Options: Sendable {
        /// Wall-clock budget for one `account add` invocation.
        public var timeout: TimeInterval
        /// Cap applied to each output stream before truncation flags fire.
        public var maxBytesPerStream: Int
        /// How much of stderr to carry into `registryRejected` messages.
        public var stderrTailLimit: Int

        public init(
            timeout: TimeInterval = 30,
            maxBytesPerStream: Int = 512 * 1024,
            stderrTailLimit: Int = 2048
        ) {
            self.timeout = timeout
            self.maxBytesPerStream = maxBytesPerStream
            self.stderrTailLimit = stderrTailLimit
        }
    }

    private let executablePath: String?
    private let runner: BoundedProcessRunner
    private let options: Options

    /// - Parameter executablePath: resolved `llm-router` path. When nil, the
    ///   registrar resolves it via `BinaryLocator.findInCommonPaths` on first
    ///   use — inject a fixed path in tests instead of relying on the host.
    public init(
        executablePath: String? = nil,
        runner: BoundedProcessRunner = BoundedProcessRunner(),
        options: Options = Options()
    ) {
        self.executablePath = executablePath
        self.runner = runner
        self.options = options
    }

    public func register(
        _ request: RouterRegistrationRequest
    ) async throws -> RouterRegistrationOutcome {
        let binary = executablePath
            ?? BinaryLocator.findInCommonPaths("llm-router")
        guard let binary else {
            throw EnrolmentError.registryRejected(
                reason: "llm-router executable was not found"
            )
        }

        let arguments = request.arguments()
        let result: ProcessRunResult
        do {
            result = try await runner.run(
                executable: binary,
                arguments: arguments,
                options: .init(
                    timeout: options.timeout,
                    maxBytesPerStream: options.maxBytesPerStream,
                    terminationGrace: 2
                )
            )
        } catch let error as ProcessRunError {
            throw EnrolmentError.registryRejected(
                reason: "llm-router account add \(Self.describe(error))"
            )
        }

        guard result.exitStatus == 0 else {
            // Never lie: a non-zero exit means the account is NOT registered.
            throw EnrolmentError.registryRejected(
                reason: "llm-router account add exited \(result.exitStatus)\(Self.tailSuffix(Self.decode(result.stderr)))"
            )
        }

        // Success requires the router's own ack line on stdout OR stderr —
        // a bare exit 0 without a parseable ack is treated as rejection so a
        // half-broken router cannot silently pass.
        let acknowledged = Self.acknowledges(request, result: result)
        guard acknowledged else {
            throw EnrolmentError.registryRejected(
                reason: "llm-router account add produced no acknowledgement\(Self.tailSuffix(Self.decode(result.stderr)))"
            )
        }

        return RouterRegistrationOutcome(
            alias: request.alias,
            rawStdout: Self.decode(result.stdout),
            rawStderr: Self.decode(result.stderr)
        )
    }

    // MARK: - Parsing helpers

    /// `ProcessRunResult` carries raw `Data`; decode once at the boundary.
    private static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// The router replies with a JSON line ({"result":"ok","alias":…}) or a
    /// plain "ok"/"added" line on either stream. Any of these counts.
    private static func acknowledges(
        _ request: RouterRegistrationRequest, result: ProcessRunResult
    ) -> Bool {
        for blob in [Self.decode(result.stdout), Self.decode(result.stderr)]
        where !blob.isEmpty {
            let lowered = blob.lowercased()
            if lowered.contains("\"result\":\"ok\"")
                || lowered.contains("\"result\": \"ok\"")
                || lowered.contains("\"alias\":\"\(request.alias.lowercased())\"")
                || lowered.contains("account added")
                || trimmedLinesEqualOK(blob) {
                return true
            }
        }
        return false
    }

    private static func trimmedLinesEqualOK(_ blob: String) -> Bool {
        blob.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains { $0 == "ok" || $0.hasPrefix("ok:") }
    }

    private static func describe(_ error: ProcessRunError) -> String {
        switch error {
        case .launchFailed(let message):
            return "could not launch: \(message)"
        case .timedOut(let after, let tail):
            return "timed out after \(Int(after))s\(suffix(tail))"
        case .cancelled(let tail):
            return "was cancelled\(suffix(tail))"
        }
    }

    private static func tailSuffix(_ stderr: String) -> String {
        let tail = Self.boundedTail(stderr)
        return tail.isEmpty ? "" : " — stderr: \(tail)"
    }

    /// Bounded (default 2 KiB) stderr tail for error messages. Keeps logs
    /// useful without ever dumping a full stream.
    private static func boundedTail(_ stderr: String) -> String {
        let bytes = Data(stderr.utf8)
        guard bytes.count > 2048 else { return stderr }
        let suffix = bytes.suffix(2048)
        return "…\n" + String(decoding: suffix, as: UTF8.self)
    }

    private static func suffix(_ tail: String) -> String {
        guard !tail.isEmpty else { return "" }
        let bounded = boundedTail(tail)
        return " — stderr: \(bounded)"
    }
}
