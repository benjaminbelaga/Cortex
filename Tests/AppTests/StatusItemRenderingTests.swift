import AppKit
import Foundation
import SwiftUI
import Testing
import Infrastructure
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

    @Test("an unknown measurement renders neutrally, never the healthy green")
    func unknownStatusRendersNeutral() {
        // The menu-bar "—" placeholder and any other missing-measurement badge
        // must use the neutral tertiary colour, not the all-good green.
        let theme = ThemeRegistry.shared.resolveTheme(for: "dark", systemColorScheme: .dark)
        #expect(theme.statusColor(for: .unknown) == theme.textTertiary)
        #expect(theme.statusColor(for: .unknown) != theme.statusColor(for: .healthy))
    }

    @Test("a provider with no measurement paints a neutral menu-bar fallback, never green")
    func noMeasurementFallbackIsNeutral() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Provider that has never reported: no snapshot, no error.
        let provider = SilentProvider(id: "claude", name: "Claude")
        let monitor = QuotaMonitor(
            providers: AIProviders(providers: [provider]),
            clock: DriverTestClock()
        )
        let settings = AppSettings(
            repository: JSONSettingsRepository(
                store: JSONSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
            )
        )
        let driver = StatusItemLabelDriver(
            monitor: monitor,
            settings: settings,
            sessionMonitor: SessionMonitor()
        )

        // No snapshot → the icon-only fallback must be the first-class "no
        // measurement" status, rendered in the neutral tertiary colour — never
        // the healthy green, which would assert a reading that does not exist.
        let status = driver.effectiveSelectedProviderStatus
        #expect(status == .unknown)
        #expect(status != .healthy)

        let theme = ThemeRegistry.shared.resolveTheme(for: "dark", systemColorScheme: .dark)
        #expect(theme.statusColor(for: status) == theme.textTertiary)
        #expect(theme.statusColor(for: status) != theme.statusColor(for: .healthy))
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

    // MARK: - Helpers

    /// A provider that has never been probed: no snapshot, no error.
    private final class SilentProvider: AIProvider {
        let id: String
        let name: String
        var isEnabled = true
        var isSyncing = false
        var snapshot: UsageSnapshot?
        var lastError: Error?
        var cliCommand: String { id }
        var dashboardURL: URL? { nil }

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        func isAvailable() async -> Bool { true }
        func refresh() async throws -> UsageSnapshot {
            UsageSnapshot(providerId: id, quotas: [], capturedAt: Date())
        }
    }

    private struct DriverTestClock: Clock {
        func sleep(for duration: Duration) async throws {}
        func sleep(nanoseconds: UInt64) async throws {}
    }
}
