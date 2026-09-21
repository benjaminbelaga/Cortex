import Foundation

/// Outcome of a process that ran to completion (any exit status).
public struct ProcessRunResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitStatus: Int32
    /// True when stdout exceeded the byte cap and was truncated.
    public let stdoutTruncated: Bool
    /// True when stderr exceeded the byte cap and was truncated.
    public let stderrTruncated: Bool

    public init(
        stdout: Data,
        stderr: Data,
        exitStatus: Int32,
        stdoutTruncated: Bool,
        stderrTruncated: Bool
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    /// The last `maxBytes` UTF-8 bytes of stderr, for attaching to an error.
    public func stderrTail(maxBytes: Int = 2048) -> String {
        let slice = stderr.count > maxBytes ? stderr.suffix(maxBytes) : stderr
        return String(decoding: slice, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Failure to run a process to completion. A non-zero exit is NOT an error here:
/// it is reported through `ProcessRunResult.exitStatus` so the caller decides.
public enum ProcessRunError: Error, Sendable {
    case launchFailed(String)
    case timedOut(after: TimeInterval, stderrTail: String)
    case cancelled(stderrTail: String)
}

/// Runs a subprocess while draining stdout AND stderr concurrently from the
/// moment it launches, so a child emitting more than a pipe buffer (~64 KiB)
/// can never block on a full pipe and produce a false timeout. Output is capped
/// (excess dropped with a truncation flag, drain continues), the deadline
/// escalates TERM → grace → SIGKILL, Task cancellation is honored the same way,
/// and the child is always reaped.
public final class BoundedProcessRunner: @unchecked Sendable {
    public struct Options: Sendable {
        public var timeout: TimeInterval
        public var maxBytesPerStream: Int
        public var terminationGrace: TimeInterval

        public init(
            timeout: TimeInterval = 60,
            maxBytesPerStream: Int = 8 * 1024 * 1024,
            terminationGrace: TimeInterval = 2
        ) {
            self.timeout = timeout
            self.maxBytesPerStream = maxBytesPerStream
            self.terminationGrace = terminationGrace
        }
    }

    public init() {}

    /// Drives one process to completion (or failure). `environment` replaces the
    /// child's environment when non-nil; otherwise it inherits the parent's.
    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        options: Options = Options()
    ) async throws -> ProcessRunResult {
        let state = RunState(cap: options.maxBytesPerStream)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Attach drains BEFORE launch so no early bytes are missed.
        install(handler: stdoutPipe.fileHandleForReading, stream: .stdout, state: state)
        install(handler: stderrPipe.fileHandleForReading, stream: .stderr, state: state)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessRunResult, Error>) in
                state.attach(continuation: continuation, process: process, grace: options.terminationGrace)

                process.terminationHandler = { [weak state] _ in
                    state?.handleTermination()
                }
                do {
                    try process.run()
                } catch {
                    state.finishLaunchFailure(error.localizedDescription)
                    return
                }

                // Deadline: escalate on the shared queue.
                state.queue.asyncAfter(deadline: .now() + options.timeout) { [weak state] in
                    state?.markTimedOut(after: options.timeout)
                }
            }
        } onCancel: {
            state.markCancelled()
        }
    }

    private enum StreamID { case stdout, stderr }

    private func install(handler fileHandle: FileHandle, stream: StreamID, state: RunState) {
        fileHandle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                state.markStreamClosed(stream == .stdout)
            } else {
                state.append(chunk, isStdout: stream == .stdout)
            }
        }
    }

    /// All mutable run state guarded by one lock; the escalation timer and the
    /// two readability handlers race onto it, so every access takes the lock and
    /// the continuation is resumed at most once.
    private final class RunState: @unchecked Sendable {
        let queue = DispatchQueue(label: "cortex.bounded-process-runner")
        private let lock = NSLock()
        private let cap: Int

        private var stdoutData = Data()
        private var stderrData = Data()
        private var stdoutTruncated = false
        private var stderrTruncated = false
        private var stdoutClosed = false
        private var stderrClosed = false

        private var continuation: CheckedContinuation<ProcessRunResult, Error>?
        private var process: Process?
        private var grace: TimeInterval = 2
        private var resumed = false
        private var timedOut = false
        private var cancelled = false
        private var timeoutSeconds: TimeInterval = 0

        init(cap: Int) { self.cap = cap }

        func attach(
            continuation: CheckedContinuation<ProcessRunResult, Error>,
            process: Process,
            grace: TimeInterval
        ) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
            self.process = process
            self.grace = grace
        }

        func append(_ chunk: Data, isStdout: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isStdout {
                let room = cap - stdoutData.count
                if room > 0 { stdoutData.append(chunk.prefix(room)) }
                if chunk.count > room { stdoutTruncated = true }
            } else {
                let room = cap - stderrData.count
                if room > 0 { stderrData.append(chunk.prefix(room)) }
                if chunk.count > room { stderrTruncated = true }
            }
        }

        func markStreamClosed(_ isStdout: Bool) {
            lock.lock()
            if isStdout { stdoutClosed = true } else { stderrClosed = true }
            let done = stdoutClosed && stderrClosed
            lock.unlock()
            if done { resolve() }
        }

        /// The direct child has exited. Normally both pipes EOF immediately and
        /// `markStreamClosed` already resolved; this fallback covers a leaked
        /// grandchild still holding a pipe open, where EOF never comes. A short
        /// grace lets in-flight buffered reads land first. `resolve` is
        /// idempotent, so whichever path fires first wins.
        func handleTermination() {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.resolve()
            }
        }

        func markTimedOut(after seconds: TimeInterval) {
            lock.lock()
            let settled = resumed || (stdoutClosed && stderrClosed)
            let proc = process
            // A process that already exited (pipes about to EOF) is not a timeout.
            if settled || !(proc?.isRunning ?? false) { lock.unlock(); return }
            timedOut = true
            timeoutSeconds = seconds
            lock.unlock()
            escalate(proc)
        }

        func markCancelled() {
            lock.lock()
            let settled = resumed || (stdoutClosed && stderrClosed)
            let proc = process
            if settled { lock.unlock(); return }
            cancelled = true
            lock.unlock()
            escalate(proc)
        }

        func finishLaunchFailure(_ message: String) {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            // Drop unused handlers; nothing launched.
            cont?.resume(throwing: ProcessRunError.launchFailed(message))
        }

        private func escalate(_ proc: Process?) {
            guard let proc, proc.isRunning else { return }
            proc.terminate() // SIGTERM
            let deadline = DispatchTime.now() + grace
            queue.asyncAfter(deadline: deadline) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }

        /// Both streams reached EOF: the child has closed its pipes and is
        /// exiting. Reap it, then resume once with a result or the pending error.
        private func resolve() {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            let cont = continuation
            continuation = nil
            let proc = process
            let out = stdoutData
            let err = stderrData
            let outTrunc = stdoutTruncated
            let errTrunc = stderrTruncated
            let didTimeout = timedOut
            let didCancel = cancelled
            let timeoutAfter = timeoutSeconds
            lock.unlock()

            proc?.waitUntilExit()
            let status = proc?.terminationStatus ?? -1

            if didCancel {
                cont?.resume(throwing: ProcessRunError.cancelled(
                    stderrTail: Self.tail(err)
                ))
            } else if didTimeout {
                cont?.resume(throwing: ProcessRunError.timedOut(
                    after: timeoutAfter, stderrTail: Self.tail(err)
                ))
            } else {
                cont?.resume(returning: ProcessRunResult(
                    stdout: out,
                    stderr: err,
                    exitStatus: status,
                    stdoutTruncated: outTrunc,
                    stderrTruncated: errTrunc
                ))
            }
        }

        private static func tail(_ data: Data, maxBytes: Int = 2048) -> String {
            let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
            return String(decoding: slice, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
