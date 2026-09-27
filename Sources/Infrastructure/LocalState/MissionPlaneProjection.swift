import Foundation

/// Read-only materialized view of the **mission control plane**.
///
/// Authority: `missiond` owns missions, leases, session bindings and receipts
/// (`yoyaku-brain-os/docs/ARCHITECTURE.md` — one owner per record, other systems
/// build materialized views). Cortex therefore only *reads*
/// `~/.yoyaku/brain/brain.db` plus the `receipts/` directory, and never writes
/// into the plane: progress authored elsewhere, displayed here.
///
/// Only steps the plane (or a receipt file) can actually prove are reported — a
/// mission with nothing but its creation row is `registered`, never "running".
public struct MissionProgress: Sendable, Equatable, Identifiable {
    /// Mission-level awareness (audit V2 §7) — derived, honest, and added to the
    /// proven-step chain below. `nil` when the caller did not ask for it, so the
    /// older call sites keep their exact behaviour.
    public let awareness: MissionAwareness.Awareness?
    public let isCapacityPressured: Bool

    public enum Step: String, Sendable, CaseIterable {
        case registered
        case leased
        case bound
        case terminalOpened

        public var label: String {
            switch self {
            case .registered: "enregistrée"
            case .leased: "bail"
            case .bound: "session liée"
            case .terminalOpened: "terminal ouvert"
            }
        }
    }

    public var id: String { missionId }

    public let missionId: String
    public let objective: String
    public let worktree: String?
    public let status: String
    public let phase: String?
    public let harness: String?
    /// Proven steps, in canonical order (`registered` first).
    public let steps: [Step]
    public let updatedAt: Date?
    public let receiptAt: Date?

    public var worktreeName: String? {
        worktree.map { ($0 as NSString).lastPathComponent }
    }

    public var isProven: Bool { !steps.isEmpty }
}

/// One row of the plane's `missions` table joined with its lease count and its
/// most recent session binding. Kept plain so the projection is testable without
/// a database.
public struct MissionPlaneRow: Sendable, Equatable {
    public let missionId: String
    public let objective: String
    public let worktree: String?
    public let status: String
    public let phase: String?
    public let runtime: String?
    public let leaseCount: Int
    public let updatedAt: String?

    public init(
        missionId: String,
        objective: String,
        worktree: String? = nil,
        status: String = "active",
        phase: String? = nil,
        runtime: String? = nil,
        leaseCount: Int = 0,
        updatedAt: String? = nil
    ) {
        self.missionId = missionId
        self.objective = objective
        self.worktree = worktree
        self.status = status
        self.phase = phase
        self.runtime = runtime
        self.leaseCount = leaseCount
        self.updatedAt = updatedAt
    }
}

public enum MissionPlaneReader {
    public static func databasePath(home: URL) -> String {
        home.appendingPathComponent(".yoyaku/brain/brain.db").path
    }

    public static func receiptsDirectory(home: URL) -> URL {
        home.appendingPathComponent(".yoyaku/brain/receipts", isDirectory: true)
    }

    /// `LIMIT`-bounded, newest first, active missions only. Any SQLite failure
    /// yields an empty projection — the plane being unreadable is not a reason to
    /// invent missions, and the caller renders its own "unknown" state.
    ///
    /// `capacityPressure` comes from Guardian (the authority on machine
    /// saturation); when the snapshot is stale or unreadable the caller passes
    /// `false`, so "waiting for capacity" is never claimed without a live basis.
    public static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            limit: Int = 20,
                            capacityPressure: Bool = false,
                            now: Date = Date()) -> [MissionProgress] {
        let sql = """
        SELECT m.mission_id, m.objective, m.repo_root, m.status, m.phase, m.updated_at,
               (SELECT COUNT(*) FROM leases l WHERE l.holder_mission_id = m.mission_id) AS lease_count,
               (SELECT b.runtime FROM session_bindings b
                 WHERE b.mission_id = m.mission_id
                 ORDER BY b.last_seen_at DESC LIMIT 1) AS runtime
        FROM missions m
        WHERE m.status = 'active'
        ORDER BY m.updated_at DESC
        LIMIT ?
        """
        let raw: [[String: Any]]
        do {
            // Reuses the shared read-only, bounded SQLite helper (same one the
            // OpenCode session source uses) rather than opening a second style.
            raw = try SQLiteReadOnly.rows(
                databasePath: databasePath(home: home),
                sql: sql,
                bindings: [.int(Int64(limit))],
                limit: limit
            )
        } catch {
            return []
        }
        let rows = raw.compactMap { row -> MissionPlaneRow? in
            guard let missionId = row["mission_id"] as? String else { return nil }
            return MissionPlaneRow(
                missionId: missionId,
                objective: (row["objective"] as? String) ?? "",
                worktree: row["repo_root"] as? String,
                status: (row["status"] as? String) ?? "active",
                phase: row["phase"] as? String,
                runtime: row["runtime"] as? String,
                leaseCount: Int(row["lease_count"] as? Int64 ?? 0),
                updatedAt: row["updated_at"] as? String
            )
        }
        return project(rows,
                       receipts: receipts(home: home),
                       capacityPressure: capacityPressure,
                       now: now)
    }

    /// Receipt files prove a terminal was opened for that mission. A file whose
    /// timestamp cannot be read still proves the step, with `nil` date.
    static func receipts(home: URL) -> [String: Date?] {
        let directory = receiptsDirectory(home: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return [:]
        }
        var found: [String: Date?] = [:]
        for name in names where name.hasSuffix(".json") {
            let missionId = String(name.dropLast(".json".count))
            guard missionId.hasPrefix("msn_") else { continue }
            let url = directory.appendingPathComponent(name)
            let raw = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
            // Key presence IS the evidence (a terminal was opened for that
            // mission); the timestamp is best-effort. Written as `.some(...)`
            // because `found[id] = optionalNil` would not insert at all — a
            // receipt with an unreadable date must still prove the step.
            found[missionId] = .some(raw?.ts.flatMap(LLMRouterSuggestionClient.parseTimestamp))
        }
        return found
    }

    /// Pure projection: the plane's rows plus receipt evidence become the proven
    /// chain. Shared with the tests so the rule lives in one place.
    ///
    /// `capacityPressure` is decided by the caller (Guardian is the authority on
    /// machine saturation) and `now` is injected so the derivation is testable
    /// without touching the clock.
    public static func project(_ rows: [MissionPlaneRow],
                               receipts: [String: Date?],
                               capacityPressure: Bool = false,
                               now: Date = Date()) -> [MissionProgress] {
        rows.map { row in
            var steps: [MissionProgress.Step] = [.registered]
            if row.leaseCount > 0 { steps.append(.leased) }
            if let runtime = row.runtime, !runtime.isEmpty { steps.append(.bound) }
            let receipt = receipts[row.missionId]
            if receipt != nil { steps.append(.terminalOpened) }
            let awareness = MissionAwareness.awareness(
                missionId: row.missionId,
                status: row.status,
                receiptAt: receipt ?? nil,
                runtime: row.runtime,
                capacityPressure: capacityPressure,
                now: now
            )
            return MissionProgress(
                awareness: awareness,
                isCapacityPressured: capacityPressure,
                missionId: row.missionId,
                objective: row.objective,
                worktree: row.worktree,
                status: row.status,
                phase: row.phase,
                harness: row.runtime,
                steps: steps,
                updatedAt: LLMRouterSuggestionClient.parseTimestamp(row.updatedAt),
                receiptAt: receipt ?? nil
            )
        }
    }

    private struct Receipt: Decodable {
        let missionId: String?
        let ts: String?

        enum CodingKeys: String, CodingKey {
            case missionId = "mission_id"
            case ts
        }
    }
}
