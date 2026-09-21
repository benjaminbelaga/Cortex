import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

/// Regression tests for the "cota" bug class: raw CLI output (onboarding
/// prompts, settings dialogs, ANSI-mangled redraw fragments) leaking into
/// parsed fields and rendering in the menu bar.
///
/// Fixtures mirror payloads captured in ~/Library/Logs/ClaudeBar/ClaudeBar.log
/// on 2026-08-18: the Chrome-extension onboarding prompt and the
/// settings-validation dialog both appeared in place of the usage table.
@Suite
struct ClaudeUsageProbePromptLeakTests {

    private func makeProbe() -> ClaudeUsageProbe {
        ClaudeUsageProbe(accountInfoResolver: NoOpAccountInfoResolver())
    }

    // MARK: - Fixtures (from the live log)

    /// Chrome-extension onboarding prompt painted instead of the usage table,
    /// complete with cursor-positioning CSI sequences like the real TTY bytes.
    static let chromeOnboardingOutput = """
    \u{1B}[3GClaude\u{1B}[10Gin\u{1B}[13GChrome\u{1B}[20Gextension\u{1B}[30Gdetected\u{1B}[0m

    \u{1B}[3GClaude\u{1B}[10Gwill\u{1B}[15Guse\u{1B}[19Gyour\u{1B}[24GChrome\u{1B}[31Gbrowser\u{1B}[39Gby\u{1B}[42Gdefault\u{1B}[0m

    \u{1B}[3GThis\u{1B}[8Gsession\u{1B}[16Gis\u{1B}[19Gin\u{1B}[22GAuto\u{1B}[27Gmode\u{1B}[0m

    \u{1B}[3G❯\u{1B}[5G1.\u{1B}[8GYes,\u{1B}[13Guse\u{1B}[17Gmy\u{1B}[20Gbrowser\u{1B}[0m
    \u{1B}[5G2.\u{1B}[8GNo,\u{1B}[12Gkeep\u{1B}[17Gbrowser\u{1B}[25Gtools\u{1B}[31Goff\u{1B}[0m

    \u{1B}[3GEnter\u{1B}[9Gto\u{1B}[12Gconfirm\u{1B}[20G·\u{1B}[22GEsc\u{1B}[29Gto\u{1B}[32Gkeep\u{1B}[34Gbrowser\u{1B}[42Gtools\u{1B}[48Goff\u{1B}[0m
    """

    /// Settings-validation dialog (invalid settings in the profile's
    /// settings.json) painted instead of the usage table.
    static let settingsValidationOutput = """
    Claude Code v2.1.198

    ⚠️ Settings validation failed

    Invalid value for permissions.allow: "*"

    ❯ 1. Continue
      2. Fix with Claude
      3. Exit and fix manually
    """

    /// A healthy usage table for reference assertions.
    static let healthyUsageOutput = """
    Claude Code v2.1.198

    Current session
    ██████████░░░░░░░░░░ 47% used
    Resets in 2h 15m

    Current week (all models)
    ████████████░░░░░░░░ 40% left
    Resets Jan 15, 3:30pm (America/Los_Angeles)
    """

    // MARK: - ANSIStripper

    @Test("ANSIStripper removes cursor-positioning sequences")
    func ANSIStripperRemovesCursorPositioningSequences() {
        let stripped = ANSIStripper.strip(Self.chromeOnboardingOutput)
        #expect(!stripped.contains("\u{1B}"))
        #expect(stripped.contains("Claude"))
        #expect(stripped.contains("keep browser tools off"))
        // Line structure survives
        #expect(stripped.contains("\n"))
    }

    @Test("ANSIStripper preserves plain usage tables")
    func ANSIStripperPreservesPlainUsageTables() {
        let stripped = ANSIStripper.strip(Self.healthyUsageOutput)
        #expect(stripped == Self.healthyUsageOutput)
    }

    // MARK: - extractReset strict whitelist

    @Test("extractReset rejects Chrome onboarding prompt line")
    func extractResetRejectsChromeOnboardingPromptLine() {
        let probe = makeProbe()
        let text = """
        Current session
        Claude in Chrome extension detected
        Resets in 2h 15m
        """
        // The prompt line appears BEFORE the real reset line inside the
        // 14-line window: the whitelist must skip it and find the real one.
        let result = probe.extractReset(labelSubstring: "Current session", text: text)
        #expect(result == "Resets in 2h 15m")
    }

    @Test("extractReset returns nil when only prompt text follows the label")
    func extractResetReturnsNilWhenOnlyPromptTextFollowsTheLabel() {
        let probe = makeProbe()
        let text = """
        Current session
        Claude in Chrome extension detected
        This session is in Auto mode
        ❯ 1. Yes, use my browser
        """
        let result = probe.extractReset(labelSubstring: "Current session", text: text)
        #expect(result == nil)
    }

    @Test("extractReset returns nil for settings-validation dialog")
    func extractResetReturnsNilForSettingsValidationDialog() {
        let probe = makeProbe()
        let result = probe.extractReset(labelSubstring: "Current session", text: Self.settingsValidationOutput)
        #expect(result == nil)
    }

    @Test("extractReset accepts documented clock formats")
    func extractResetAcceptsDocumentedClockFormats() {
        let probe = makeProbe()
        for resetLine in [
            "Resets in 2h 15m",
            "Resets 30m",
            "Resets 2d",
            "Resets 4:59pm (America/New_York)",
            "Resets 3pm",
            "Resets Jan 15, 3:30pm (America/Los_Angeles)",
            "Resets Jan 1, 2026",
            "$5.41 / $20.00 spent · Resets Jan 1, 2026",
        ] {
            let text = "Current session\n\(resetLine)\n"
            let result = probe.extractReset(labelSubstring: "Current session", text: text)
            #expect(result != nil, "expected acceptance for: \(resetLine)")
        }
    }

    // MARK: - cleanResetText post-parse defense

    @Test("cleanResetText rejects implausible strings")
    func cleanResetTextRejectsImplausibleStrings() {
        let probe = makeProbe()
        // Too long (prompt sentence, not a reset)
        #expect(probe.cleanResetText("Claude in Chrome extension detected — Enter to confirm") == nil)
        // Newline embedded
        #expect(probe.cleanResetText("Resets 2h\nSession forked") == nil)
        // No digit anywhere near the front
        #expect(probe.cleanResetText("extension detected") == nil)
    }

    @Test("cleanResetText still prefixes valid short durations")
    func cleanResetTextStillPrefixesValidShortDurations() {
        let probe = makeProbe()
        #expect(probe.cleanResetText("in 2h") == "Resets in 2h")
        #expect(probe.cleanResetText("Resets 4:59pm (America/New_York)") == "Resets 4:59pm (America/New_York)")
    }

    // MARK: - end-to-end parse over mangled payloads

    @Test("parse throws on pure onboarding prompt instead of returning garbage")
    func parseThrowsOnPureOnboardingPromptInsteadOfReturningGarbage() {
        #expect(throws: ProbeError.self) {
            _ = try ClaudeUsageProbe.parse(Self.chromeOnboardingOutput)
        }
    }

    @Test("parse throws on settings dialog instead of returning garbage")
    func parseThrowsOnSettingsDialogInsteadOfReturningGarbage() {
        #expect(throws: ProbeError.self) {
            _ = try ClaudeUsageProbe.parse(Self.settingsValidationOutput)
        }
    }

    @Test("parse succeeds on healthy table and yields whitelisted resetText")
    func parseSucceedsOnHealthyTableAndYieldsWhitelistedResettext() throws {
        let snapshot = try ClaudeUsageProbe.parse(Self.healthyUsageOutput)
        #expect(snapshot.quotas.count == 2)
        let session = snapshot.quotas.first { $0.quotaType == .session }
        #expect(session?.resetText == "Resets in 2h 15m")
        let weekly = snapshot.quotas.first { $0.quotaType == .weekly }
        #expect(weekly?.resetText?.hasPrefix("Resets Jan 15") == true)
    }
}
