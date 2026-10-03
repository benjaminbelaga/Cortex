import Foundation
import Domain

/// Writes the credential-free account roster (Contract A, v7.2) to
/// `~/.claude/state/llm-router/cortex-accounts.json` after each probe cycle.
///
/// SECURITY INVARIANT: the payload is built from `OverviewBuilder.build`, whose
/// `ProviderSnapshot` rows carry quota windows and identity labels only. The
/// only settings reference read is the non-secret immutable catalogAccountId;
/// no credential or credential reference reaches the exported payload.
public final class CortexAccountsExporter: CortexAccountsExporting, @unchecked Sendable {

    private let outputURL: URL
    private let preferredModelsProvider: @Sendable () -> [String: [String]]
    private let clock: @Sendable () -> Date
    private let catalogIdsProvider: @Sendable () -> [String: String]
    /// Serializes writes and drops a stale one so two overlapping exports can
    /// never publish out of order (Cortex §3).
    private let serializer = PublicationSerializer()
    /// Monotonic generation, bumped on each export and stamped into the payload.
    /// Main-actor isolated: `exportAfterRefresh` is the only writer.
    @MainActor private var generation: UInt64 = 0
    /// The generation already stamped in the payload on disk, read exactly once
    /// per process (lazily, on the first export) so the sequence continues across
    /// restarts instead of restarting at 1. `nil` means "not read yet"; once
    /// seeded it is kept for the process lifetime, so an export never re-reads
    /// the file it is about to overwrite (the value is monotonic by construction).
    @MainActor private var diskGeneration: UInt64?

    public init(
        outputURL: URL = CortexAccountsExporter.defaultOutputURL(),
        preferredModelsProvider: @escaping @Sendable () -> [String: [String]] = {
            CortexAccountsExporter.effectivePreferences(
                providerPreferred: JSONSettingsRepository.shared.providerPreferredModel(),
                legacy: JSONSettingsRepository.shared.preferredModels()
            )
        },
        clock: @escaping @Sendable () -> Date = Date.init,
        catalogIdsProvider: @escaping @Sendable () -> [String: String] = {
            var ids: [String: String] = [:]
            for provider in RouterProviderIdMap.routerByCortex.keys {
                for account in JSONSettingsRepository.shared.accounts(forProvider: provider) {
                    if let catalogId = account.probeConfig["catalogAccountId"] {
                        ids["\(provider)|\(account.accountId)"] = catalogId
                    }
                }
            }
            return ids
        }
    ) {
        self.outputURL = outputURL
        self.preferredModelsProvider = preferredModelsProvider
        self.clock = clock
        self.catalogIdsProvider = catalogIdsProvider
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
        // Seed the counter from the payload already on disk exactly once,
        // lazily, on the main actor: `cortex-accounts.json` is a small file and
        // this touches it a single time per process (never again, so an export
        // never re-reads the file it is about to overwrite). The detached write
        // below begins only after this read returns, so the seeded value is
        // always the pre-overwrite generation. If it were moved into the
        // detached task the value would have to be threaded back onto the main
        // actor anyway; the one small non-throwing read is cheaper on the main
        // actor than that hop.
        if diskGeneration == nil {
            diskGeneration = Self.lastPublishedGeneration(at: outputURL)
        }
        // Continue above BOTH the on-disk generation (across process restarts)
        // and the in-process counter (stale-drop ordering), so a fresh process
        // continues at e.g. 38 over a file that already says 37 — never at 1.
        generation = max(diskGeneration ?? 0, generation) &+ 1
        let generation = self.generation
        let payload = Self.payload(
            rows: rows,
            preferredModels: preferredModelsProvider(),
            now: clock(),
            catalogIds: catalogIdsProvider(),
            routerProviderIds: Set(providers.filter { $0 is RouterBackedProvider }.map(\.id)),
            generation: Int(generation)
        )
        let url = outputURL
        let serializer = serializer
        // File I/O off the main actor; the payload is a plain value type. The
        // serializer guarantees only the newest generation reaches disk.
        Task.detached(priority: .utility) {
            guard let data = try? Self.encode(payload) else { return }
            try? await serializer.publish(data: data, generation: generation, to: url)
        }
    }

    // MARK: - Pure projection (testable)

    /// Builds the Contract A payload from overview rows. Rows whose provider is
    /// not in the router mapping are dropped.
    nonisolated static func payload(
        rows: [ProviderSnapshot],
        preferredModels: [String: [String]],
        now: Date,
        catalogIds: [String: String] = [:],
        routerProviderIds: Set<String> = [],
        generation: Int = 0
    ) -> CortexAccountsPayload {
        let accounts: [CortexAccountEntry] = rows.compactMap { row in
            guard let routerProvider = routerProviderByCortexId[row.providerId] else { return nil }
            return CortexAccountEntry(
                routerProvider: routerProvider,
                cortexProvider: row.providerId,
                accountId: catalogIds[row.id] ?? accountId(from: row),
                label: row.accountLabel ?? row.providerName,
                windows: row.windows.map(window(from:)),
                authState: authState(for: row),
                status: status(for: row),
                preferredFamilies: preferredFamilies(for: row, map: preferredModels),
                measuredAt: row.capturedAt.map(iso),
                source: routerProviderIds.contains(row.providerId) ? "router" : "native"
            )
        }
        return CortexAccountsPayload(
            schemaVersion: 1,
            generatedAt: iso(now),
            generation: generation,
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

    /// The `generation` already stamped in an existing payload, used to seed the
    /// counter on the first export of a fresh process so the sequence continues
    /// across restarts (an old collection never replaces a newer one — at the
    /// file level too, not only inside one process).
    ///
    /// Best-effort and non-throwing: an absent, unreadable, or malformed file
    /// reads as 0 (no generation known). It never invents a value and never
    /// throws — a consumer that finds garbage on disk just gets a clean start.
    nonisolated static func lastPublishedGeneration(at url: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: url),
              let probe = try? JSONDecoder().decode(GenerationProbe.self, from: data),
              let generation = probe.generation,
              generation > 0
        else { return 0 }
        return UInt64(generation)
    }

    /// Decodes only `generation`, so it tolerates any rest of the contract
    /// drifting between versions (unknown/renamed fields are ignored).
    private struct GenerationProbe: Decodable {
        let generation: Int?
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
    /// Monotonic publication generation (Cortex §3). Lets a consumer detect an
    /// out-of-order publish, and pairs with the serializer's stale-write drop.
    public let generation: Int?
    public let accounts: [CortexAccountEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case generation
        case accounts
    }
}

/// Serializes publication so an older export can never overwrite a newer one:
/// a write whose generation is not newer than the last published one is dropped
/// (Cortex §3 — "un export plus ancien ne remplace pas un plus récent").
actor PublicationSerializer {
    private var lastPublished: UInt64 = 0

    func publish(data: Data, generation: UInt64, to url: URL) throws {
        guard generation > lastPublished else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        lastPublished = generation
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
    public let measuredAt: String?
    public let source: String

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
        case source
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
