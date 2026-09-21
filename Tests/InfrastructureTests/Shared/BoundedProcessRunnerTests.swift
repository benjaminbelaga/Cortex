import Testing
import Foundation
@testable import Infrastructure

/// Pins the concurrent-drain contract of `BoundedProcessRunner`: large output on
/// either stream never deadlocks, exit status and stderr are preserved, the
/// deadline escalates TERM → SIGKILL, Task cancellation reaps the child, and the
/// byte cap truncates without hanging.
@Suite("BoundedProcessRunner")
struct BoundedProcessRunnerTests {

    private func sh(_ script: String) -> (String, [String]) {
        ("/bin/sh", ["-c", script])
    }

    @Test("Large stdout (1 MiB) drains without deadlock")
    func largeStdout() async throws {
        let runner = BoundedProcessRunner()
        let (exe, args) = sh("yes X | head -c 1048576")
        let result = try await runner.run(executable: exe, arguments: args,
                                          options: .init(timeout: 20))
        #expect(result.exitStatus == 0)
        #expect(result.stdout.count == 1_048_576)
        #expect(result.stdoutTruncated == false)
    }

    @Test("Large stderr (1 MiB) drains without deadlock")
    func largeStderr() async throws {
        let runner = BoundedProcessRunner()
        let (exe, args) = sh("yes X | head -c 1048576 1>&2")
        let result = try await runner.run(executable: exe, arguments: args,
                                          options: .init(timeout: 20))
        #expect(result.exitStatus == 0)
        #expect(result.stderr.count == 1_048_576)
    }

    @Test("Non-zero exit is a result, with stderr preserved")
    func nonZeroExitPreservesStderr() async throws {
        let runner = BoundedProcessRunner()
        let (exe, args) = sh("echo boom 1>&2; exit 3")
        let result = try await runner.run(executable: exe, arguments: args)
        #expect(result.exitStatus == 3)
        #expect(result.stderrTail().contains("boom"))
    }

    @Test("A TERM-ignoring child is force-killed at the deadline")
    func termIgnoringChildIsKilled() async throws {
        let runner = BoundedProcessRunner()
        let (exe, args) = sh("trap '' TERM; sleep 30")
        let start = Date()
        await #expect(throws: ProcessRunError.self) {
            _ = try await runner.run(executable: exe, arguments: args,
                                     options: .init(timeout: 0.5, terminationGrace: 0.3))
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("A missing executable fails to launch")
    func missingExecutable() async throws {
        let runner = BoundedProcessRunner()
        await #expect(throws: ProcessRunError.self) {
            _ = try await runner.run(
                executable: "/nonexistent/cortex-does-not-exist", arguments: []
            )
        }
    }

    @Test("Task cancellation stops the run and reaps the child")
    func cancellationReapsChild() async throws {
        let runner = BoundedProcessRunner()
        let (exe, args) = sh("sleep 30")
        let task = Task {
            try await runner.run(executable: exe, arguments: args,
                                 options: .init(timeout: 30, terminationGrace: 0.3))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let start = Date()
        await #expect(throws: ProcessRunError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("Output beyond the cap is truncated, drain still completes")
    func capTruncates() async throws {
        let runner = BoundedProcessRunner()
        let (exe, args) = sh("yes X | head -c 5242880") // 5 MiB
        let result = try await runner.run(executable: exe, arguments: args,
                                          options: .init(timeout: 30, maxBytesPerStream: 1_048_576))
        #expect(result.exitStatus == 0)
        #expect(result.stdout.count == 1_048_576)
        #expect(result.stdoutTruncated == true)
    }

    @Test("Large stdout with a non-zero exit keeps both")
    func largeStdoutNonZeroExit() async throws {
        let runner = BoundedProcessRunner()
        let (exe, args) = sh("yes X | head -c 262144; exit 7")
        let result = try await runner.run(executable: exe, arguments: args,
                                          options: .init(timeout: 20))
        #expect(result.stdout.count == 262_144)
        #expect(result.exitStatus == 7)
    }
}
