import Testing
import Foundation
import Network
@testable import Domain
@testable import Infrastructure

/// Lifecycle regression for `StatusLineObserver` (RC gate 6, 2026-09-21).
///
/// Live incident: starting the observer crashed the process with SIGTRAP —
/// `stateUpdateHandler` (invoked ON the observer's serial queue) called
/// `queue.sync` against that same queue, and `processRequest` did the same
/// from the connection callback. libdispatch traps on sync-on-owned-queue.
/// This suite starts a REAL listener (ephemeral port, port file injection is
/// a no-op so the real home is never touched); before the fix it traps the
/// whole test process, after it must reach `.ready` and stop cleanly.
@Suite(.serialized)
struct StatusLineObserverLifecycleTests {
    private func makeObserver() -> StatusLineObserver {
        StatusLineObserver(
            defaultPort: 0, // ephemeral — never collides with a live app
            portWriter: { _ in },
            portRemover: {}
        )
    }

    private func waitForPort(_ observer: StatusLineObserver) async -> UInt16 {
        for _ in 0..<50 {
            if observer.actualPort != 0 { return observer.actualPort }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return observer.actualPort
    }

    @Test("start() reaches ready with a bound port, stop() releases it")
    func startReachesReadyAndStops() async throws {
        let observer = makeObserver()
        try observer.start()
        let port = await waitForPort(observer)
        #expect(port != 0, "observer must report the bound port after .ready")
        observer.stop()
        #expect(observer.actualPort == 0, "stop() must release the port")
    }

    @Test("start() is idempotent — a second call keeps the same listener")
    func startIsIdempotent() async throws {
        let observer = makeObserver()
        try observer.start()
        let first = await waitForPort(observer)
        #expect(first != 0)

        try observer.start() // no-op while running
        let second = await waitForPort(observer)
        #expect(second == first, "second start must not rebind a new port")

        observer.stop()
    }

    @Test("isRequestComplete waits for the declared body bytes")
    func requestCompleteness() {
        let head = "POST /statusline HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        #expect(StatusLineObserver.isRequestComplete(Data(head.utf8)) == false,
                "headers alone are not a complete request when a length is declared")
        #expect(StatusLineObserver.isRequestComplete(Data((head + "12345").utf8)) == false,
                "partial body must keep the server reading")
        #expect(StatusLineObserver.isRequestComplete(Data((head + "1234567890").utf8)) == true)
        let bodyless = "POST /hook HTTP/1.1\r\nHost: x\r\n\r\n"
        #expect(StatusLineObserver.isRequestComplete(Data(bodyless.utf8)) == true,
                "no Content-Length → headers suffice")
        #expect(StatusLineObserver.isRequestComplete(Data("POST /st".utf8)) == false)
    }

    /// Minimal raw-TCP POST over Network.framework. Deliberately NOT
    /// URLSession: under full-suite parallel load the HTTP client stack
    /// timed out intermittently (flake proven 2026-09-21), while the raw
    /// connection exercises the exact same server callback deterministically.
    private func rawPost(port: UInt16, path: String, body: String) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let probe = ConnectionProbe(port: port, continuation: continuation) else {
                continuation.resume(returning: false)
                return
            }
            probe.start(path: path, body: body)
        }
    }

    @Test("a request served on the connection callback mutates state without trapping")
    func servedRequestMutatesState() async throws {
        // Before the fix, processRequest's queue.sync trapped the process on
        // the first served POST. Exercising the full path here pins that.
        let observer = makeObserver()
        try observer.start()
        let port = await waitForPort(observer)
        #expect(port != 0)

        // Fresh payload timestamp: `latestObservation` filters anything older
        // than its 1 h maxAge window, and a hardcoded fixture rots out of the
        // window as the session runs (same trap as ClaudeStatusLineProbeTests,
        // 2026-09-20).
        let formatter = ISO8601DateFormatter()
        let ts = formatter.string(from: Date())
        let payload = #"{"timestamp":"\#(ts)","model":"claude-opus-4-5","rate_limits":{"five_hour":{"used_percentage":42,"resets_at":"2026-09-22T02:00:00Z"}}}"#
        // Up to two attempts: a refused first connect under heavy parallel
        // load is a test-harness artifact, not a server defect.
        for _ in 0..<2 where observer.latestObservation(for: "/tmp/rc-lifecycle") == nil {
            _ = await rawPost(port: port, path: "/statusline?configDir=%2Ftmp%2Frc-lifecycle", body: payload)
            for _ in 0..<20 {
                if observer.latestObservation(for: "/tmp/rc-lifecycle") != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        let observed = observer.latestObservation(for: "/tmp/rc-lifecycle")
        #expect(observed != nil, "served POST must land in the observation store")
        #expect(observed?.windows.first?.percentRemaining == 58)

        observer.stop()
    }
}

/// Raw-TCP one-shot POST probe used by the lifecycle suite. Lock-protected
/// state so it can be captured in `@Sendable` Network.framework callbacks.
/// Resumes its continuation exactly once (response, failure, or 5 s timeout).
private final class ConnectionProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var settled = false

    init?(port: UInt16, continuation: CheckedContinuation<Bool, Never>) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        // Explicit loopback endpoint — a string host goes through the
        // resolver and can fail/hang in a test process.
        self.connection = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: nwPort),
            using: .tcp
        )
        self.continuation = continuation
    }

    private func finish(_ ok: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        connection.cancel()
        continuation.resume(returning: ok)
    }

    func start(path: String, body: String) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let request = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Content-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n\(body)"
                connection.send(
                    content: Data(request.utf8),
                    completion: .contentProcessed { [self] error in
                        if error != nil { finish(false) }
                    }
                )
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, _, error in
                    finish(error == nil && data != nil)
                }
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in finish(false) }
    }
}
