import Testing
import Foundation
import Domain
import Infrastructure
@testable import Cortex

/// Honesty tests for the exported `~/.claudebar/status.json` payload.
///
/// External widgets (BetterTouchTool / SwiftBar / Raycast) read this file. A
/// provider that was never probed — or whose probe returned no windows — has no
/// measurement, so it must export `"unknown"`, never a reassuring `"healthy"`
/// borrowed from a snapshot that does not exist. Genuinely healthy providers
/// must keep exporting `"healthy"`.
@Suite(.serialized)
@MainActor
struct StatusExportDriverTests {

    private struct TestClock: Clock {
        func sleep(for duration: Duration) async throws {}
        func sleep(nanoseconds: UInt64) async throws {}
    }

    /// Minimal provider whose snapshot is controlled by the test. A `nil`
    /// snapshot models "never probed".
    private final class StubProvider: AIProvider {
        let id: String
        let name: String
        var isEnabled = true
        var isSyncing = false
        var snapshot: UsageSnapshot?
        var lastError: Error?

        init(id: String, name: String, snapshot: UsageSnapshot?) {
            self.id = id
            self.name = name
            self.snapshot = snapshot
        }

        var cliCommand: String { id }
        var dashboardURL: URL? { nil }
        func isAvailable() async -> Bool { true }
        func refresh() async throws -> UsageSnapshot {
            snapshot ?? UsageSnapshot(providerId: id, quotas: [], capturedAt: Date())
        }
    }

    /// Builds a driver over a single Claude provider with the given snapshot,
    /// starts it (which writes the payload synchronously), and returns the
    /// decoded export. The temp directory is removed on the way out.
    private func exportedPayload(
        providerSnapshot: UsageSnapshot?,
        touchBarEnabled: Bool = true
    ) throws -> StatusExportDriver.ExportPayload {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("status.json")

        let provider = StubProvider(id: "claude", name: "Claude", snapshot: providerSnapshot)
        let monitor = QuotaMonitor(providers: AIProviders(providers: [provider]), clock: TestClock())
        let settings = AppSettings(
            repository: JSONSettingsRepository(
                store: JSONSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
            )
        )
        settings.touchBarEnabled = touchBarEnabled
        let driver = StatusExportDriver(monitor: monitor, settings: settings, fileURL: fileURL)
        driver.start()
        defer {
            driver.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        return try JSONDecoder().decode(
            StatusExportDriver.ExportPayload.self,
            from: Data(contentsOf: fileURL)
        )
    }

    @Test
    func `provider with no snapshot exports unknown not healthy`() throws {
        let payload = try exportedPayload(providerSnapshot: nil)

        #expect(payload.providers.count == 1)
        #expect(payload.providers.first?.id == "claude")
        #expect(payload.providers.first?.status == "unknown")
        #expect(payload.providers.first?.status != "healthy")
    }

    @Test
    func `provider with an empty snapshot exports unknown`() throws {
        let empty = UsageSnapshot(providerId: "claude", quotas: [], capturedAt: Date())
        let payload = try exportedPayload(providerSnapshot: empty)

        #expect(payload.providers.first?.status == "unknown")
        #expect(payload.providers.first?.status != "healthy")
    }

    @Test
    func `a genuinely healthy provider still exports healthy`() throws {
        let healthy = UsageSnapshot(
            providerId: "claude",
            quotas: [UsageQuota(percentRemaining: 90, quotaType: .session, providerId: "claude")],
            capturedAt: Date()
        )
        let payload = try exportedPayload(providerSnapshot: healthy)

        #expect(payload.providers.first?.status == "healthy")
    }

    @Test
    func `disabling the Touch Bar still exports the provider status`() throws {
        let healthy = UsageSnapshot(
            providerId: "claude",
            quotas: [UsageQuota(percentRemaining: 90, quotaType: .session, providerId: "claude")],
            capturedAt: Date()
        )
        let payload = try exportedPayload(providerSnapshot: healthy, touchBarEnabled: false)

        // The display switch still flips the published `enabled` hint (widgets
        // use it to hide)...
        #expect(payload.enabled == false)
        // ...but it no longer blanks the data contract: providers and the
        // status / menu-bar text are still described.
        #expect(payload.providers.count == 1)
        #expect(payload.providers.first?.status == "healthy")
        #expect(payload.status != "disabled")
        #expect(payload.menuBarText.isEmpty == false)
    }
}
