import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite
struct CodexUsageProbeParsingTests {

    // MARK: - Sample CLI Output

    static let sampleCodexOutput = """
    Codex v1.2.0

    Credits: 150.50

    5h limit
    ████████████████░░░░ 65% left
    resets in 2h 15m

    Weekly limit
    ██████████░░░░░░░░░░ 35% left
    resets Jan 15
    """

    static let exhaustedQuotaOutput = """
    Codex v1.2.0

    Credits: 0.00

    5h limit
    ░░░░░░░░░░░░░░░░░░░░ 0% left
    resets in 30m

    Weekly limit
    ██████████░░░░░░░░░░ 35% left
    resets Jan 15
    """

    static let creditsOnlyOutput = """
    Credits: 500.00
    """

    // MARK: - Parsing Percentages

    @Test
    func `parses five hour limit from codex output`() throws {
        // Given
        let output = Self.sampleCodexOutput

        // When
        let snapshot = try simulateParse(text: output)

        // Then
        #expect(snapshot.sessionQuota?.percentRemaining == 65)
        #expect(snapshot.sessionQuota?.status == .healthy)
    }

    @Test
    func `parses weekly limit from codex output`() throws {
        // Given
        let output = Self.sampleCodexOutput

        // When
        let snapshot = try simulateParse(text: output)

        // Then
        #expect(snapshot.weeklyQuota?.percentRemaining == 35)
        #expect(snapshot.weeklyQuota?.status == .warning)
    }

    @Test
    func `detects depleted quota at zero percent`() throws {
        // Given
        let output = Self.exhaustedQuotaOutput

        // When
        let snapshot = try simulateParse(text: output)

        // Then
        #expect(snapshot.sessionQuota?.percentRemaining == 0)
        #expect(snapshot.sessionQuota?.status == .depleted)
        #expect(snapshot.sessionQuota?.isDepleted == true)
    }

    @Test
    func `credits only output throws parse error without limits`() throws {
        // Given
        let output = Self.creditsOnlyOutput

        // When & Then - We need quota limits, not just credits
        #expect(throws: ProbeError.self) {
            try simulateParse(text: output)
        }
    }

    // MARK: - Error Detection

    static let updateRequiredOutput = """
    Update available: 1.2.1
    Run `bun install -g @openai/codex` to update
    """

    static let dataNotAvailableOutput = """
    data not available yet
    """

    @Test
    func `detects update required and throws error`() throws {
        // Given
        let output = Self.updateRequiredOutput

        // When & Then
        #expect(throws: ProbeError.self) {
            try simulateParse(text: output)
        }
    }

    @Test
    func `detects data not available and throws error`() throws {
        // Given
        let output = Self.dataNotAvailableOutput

        // When & Then
        #expect(throws: ProbeError.self) {
            try simulateParse(text: output)
        }
    }

    // MARK: - ANSI Code Handling

    static let ansiColoredOutput = """
    \u{1B}[32m5h limit\u{1B}[0m
    ████████████████░░░░ \u{1B}[33m65% left\u{1B}[0m
    resets in 2h 15m
    """

    @Test
    func `strips ansi color codes before parsing`() throws {
        // Given
        let output = Self.ansiColoredOutput

        // When
        let snapshot = try simulateParse(text: output)

        // Then
        #expect(snapshot.sessionQuota?.percentRemaining == 65)
    }

    // MARK: - Helper

    private func simulateParse(text: String) throws -> UsageSnapshot {
        try CodexUsageProbe.parse(text)
    }
}
