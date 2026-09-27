import Foundation
import Domain

/// Read-only awareness layer for the **mission control plane** (audit V2 §7).
///
/// Guardian already reports machine facts (RAM, swap, load, processes). This
/// type adds the *mission* dimension: what the plane can honestly prove about a
/// mission, and what is merely suspicious.
///
/// Doctrine applied here (audit V2 §7):
/// - **An absence of output is not proof of a stall.** A long compile, download,
///   reasoning turn or tool run is legitimate. So there is no `STALLED` verdict:
///   only a `stalledSuspect` *suspicion*, raised from several signals and an
///   age that depends on the operation, meant to prompt a bounded look — never a
///   kill. Cortex never stops a writing process.
/// - **Deterministic route**: when the domain can decide without a model, it
///   does. `suspicionThreshold` returns the window; no LLM is asked.
public enum MissionAwareness {

    /// A suspicion window, deliberately generous.
    ///
    /// Calibrated against a measured value, not a guess: `install-local.sh`
    /// (build + codesign + install + relaunch) took **~151 s** on
    /// 2026-09-27. A legitimate command may therefore be silent for minutes, so
    /// the window is set well above that — flagging "suspect" is a hint to look,
    /// and a hint that fires during every normal rebuild is noise, not signal.
    public static let suspicionThreshold: TimeInterval = 900

    /// A structured, honest awareness line for one mission.
    ///
    /// The four states below are the ones Cortex can *prove* or *suspect*. The
    /// audit's fuller vocabulary (`WAITING_TOOL`, `VERIFY_PENDING`,
    /// `COMPLETED_VERIFIED`, …) is intentionally absent: no source plays the
    /// verification role yet, and inventing a state nothing can produce would be
    /// exactly the "reassuring zero" the audit forbids (C9).
    public struct Awareness: Sendable, Equatable {
        public let missionId: String
        public let state: MissionRuntimeState
        /// Seconds since the launch receipt — only meaningful (and only
        /// populated) when the mission was actually launched.
        public let sinceLaunch: TimeInterval?
        /// Plain-language reason, shown to the user. Never a claim the data
        /// cannot support.
        public let detail: String

        public init(missionId: String,
                    state: MissionRuntimeState,
                    sinceLaunch: TimeInterval? = nil,
                    detail: String) {
            self.missionId = missionId
            self.state = state
            self.sinceLaunch = sinceLaunch
            self.detail = detail
        }
    }

    /// Derive the awareness line. Pure and total — no clock is read here, the
    /// caller passes `now`, which is what makes it testable without fixtures on
    /// disk.
    ///
    /// - `registered` + no receipt → the mission exists but nothing launched it.
    /// - receipt at `t≤0s` → `processStarted`: the launch was *just* handed to
    ///   the terminal; it is the honest ceiling of what a receipt proves.
    /// - receipt older than the suspicion window → `stalledSuspect`, together
    ///   with the measured age. It never says "stuck".
    /// - receipt inside the window, capacity already saturated → `waitingCapacity`:
    ///   honest *only* because the harness is genuinely at its limit.
    /// - otherwise → `running`.
    public static func awareness(
        missionId: String,
        status: String,
        receiptAt: Date?,
        runtime: String?,
        capacityPressure: Bool,
        now: Date
    ) -> Awareness {
        // Terminal missions are statements about the plane, not progress.
        if status != "active" {
            return Awareness(
                missionId: missionId,
                state: .terminal(status),
                detail: "Mission \(status) — elle ne progresse plus."
            )
        }

        guard let receiptAt else {
            return Awareness(
                missionId: missionId,
                state: .registered,
                detail: "Enregistrée, aucun lancement prouvé."
            )
        }

        let elapsed = now.timeIntervalSince(receiptAt)
        let harnessName = runtime.flatMap { $0.isEmpty ? nil : $0 } ?? "inconnu"

        // Clock skew or a receipt written "now": the launch is in flight.
        if elapsed <= 0 {
            return Awareness(
                missionId: missionId,
                state: .processStarted,
                sinceLaunch: elapsed,
                detail: "Lancement confié au terminal à l'instant (\(harnessName))."
            )
        }

        if elapsed >= suspicionThreshold {
            return Awareness(
                missionId: missionId,
                state: .stalledSuspect,
                sinceLaunch: elapsed,
                detail: "Aucune preuve de progrès depuis \(Self.duration(elapsed)) — "
                    + "à vérifier, cela peut être une compilation ou un outil long."
            )
        }

        if capacityPressure {
            return Awareness(
                missionId: missionId,
                state: .waitingCapacity,
                sinceLaunch: elapsed,
                detail: "Lancée il y a \(Self.duration(elapsed)) (\(harnessName)) mais "
                    + "la machine est saturée : l'attente est probablement la capacité."
            )
        }

        return Awareness(
            missionId: missionId,
            state: .running,
            sinceLaunch: elapsed,
            detail: "Active depuis \(Self.duration(elapsed)) (\(harnessName))."
        )
    }

    /// Compact, human duration — deterministic, no Foundation formatter (whose
    /// output depends on the locale and would make tests flaky).
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 { return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min" }
        let days = hours / 24
        let restHours = hours % 24
        return "\(days) j \(restHours) h"
    }

    /// Is the machine genuinely saturated? Guardian is the authority: a stale or
    /// missing snapshot answers `false`, because claiming "waiting for capacity"
    /// on old data is worse than saying nothing.
    ///
    /// Thresholds mirror the ones the SwiftBar plugin used, so the two surfaces
    /// agree on what "pressure" means (rule 81: one alphabet, two surfaces).
    public static func capacityPressured(_ snapshot: GuardianSnapshot?) -> Bool {
        guard let snapshot, !snapshot.isStale else { return false }
        let m = snapshot.metrics
        if snapshot.findings.contains(where: { $0.rule == "load_high" }) { return true }
        if let load = m.load1PerCore, load >= 6 { return true }
        if let swap = m.swapUsedPct, swap >= 85 { return true }
        return false
    }
}

/// The mission-level states Cortex can prove or honestly suspect (audit V2 §7).
///
/// Deliberately smaller than the audit's full vocabulary. Each case here has a
/// real source behind it today; the rest stay unimplemented until a source can
/// produce them (see `docs/features/mission-progress.md`).
public enum MissionRuntimeState: Sendable, Equatable {
    /// Creation row only — nothing launched it.
    case registered
    /// A launch receipt exists; the terminal received it moments ago.
    case processStarted
    /// Receipt + capacity saturated: the mission is probably waiting for slots.
    case waitingCapacity
    /// Receipt + recent activity: nothing to report.
    case running
    /// Receipt, then a long silence. A suspicion, never a verdict.
    case stalledSuspect
    /// The plane itself says the mission ended (`complete`/`blocked`/…).
    case terminal(String)

    public var label: String {
        switch self {
        case .registered: "enregistrée"
        case .processStarted: "lancée"
        case .waitingCapacity: "attente capacité"
        case .running: "en cours"
        case .stalledSuspect: "suspicion d'arrêt"
        case .terminal(let status): status
        }
    }
}
