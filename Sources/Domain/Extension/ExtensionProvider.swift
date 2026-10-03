import Foundation

/// An AIProvider backed by an extension manifest and script-based probes.
/// Each section has its own probe; refresh runs all probes and merges results.
@MainActor
@Observable
public final class ExtensionProvider: AIProvider {
    // MARK: - Identity

    public let id: String
    public let name: String
    public let cliCommand: String = ""
    public let dashboardURL: URL?
    public let statusPageURL: URL?

    /// The parsed extension manifest
    public let manifest: ExtensionManifest

    // MARK: - State

    public var isEnabled: Bool {
        didSet { settingsRepository.setEnabled(isEnabled, forProvider: id) }
    }

    public private(set) var isSyncing: Bool = false
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var lastError: Error?

    // MARK: - Dependencies

    /// Section-keyed probes (section.id → probe)
    private let probes: [String: any UsageProbe]
    private let settingsRepository: ProviderSettingsRepository

    // MARK: - Init

    public init(
        manifest: ExtensionManifest,
        probes: [String: any UsageProbe],
        settingsRepository: ProviderSettingsRepository
    ) {
        self.manifest = manifest
        self.id = "ext-\(manifest.id)"
        self.name = manifest.name
        self.dashboardURL = manifest.dashboardURL
        self.statusPageURL = manifest.statusPageURL
        self.probes = probes
        self.settingsRepository = settingsRepository
        self.isEnabled = settingsRepository.isEnabled(forProvider: "ext-\(manifest.id)")
    }

    // MARK: - AIProvider

    public func isAvailable() async -> Bool {
        for probe in probes.values {
            if await probe.isAvailable() {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        isSyncing = true
        defer { isSyncing = false }

        // Run all section probes concurrently
        let probeEntries = Array(probes)
        let outcome = await withTaskGroup(of: (String, Result<UsageSnapshot, Error>).self) { group in
            for (sectionId, probe) in probeEntries {
                group.addTask {
                    do {
                        let snapshot = try await probe.probe()
                        return (sectionId, .success(snapshot))
                    } catch {
                        return (sectionId, .failure(error))
                    }
                }
            }

            var collected: [(String, UsageSnapshot)] = []
            /// The first error the user can ACT on. A probe that cannot run
            /// because a required config field is unset must say so: collapsing
            /// it into `noData` hides the only message that would let the user
            /// fix it (honest states — see `ExtensionProbeError`).
            var actionable: ExtensionProbeError?
            for await (sectionId, result) in group {
                switch result {
                case .success(let snapshot):
                    collected.append((sectionId, snapshot))
                case .failure(let error):
                    if let probeError = error as? ExtensionProbeError,
                       case .unconfigured = probeError {
                        actionable = actionable ?? probeError
                    }
                }
            }
            return (collected, actionable)
        }

        let results = outcome.0

        guard !results.isEmpty else {
            let error: Error = outcome.1 ?? ProbeError.noData
            lastError = error
            throw error
        }

        let merged = mergeSnapshots(results.map(\.1))
        snapshot = merged
        lastError = nil
        return merged
    }

    // MARK: - Private

    private func mergeSnapshots(_ snapshots: [UsageSnapshot]) -> UsageSnapshot {
        var allQuotas: [UsageQuota] = []
        var costUsage: CostUsage?
        var dailyReport: DailyUsageReport?
        var metrics: [ExtensionMetric] = []

        for s in snapshots {
            allQuotas.append(contentsOf: s.quotas)
            if let cost = s.costUsage { costUsage = cost }
            if let daily = s.dailyUsageReport { dailyReport = daily }
            if let m = s.extensionMetrics { metrics.append(contentsOf: m) }
        }

        return UsageSnapshot(
            providerId: id,
            quotas: allQuotas,
            capturedAt: Date(),
            costUsage: costUsage,
            dailyUsageReport: dailyReport,
            extensionMetrics: metrics.isEmpty ? nil : metrics
        )
    }
}
