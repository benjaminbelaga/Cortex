import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("KimiCLIUsageProbe Tests")
struct KimiCLIUsageProbeTests {

    // MARK: - Sample Output

    private static let validCLIOutput = """
    ╭─────────────────────────────── API Usage ───────────────────────────────╮
    │  Weekly limit  ━━━━━━━━━━━━━━━━━━━━  100% left  (resets in 6d 23h 22m)  │
    │  5h limit      ━━━━━━━━━━━━━━━━━━━━  100% left  (resets in 4h 22m)      │
    ╰─────────────────────────────────────────────────────────────────────────╯
    """

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when kimi binary is found`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/kimi")
        let probe = KimiCLIUsageProbe(cliExecutor: mockExecutor)

        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when kimi binary is not found`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn(nil)
        let probe = KimiCLIUsageProbe(cliExecutor: mockExecutor)

        #expect(await probe.isAvailable() == false)
    }

    // MARK: - Probe Success Tests

    @Test
    func `probe sends usage command and returns snapshot`() async throws {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/kimi")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: Self.validCLIOutput, exitCode: 0))

        let probe = KimiCLIUsageProbe(cliExecutor: mockExecutor)
        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "kimi")
        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.quota(for: .weekly)?.percentRemaining == 100.0)
        #expect(snapshot.quota(for: .session)?.percentRemaining == 100.0)
    }

    // MARK: - Probe Error Tests

    @Test
    func `probe throws cliNotFound when binary missing`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn(nil)

        let probe = KimiCLIUsageProbe(cliExecutor: mockExecutor)

        await #expect(throws: ProbeError.cliNotFound("kimi")) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws on unexpected output`() async {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/kimi")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: "Unexpected output with no usage data", exitCode: 0))

        let probe = KimiCLIUsageProbe(cliExecutor: mockExecutor)

        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws executionFailed when CLI execution fails`() async {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/kimi")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willThrow(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Process timed out"]))

        let probe = KimiCLIUsageProbe(cliExecutor: mockExecutor)

        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }
}
