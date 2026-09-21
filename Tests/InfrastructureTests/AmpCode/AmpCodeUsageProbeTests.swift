import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite
struct AmpCodeUsageProbeTests {

    static let sampleOutput = """
    Signed in as user@example.com (username)
    Amp Free: $17.59/$20 remaining (replenishes +$0.83/hour) [+100% bonus for 19 more days] - https://ampcode.com/settings#amp-free
    Individual credits: $0 remaining - https://ampcode.com/settings
    """

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when amp binary found`() async {
        // Given
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.value("amp")).willReturn("/usr/local/bin/amp")
        
        let probe = AmpCodeUsageProbe(cliExecutor: mockExecutor)

        // When & Then
        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when amp binary not found`() async {
        // Given
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.value("amp")).willReturn(nil)
        
        let probe = AmpCodeUsageProbe(cliExecutor: mockExecutor)

        // When & Then
        #expect(await probe.isAvailable() == false)
    }

    // MARK: - Probe Tests

    @Test
    func `probe returns snapshot on success`() async throws {
        // Given
        let mockExecutor = MockCLIExecutor()
        
        // 1. Locate amp
        given(mockExecutor).locate(.value("amp")).willReturn("/usr/local/bin/amp")
        
        // 2. Execute amp usage
        given(mockExecutor)
            .execute(
                binary: .value("/usr/local/bin/amp"),
                args: .value(["usage", "--no-color"]),
                input: .any,
                timeout: .any,
                workingDirectory: .any,
                autoResponses: .any
            )
            .willReturn(CLIResult(output: Self.sampleOutput, exitCode: 0))

        let probe = AmpCodeUsageProbe(cliExecutor: mockExecutor)

        // When
        let snapshot = try await probe.probe()

        // Then
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.quotas.count == 2)
        let freeQuota = snapshot.quotas.first { $0.quotaType == .modelSpecific("Free") }
        let creditsQuota = snapshot.quotas.first { $0.quotaType == .modelSpecific("Individual") }
        #expect(freeQuota?.percentRemaining == 87.95)
        #expect(creditsQuota?.dollarRemaining == 0)
        #expect(creditsQuota?.percentRemaining == 100)
    }

    @Test
    func `probe throws cliNotFound when amp binary not found`() async throws {
        // Given
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.value("amp")).willReturn(nil)
        
        let probe = AmpCodeUsageProbe(cliExecutor: mockExecutor)

        // When & Then
        await #expect(throws: ProbeError.cliNotFound("AmpCode")) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws executionFailed when command exits with error`() async throws {
        // Given
        let mockExecutor = MockCLIExecutor()
        
        // 1. Locate amp
        given(mockExecutor).locate(.value("amp")).willReturn("/usr/local/bin/amp")
        
        // 2. Execute returns error code
        given(mockExecutor)
            .execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willReturn(CLIResult(output: "Error: something went wrong", exitCode: 1))

        let probe = AmpCodeUsageProbe(cliExecutor: mockExecutor)

        // When & Then
        await #expect(throws: ProbeError.executionFailed("amp usage exited with code 1")) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws executionFailed when execution throws`() async throws {
        // Given
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.value("amp")).willReturn("/usr/local/bin/amp")
        
        given(mockExecutor)
            .execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willThrow(ProbeError.executionFailed("timeout"))

        let probe = AmpCodeUsageProbe(cliExecutor: mockExecutor)

        // When & Then
        await #expect(throws: ProbeError.executionFailed("amp usage failed: timeout")) {
            try await probe.probe()
        }
    }
}
