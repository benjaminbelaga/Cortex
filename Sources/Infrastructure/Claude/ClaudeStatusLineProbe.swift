import Foundation
import Domain

/// Passive probe backed by `StatusLineObserver`. Implements `UsageProbe` so
/// it can plug into the existing AIProvider plumbing as a fallback for the
/// CLI-based `ClaudeUsageProbe` (which scrapes `claude /usage` in a TTY).
///
/// The probe is **opt-in**: `isAvailable()` returns false unless the
/// `claudeStatusLineAdapterEnabled` setting is on AND the observer has at
/// least one observation for the bound configDir. When `probe()` is invoked
/// without a usable observation, it throws `ProbeError.executionFailed` —
/// the caller is expected to fall back to the CLI probe rather than to
/// fabricate a snapshot.
public final class ClaudeStatusLineProbe: UsageProbe, @unchecked Sendable {
    private let configDir: String
    private let observer: StatusLineObserver
    private let settingsProvider: () -> Bool

    public init(
        configDir: String,
        observer: StatusLineObserver = StatusLineObserver.shared,
        settingsProvider: @escaping () -> Bool = { false }
    ) {
        self.configDir = configDir
        self.observer = observer
        self.settingsProvider = settingsProvider
    }

    public func isAvailable() async -> Bool {
        guard settingsProvider() else { return false }
        return observer.latestObservation(for: configDir) != nil
    }

    public func probe() async throws -> UsageSnapshot {
        guard settingsProvider() else {
            throw ProbeError.executionFailed("Claude status-line adapter is disabled")
        }
        guard let observation = observer.latestObservation(for: configDir) else {
            throw ProbeError.executionFailed("No status-line observation available yet")
        }
        let quotas = observation.windows.compactMap { window -> UsageQuota? in
            guard let percent = window.percentRemaining else { return nil }
            let quotaType: QuotaType
            switch window.id {
            case .fiveHour: quotaType = .session
            case .sevenDay: quotaType = .weekly
            case .raw(let name): quotaType = .modelSpecific(name)
            }
            return UsageQuota(
                percentRemaining: percent,
                quotaType: quotaType,
                providerId: "claude",
                resetsAt: window.resetsAt,
                resetText: window.resetText
            )
        }
        return UsageSnapshot(
            providerId: "claude",
            quotas: quotas,
            capturedAt: observation.capturedAt,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil
        )
    }
}
