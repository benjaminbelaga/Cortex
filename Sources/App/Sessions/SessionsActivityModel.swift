import Foundation
import Observation
import Domain
import Infrastructure

/// Agrège les sources de sessions (transcripts Claude/Codex/Kimi/Qwen, base
/// locale OpenCode, transcripts Command Code, état de workspaces cmux) en
/// observations par outil, avec l'état de collecte de chacune. Une source en
/// échec reste visible : jamais un faux zéro.
@MainActor
@Observable
public final class SessionsActivityModel {

    /// Dernier rapport par outil (observations + échec éventuel).
    public private(set) var reports: [String: SessionSourceReport] = [:]
    /// Horodatage de la dernière collecte, pour l'affichage d'âge.
    public private(set) var collectedAt: Date?
    public private(set) var isCollecting = false

    private let sources: [any SessionSource]

    public init(sources: [any SessionSource] = [
        OpenCodeSessionSource(),
        CommandCodeSessionSource(),
        CmuxSessionSource(),
    ]) {
        self.sources = sources
    }

    /// Collecte bornée de toutes les sources, en parallèle. Ne bloque jamais
    /// l'affichage : chaque source a son propre budget interne.
    public func refresh(limit: Int = 60, now: Date = Date()) async {
        guard !isCollecting else { return }
        isCollecting = true
        defer { isCollecting = false }

        let sources = self.sources
        let reports = await withTaskGroup(of: SessionSourceReport.self) { group in
            for source in sources {
                group.addTask { await source.collect(limit: limit, now: now) }
            }
            var collected: [SessionSourceReport] = []
            for await report in group { collected.append(report) }
            return collected
        }
        self.reports = Dictionary(uniqueKeysWithValues: reports.map { ($0.toolId, $0) })
        self.collectedAt = now
    }

    public func observations(for toolId: String) -> [SessionObservation] {
        reports[toolId]?.observations ?? []
    }

    public func counts(for toolId: String) -> SessionCounts {
        SessionCounts.from(observations(for: toolId))
    }

    public func failure(for toolId: String) -> String? {
        reports[toolId]?.failure
    }
}
