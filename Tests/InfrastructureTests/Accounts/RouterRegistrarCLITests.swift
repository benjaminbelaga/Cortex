import Testing
import Foundation
import Domain
@testable import Infrastructure

/// C4-4 tests (review critique 2026-09-16 §6): the registrar is transactional —
/// argv carries the READ identity, failures never report router-connected,
/// exit 0 without an ack line is still a rejection, and every failure message
/// carries a bounded stderr tail. Stubs are shell scripts in a temp dir that
/// log their argv; no real `llm-router` is ever invoked.
@Suite("RouterRegistrarCLI")
struct RouterRegistrarCLITests {

    private static let identity = VerifiedIdentity(
        email: "personal@example.com", orgId: nil, orgName: nil,
        verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        method: .claudeAuthStatus
    )

    private func makeRequest(alias: String = "PERSONAL") -> RouterRegistrationRequest {
        RouterRegistrationRequest(
            target: .claude, alias: alias,
            authHome: "/Users/tester/.claude-personal",
            verifiedIdentity: Self.identity
        )
    }

    /// Writes one stub `llm-router` whose behaviour + output are baked in,
    /// logging argv to `<dir>/argv.log`. Returns the executable path.
    @discardableResult
    private func writeStub(
        body: String, into dir: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrc-\(UUID().uuidString)")
    ) throws -> (path: String, dir: URL) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(dir.path)/argv.log\"\n\(body)\n"
        let url = dir.appendingPathComponent("llm-router")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url.path, dir)
    }

    private func registrar(path: String, timeout: TimeInterval = 5) -> RouterRegistrarCLI {
        RouterRegistrarCLI(
            executablePath: path,
            options: .init(timeout: timeout)
        )
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Success

    @Test("Acknowledged success returns the outcome; argv carries the READ identity verbatim")
    func successArgvCarriesReadIdentity() async throws {
        let (path, dir) = try writeStub(
            body: "echo '{\"result\":\"ok\",\"alias\":\"PERSONAL\"}'"
        )
        defer { cleanup(dir) }
        let registrar = self.registrar(path: path)
        let outcome = try await registrar.register(makeRequest())
        #expect(outcome.alias == "PERSONAL")

        let argv = try String(contentsOf: dir.appendingPathComponent("argv.log"), encoding: .utf8)
        #expect(argv.contains("account add claude"))
        #expect(argv.contains("--verified-identity personal@example.com"))
        #expect(argv.contains("--auth-state connected"))
        #expect(argv.contains("--auth-home /Users/tester/.claude-personal"))
    }

    @Test("Plain-text ack line counts as acknowledgement")
    func plainTextAckCounts() async throws {
        let (path, dir) = try writeStub(body: "echo 'account added: PERSONAL'")
        defer { cleanup(dir) }
        let outcome = try await registrar(path: path).register(makeRequest())
        #expect(outcome.alias == "PERSONAL")
    }

    // MARK: - Failures never lie

    @Test("Non-zero exit → registryRejected naming the exit code and stderr tail")
    func nonZeroExitRejected() async throws {
        let (path, dir) = try writeStub(
            body: "echo 'alias already bound' 1>&2; exit 3"
        )
        defer { cleanup(dir) }
        await #expect(throws: EnrolmentError.self) {
            _ = try await registrar(path: path).register(makeRequest())
        }
    }

    @Test("Exit 0 with NO ack line is still a rejection — a bare exit 0 never registers")
    func silentZeroStillRejected() async throws {
        let (path, dir) = try writeStub(body: "exit 0") // no output at all
        defer { cleanup(dir) }
        do {
            _ = try await registrar(path: path).register(makeRequest())
            Issue.record("exit 0 without ack must throw registryRejected")
        } catch let error as EnrolmentError {
            guard case let .registryRejected(reason) = error else {
                Issue.record("expected registryRejected, got \(error)")
                return
            }
            #expect(reason.contains("no acknowledgement"))
        }
    }

    @Test("Timeout → registryRejected with the timeout duration")
    func timeoutRejected() async throws {
        let (path, dir) = try writeStub(body: "sleep 30")
        defer { cleanup(dir) }
        do {
            _ = try await registrar(path: path, timeout: 0.5).register(makeRequest())
            Issue.record("sleeping stub must time out")
        } catch let error as EnrolmentError {
            guard case let .registryRejected(reason) = error else {
                Issue.record("expected registryRejected, got \(error)")
                return
            }
            #expect(reason.contains("timed out"))
        }
    }

    @Test("Missing binary → registryRejected (dependency named, no crash)")
    func missingBinaryRejected() async {
        let registrar = RouterRegistrarCLI(executablePath: "/nonexistent/llm-router-\(UUID().uuidString)")
        do {
            _ = try await registrar.register(makeRequest())
            Issue.record("missing binary must throw")
        } catch let error as EnrolmentError {
            guard case .registryRejected = error else {
                Issue.record("expected registryRejected, got \(error)")
                return
            }
        } catch {
            Issue.record("expected EnrolmentError, got \(error)")
        }
    }

    // MARK: - Cancellation

    @Test("Task cancellation propagates as registryRejected with 'cancelled'")
    func cancellationRejected() async throws {
        let (path, dir) = try writeStub(body: "sleep 30")
        defer { cleanup(dir) }
        let registrar = self.registrar(path: path, timeout: 30)
        let task = Task {
            try await registrar.register(makeRequest())
        }
        // Give the child a moment to launch, then cancel the parent task.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled registration must throw")
        } catch let error as EnrolmentError {
            guard case let .registryRejected(reason) = error else {
                Issue.record("expected registryRejected, got \(error)")
                return
            }
            #expect(reason.contains("cancel"))
        } catch {
            Issue.record("expected EnrolmentError, got \(error)")
        }
    }
}
