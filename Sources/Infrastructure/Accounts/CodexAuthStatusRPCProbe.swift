import Foundation
import Domain

/// Production `CodexAuthStatusProbing` over `codex app-server` JSON-RPC
/// (review critique 2026-09-16 §7 direction, landed in C4-5).
///
/// One transport per call, keyed by `CODEX_HOME`:
/// - the child env is the PARENT env plus `CODEX_HOME` (the transport replaces
///   the environment when given one, so we merge explicitly) — two homes are
///   two isolated transports, no cross-read;
/// - the request is `account/read` (newline-delimited JSON-RPC 2.0);
/// - every exit path — success, timeout, malformed reply, process death —
///   CLOSES the transport (EOF on stdin + TERM), so no app-server accumulates;
/// - any failure returns `nil`: the caller (CodexAccountAdapter) treats nil as
///   "not authed yet" and keeps polling; it never fabricates an identity.
public struct CodexAuthStatusRPCProbe: CodexAuthStatusProbing {

    public let executable: String
    public let timeout: TimeInterval

    /// `codex app-server` arguments, mirroring `DefaultCodexRPCClient`
    /// (`-s read-only -a never` — #259: an unknown approval value kills the
    /// CLI at argument parsing, `never` is accepted by old and new builds).
    static let arguments = ["-s", "read-only", "-a", "never", "app-server"]

    public init(executable: String = "codex", timeout: TimeInterval = 10) {
        self.executable = executable
        self.timeout = timeout
    }

    public func authStatus(codexHome: String) async -> CodexAuthStatus? {
        // Parent env + CODEX_HOME: the transport REPLACES the environment when
        // one is supplied, so merge instead of passing a bare dictionary —
        // otherwise the child loses HOME/PATH/locale and behaves differently
        // from a user shell.
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = (codexHome as NSString).expandingTildeInPath

        let transport: ProcessRPCTransport
        do {
            transport = try ProcessRPCTransport(
                executable: executable,
                arguments: Self.arguments,
                environment: env
            )
        } catch {
            AppLog.probes.debug(
                "codex auth RPC transport failed to start: \(error.localizedDescription)"
            )
            return nil
        }

        // Every path below closes the transport: an app-server left running
        // is a leak (upstream has already had to fix exactly that).
        defer { transport.close() }

        do {
            let reply = try await withTimeout(timeout) {
                try transport.send(JSONSerialization.data(withJSONObject: [
                    "id": 0, "method": "initialize", "params": [
                        "clientInfo": ["name": "cortex", "version": "2.0.0"]
                    ]
                ]))
                _ = try await Self.receiveReply(transport, id: 0)
                try transport.send(Data(#"{"method":"initialized","params":{}}"#.utf8))
                try transport.send(Self.request(id: 1))
                return try await Self.receiveReply(transport, id: 1)
            }
            return Self.parse(reply)
        } catch {
            AppLog.probes.debug(
                "codex auth RPC failed: \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Wire helpers

    static func receiveReply(_ transport: any RPCTransport, id: Int) async throws -> Data {
        while !Task.isCancelled {
            let data = try await transport.receive()
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["id"] as? Int == id else { continue }
            if object["error"] != nil { throw ProbeError.authenticationRequired }
            return data
        }
        throw CancellationError()
    }

    /// Newline-delimited JSON-RPC 2.0 `account/read` request.
    static func request(id: Int) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "account/read",
            "params": ["refreshToken": false],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// Parses a JSON-RPC reply envelope into `CodexAuthStatus`. Tolerant by
    /// design: the app-server schema lives outside Cortex, so the parser
    /// accepts both camelCase and snake_case spellings and ignores unknown
    /// keys. An error envelope, a missing result, or a result without an
    /// account/email means NOT logged in (nil identity), never a crash.
    static func parse(_ data: Data) -> CodexAuthStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // JSON-RPC error envelope → not authed / method unavailable.
        if root["error"] != nil { return nil }
        guard let result = root["result"] else { return nil }

        // The result may be the account object itself or a wrapper
        // ({"account": {...}}) depending on schema version.
        let account = (result as? [String: Any]) ?? [:]
        let nested = account["account"] as? [String: Any] ?? account

        let email = nested["email"] as? String
            ?? nested["emailAddress"] as? String
        let plan = nested["plan"] as? String
            ?? nested["planType"] as? String
            ?? nested["plan_type"] as? String
        let accountId = nested["accountId"] as? String
            ?? nested["account_id"] as? String
            ?? nested["id"] as? String

        // Logged in = the server knows an account with an identity. Absent
        // email on an otherwise-present account is still "logged in but
        // unknown identity" — surfaced as loggedIn with nil email so the
        // enrolment pipeline keeps waiting rather than fabricating one.
        let hasAccount = !nested.isEmpty
        let loggedIn = hasAccount && (email != nil || nested.keys.contains(where: {
            ["plan", "planType", "plan_type", "accountId", "account_id", "id"].contains($0)
        }))

        guard loggedIn else { return nil }
        return CodexAuthStatus(
            loggedIn: true, email: email, planType: plan, accountId: accountId
        )
    }

    /// Races `body` against a deadline; on timeout, cancels the group so a
    /// parked `receive()` cannot outlive the caller, then rethrows.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ProbeError.executionFailed(
                    "codex auth RPC timed out after \(Int(seconds))s"
                )
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
