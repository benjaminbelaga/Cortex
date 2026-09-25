import AppKit
import SwiftUI
import Testing
@testable import Cortex
@testable import Domain

@Suite("Status item rendering")
@MainActor
struct StatusItemRenderingTests {
    @Test("build provenance reads full SHA UTC timestamp and clean marker")
    func buildProvenanceReadsStampedValues() {
        let provenance = BuildProvenance(infoDictionary: [
            "CortexGitSHA": "0123456789abcdef0123456789abcdef01234567",
            "CortexBuildUTC": "2026-08-21T08:00:00Z",
            "CortexGitDirty": false,
        ])

        #expect(provenance.gitSHA.count == 40)
        #expect(provenance.shortSHA == "0123456789ab")
        #expect(provenance.builtAtUTC == "2026-08-21T08:00:00Z")
        #expect(provenance.isDirty == false)
    }

    @Test("dual bars do not require an email suffix")
    func dualBarsDoNotRequireEmailSuffix() {
        let segments = [
            MenuBarLabel.Segment(text: "5h 70%", status: .healthy, percentRemaining: 70),
            MenuBarLabel.Segment(text: "7d 30%", status: .warning, percentRemaining: 30),
        ]

        #expect(StatusItemLabelDriver.shouldRenderDualBars(stacked: true, segments: segments))
    }

    @Test("zero percent has no progress fill")
    func zeroPercentHasNoProgressFill() {
        #expect(StatusBarDualBarImageRenderer.fillWidth(for: -1) == 0)
        #expect(StatusBarDualBarImageRenderer.fillWidth(for: 0) == 0)
        #expect(StatusBarDualBarImageRenderer.fillWidth(for: 0.1) == 4)
        #expect(StatusBarDualBarImageRenderer.fillWidth(for: 100) == 60)
    }

    @Test("Cortex brain is black in light mode and white in dark mode")
    func cortexBrainTracksMacOSAppearance() {
        #expect(StatusItemLabelDriver.brainColor(isDarkAppearance: false) == .black)
        #expect(StatusItemLabelDriver.brainColor(isDarkAppearance: true) == .white)
    }

    @Test("running cat exposes a complete non-static stride")
    func runningCatExposesCompleteNonStaticStride() throws {
        #expect(RunningCatRenderer.frameCount == 8)
        let frames = (0..<RunningCatRenderer.frameCount).map {
            RunningCatRenderer.image(frame: $0, color: .systemGreen)
        }
        let rendered = try frames.map { try #require($0.tiffRepresentation) }
        #expect(Set(rendered).count > 1)
        #expect(frames.allSatisfy { $0.size == NSSize(width: 16, height: 16) })
    }
}
