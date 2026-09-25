import Foundation
import Domain

/// Writes the credential-free account roster (Contract A, v7.2) to
/// `~/.claude/state/llm-router/cortex-accounts.json` after each probe cycle.
///
/// SECURITY INVARIANT: the payload is built from `OverviewBuilder.build`, whose
/// `ProviderSnapshot` rows carry quota windows and identity labels only — never
/// a `probeConfig` value. No field here reads a credential, so a secret can not
/// structurally reach the file. `CortexAccountsExporterTests` proves it.
public final class CortexAccountsExporter: CortexAccountsExporting, @unchecked Sendable {

    private let outputURL: URL
    private let preferredModelsProvider: @Sendable () -> [String: [String]]
    private let clock: @Sendable () -> Date

    public init(
        outputURL: URL = CortexAccountsExporter.defaultOutputURL(),
        preferredModelsProvider: @escaping @Sendable () -> [String: [String]] = {
            CortexAccountsExporter.effectivePreferences(
                providerPreferred: JSONSettingsRepository.shared.providerPreferredModel(),
                legacy: JSONSettingsRepository.shared.preferredModels()
            )
        },
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.outputURL = outputURL
        self.preferredModelsProvider = preferredModelsProvider
        self.clock = clock
    }

    public nonisolated static func defaultOutputURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/state/llm-router", isDirectory: true)
            .appendingPathComponent("cortex-accounts.json")
    }

    /// Cortex id → `router_provider` (Contract A §33) lives in
    /// `RouterProviderIdMap` (Domain), shared with the route_now card so the two
    /// directions can never drift. A provider absent from it is skipped — never
    /// guessed.
    nonisolated static var routerProviderByCortexId: [String: String] {
        RouterProviderIdMap.routerByCortex
    }

    @MainActor
    public func exportAfterRefresh(providers: [any AIProvider]) {
        let rows = OverviewBuilder.build(providers: providers)
        let payload = Self.payload(
            rows: rows,
            preferredModels: preferredModelsProvider(),
            now: clock()
        )
        let url = outputURL
        // File I/O off the main actor; the payload is a plain value type.
        Task.detached(priority: .utility) {
            try? Self.write(payload, to: url)
        }
    }

    // MARK: - Pure projection (testable)

    /// Builds the Contract A payload from overview rows. Rows whose provider is
    /// not in the router mapping are dropped.
    nonisolated static func payload(
        rows: [ProviderSnapshot],
        preferredModels: [String: [String]],
        now: Date
    ) -> CortexAccountsPayload {
        let accounts: [CortexAccountEntry] = rows.compactMap { row in
            guard let routerProvider = routerProviderByCortexId[row.providerId] else { return nil }
            return CortexAccountEntry(
                routerProvider: routerProvider,
                cortexProvider: row.providerId,
                accountId: accountId(from: row),
                label: row.accountLabel ?? row.providerName,
                windows: row.windows.map(window(from:)),
                authState: authState(for: row),
                status: status(for: row),
                preferredFamilies: preferredFamilies(for: row, map: preferredModels),
                measuredAt: iso(row.capturedAt ?? now)
            )
        }
        return CortexAccountsPayload(
            schemaVersion: 1,
            generatedAt: iso(now),
            accounts: accounts
        )
    }

    nonisolated static func encode(_ payload: CortexAccountsPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    nonisolated static func write(_ payload: CortexAccountsPayload, to url: URL) throws {
        let data = try encode(payload)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Field derivation

    nonisolated private static func accountId(from row: ProviderSnapshot) -> String {
        if let suffix = row.id.split(separator: "|", maxSplits: 1).last, row.id.contains("|") {
            return String(suffix)
        }
        return row.providerId
    }

    nonisolated private static func window(from window: WindowSnapshot) -> CortexWindow {
        CortexWindow(
            kind: kind(for: window),
            remainingPct: Int(min(max(window.percentRemaining, 0), 100).rounded()),
            resetsAt: window.resetsAt.map(iso),
            stale: window.isStale
        )
    }

    nonisolated private static func kind(for window: WindowSnapshot) -> String {
        switch window.scope {
        case .session: return "rolling"
        case .weekly: return "weekly"
        case .other:
            return window.title.lowercased().contains("month") ? "monthly" : "other"
        }
    }

    /// Contract A `auth_state` ∈ {ok, expired, error}.
    nonisolated private static func authState(for row: ProviderSnapshot) -> String {
        if row.errorClass == "auth_expired" { return "expired" }
        return row.authState == .reconnectRequired ? "error" : "ok"
    }

    /// Contract A `status` ∈ {healthy, depleted, reconnect, unknown}.
    nonisolated private static func status(for row: ProviderSnapshot) -> String {
        if row.needsReconnect { return "reconnect" }
        if row.windows.isEmpty { return "unknown" }
        if let binding = row.bindingRemaining, binding <= 0 { return "depleted" }
        return "healthy"
    }

    /// The families the brain receives, per key. The Settings provider-level
    /// pin (`app.providerPreferredModel`, one family) WINS over the legacy
    /// per-row multi-select (`app.preferredModels`): R35 — what Ben picks in
    /// Settings is what llm-router locks on, never a display-only preference.
    nonisolated public static func effectivePreferences(
        providerPreferred: [String: String],
        legacy: [String: [String]]
    ) -> [String: [String]] {
        var merged = legacy
        for (providerId, family) in providerPreferred where !family.isEmpty {
            merged[providerId] = [family]
        }
        return merged
    }

    /// Provider-level key first (the pin is per provider, bible R12), then the
    /// legacy per-row key so older choices keep flowing until they are cleared.
    nonisolated private static func preferredFamilies(
        for row: ProviderSnapshot,
        map: [String: [String]]
    ) -> [String] {
        let ids = map[row.providerId] ?? map[row.id] ?? []
        return ModelFamily.families(from: ids).map(\.rawValue)
    }

    nonisolated private static func iso(_ date: Date) -> String {
        date.ISO8601Format()
    }
}

// MARK: - Contract A payload (credential-free)

public struct CortexAccountsPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let accounts: [CortexAccountEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case accounts
    }
}

public struct CortexAccountEntry: Codable, Equatable, Sendable {
    public let routerProvider: String
    public let cortexProvider: String
    public let accountId: String
    public let label: String
    public let windows: [CortexWindow]
    public let authState: String
    public let status: String
    public let preferredFamilies: [String]
    public let measuredAt: String

    enum CodingKeys: String, CodingKey {
        case routerProvider = "router_provider"
        case cortexProvider = "cortex_provider"
        case accountId = "account_id"
        case label
        case windows
        case authState = "auth_state"
        case status
        case preferredFamilies = "preferred_families"
        case measuredAt = "measured_at"
    }
}

public struct CortexWindow: Codable, Equatable, Sendable {
    public let kind: String
    public let remainingPct: Int
    public let resetsAt: String?
    public let stale: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case remainingPct = "remaining_pct"
        case resetsAt = "resets_at"
        case stale
    }
}
