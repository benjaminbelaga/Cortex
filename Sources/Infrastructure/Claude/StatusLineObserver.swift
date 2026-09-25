import Foundation
import Network
import Domain

/// Localhost-only HTTP observer that receives `ClaudeRateLimitObservation`s
/// POSTed by the `cortex-statusline.sh` shim. Stores the latest observation
/// per config directory in memory; consumers (`ClaudeStatusLineProbe`) read
/// synchronously.
///
/// Why a dedicated observer instead of reusing `HookHTTPServer`: the hook
/// server consumes `SessionEvent` (a closed type) and routes through
/// `SessionEventParser`. The statusline payload is a different schema from
/// a different producer; sharing the port means either a discriminator
/// field (which `SessionEvent` would have to learn) or a multi-route
/// handler (which couples the two concerns in one file). Separate observer,
/// separate port — easier to reason about, easier to gate behind the
/// `claudeStatusLineAdapterEnabled` kill-switch, and easier to ship a
/// regression fix on one without the other.
///
/// Concurrency: NWListener callbacks run on `queue`. All mutable state is
/// accessed on `queue`; external readers (`latestObservation(for:)`) use
/// `queue.sync` so the read is linearizable with respect to the writer.
public final class StatusLineObserver: @unchecked Sendable {
    /// Process-wide singleton. The shim POSTs to a single observer;
    /// tests inject their own instance.
    public static let shared = StatusLineObserver()

    private let defaultPort: UInt16
    private let queue = DispatchQueue(label: "fr.yoyaku.cortex.statusline-observer")
    private var listener: NWListener?
    private var observations: [String: ClaudeRateLimitObservation] = [:]
    public private(set) var actualPort: UInt16 = 0
    /// Port-file persistence seam. Production writes
    /// `~/.claude/cortex-statusline-port`; tests inject no-ops so a lifecycle
    /// test never touches the real home.
    private let portWriter: (Int) throws -> Void
    private let portRemover: () -> Void

    public init(
        defaultPort: UInt16 = HookConstants.defaultStatusLinePort,
        portWriter: @escaping (Int) throws -> Void = { try StatusLinePortDiscovery.writePort($0) },
        portRemover: @escaping () -> Void = { StatusLinePortDiscovery.removePortFile() }
    ) {
        self.defaultPort = defaultPort
        self.portWriter = portWriter
        self.portRemover = portRemover
    }

    /// Starts the observer. Idempotent — calling twice is a no-op the
    /// second time (the listener stays up).
    public func start() throws {
        var alreadyRunning = false
        queue.sync { alreadyRunning = listener != nil }
        guard !alreadyRunning else { return }

        let port: NWEndpoint.Port = NWEndpoint.Port(rawValue: defaultPort) ?? .any
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)

        // `stateUpdateHandler` runs on `queue` (set by `listener.start`
        // below), so mutable state is touched directly — a `queue.sync`
        // here would deadlock against our own serial queue and trap
        // (dispatch-sync-on-owned-queue). Regression proven live 2026-09-21.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let actualPort = listener.port?.rawValue {
                    self.actualPort = actualPort
                    try? self.portWriter(Int(actualPort))
                    AppLog.hooks.info("StatusLine observer listening on port \(actualPort)")
                }
            case .failed(let error):
                AppLog.hooks.error("StatusLine observer failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: queue)
        queue.sync { self.listener = listener }
    }

    /// Stops the observer and drops in-memory observations.
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            observations.removeAll()
            actualPort = 0
            portRemover()
            AppLog.hooks.info("StatusLine observer stopped")
        }
    }

    /// Latest observation for `configDir`, or nil if none has been received
    /// (or if the observation is older than `maxAge` — defaults to 1 hour,
    /// generous enough to span a long Claude session but short enough that
    /// a stale 0% from yesterday doesn't paint the row red).
    public func latestObservation(
        for configDir: String,
        maxAge: TimeInterval = 3600
    ) -> ClaudeRateLimitObservation? {
        let expanded = (configDir as NSString).expandingTildeInPath
        return queue.sync {
            let key = observations.keys.first { k in
                ((k as NSString).expandingTildeInPath) == expanded
            } ?? expanded
            guard let observation = observations[key] else { return nil }
            let age = Date().timeIntervalSince(observation.capturedAt)
            return age <= maxAge ? observation : nil
        }
    }

    /// True when the observer has at least one observation across any
    /// configDir — used by `ClaudeStatusLineProbe.isAvailable()`.
    public var hasAnyObservation: Bool {
        queue.sync { !observations.isEmpty }
    }

    /// Test seam: inject an observation directly. Production code receives
    /// observations via POST; tests use this to seed state without standing
    /// up a real NWListener.
    public func recordForTesting(_ observation: ClaudeRateLimitObservation) {
        let expanded = (observation.configDir as NSString).expandingTildeInPath
        queue.sync {
            observations[expanded] = observation
        }
    }

    // MARK: - Connection handling

    /// HTTP requests are not guaranteed to arrive in a single `receive`
    /// callback: URLSession writes head and body separately, and larger
    /// payloads span TCP segments (live proof 2026-09-21 — a single-read
    /// server parsed an empty body). Accumulate until the declared
    /// Content-Length is present (or the connection finishes / the cap is
    /// hit), then respond once and process.
    private static let maxRequestBytes = 1 << 20 // 1 MiB

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveChunk(in: connection, accumulated: Data())
    }

    private func receiveChunk(in connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if Self.isRequestComplete(buffer) || isComplete || error != nil
                || buffer.count >= Self.maxRequestBytes
            {
                self.respondAndClose(connection)
                self.processRequest(buffer)
                return
            }
            self.receiveChunk(in: connection, accumulated: buffer)
        }
    }

    /// True when the accumulated bytes contain the header terminator and,
    /// when a `Content-Length` is declared, at least that many body bytes.
    static func isRequestComplete(_ data: Data) -> Bool {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: marker) else { return false }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return true
        }
        guard let lengthLine = headerText.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("content-length:")
        }) else {
            return true // no declared body — headers suffice
        }
        guard let rawValue = lengthLine.split(separator: ":", maxSplits: 1).last,
              let declared = Int(rawValue.trimmingCharacters(in: .whitespaces))
        else {
            return true
        }
        return data.count - headerEnd.upperBound >= declared
    }

    private func respondAndClose(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(
            content: response.data(using: .utf8),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    /// Runs on `queue` (called from `connection.receive`, itself started on
    /// the queue) — no `queue.sync` for state mutation, same rule as the
    /// listener callbacks above.
    private func processRequest(_ rawData: Data) {
        guard let rawString = String(data: rawData, encoding: .utf8) else { return }
        guard let separator = rawString.range(of: "\r\n\r\n") else { return }
        let headerPart = String(rawString[rawString.startIndex..<separator.lowerBound])
        let bodyString = String(rawString[separator.upperBound...])
        guard headerPart.hasPrefix("POST /statusline") else { return }
        guard let bodyData = bodyString.data(using: .utf8) else { return }

        // The configDir comes from a query param: `POST /statusline?configDir=<url-encoded>`
        let configDir = extractConfigDir(from: headerPart) ?? ""
        do {
            if let observation = try ClaudeRateLimitObservation.parse(bodyData, configDir: configDir) {
                let expanded = (configDir as NSString).expandingTildeInPath
                observations[expanded] = observation
            }
        } catch {
            AppLog.hooks.warning("StatusLine parse failed: \(error)")
        }
    }

    private func extractConfigDir(from header: String) -> String? {
        guard let firstLine = header.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let query = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "configDir" else { continue }
            return String(kv[1])
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// Discovers the StatusLineObserver port to the shim. Lives separately from
/// `PortDiscovery` so the shim reads its own file
/// (`~/.claude/cortex-statusline-port`) without ever touching the hook port.
public enum StatusLinePortDiscovery {
    public static var portFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/cortex-statusline-port"
    }

    public static func writePort(_ port: Int) throws {
        let directory = (portFilePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try "\(port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)
    }

    public static func readPort() -> Int? {
        guard let content = try? String(contentsOfFile: portFilePath, encoding: .utf8) else {
            return nil
        }
        return Int(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func removePortFile() {
        try? FileManager.default.removeItem(atPath: portFilePath)
    }
}
