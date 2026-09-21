import SwiftUI
import Domain
import Infrastructure

/// "Ce que j'utilise" card: live + 24h session counts per harness, the REAL
/// tmux session count, and the Claude lifecycle timeline (forks, compactions)
/// — Ben's ask, 2026-08-18 + 2026-08-24 (tmux truth).
struct SessionsCardView: View {
    let tracker: HarUsageTracker
    let sessionMonitor: SessionMonitor

    @Environment(\.appTheme) private var theme
    @State private var tmuxCount: Int?
    @State private var runtime: LLMRuntimeSnapshot?
    @State private var isExpanded = false
    @State private var settings = AppSettings.shared
    @State private var sessionsActivity = SessionsActivityModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Text("Sessions")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(theme.font(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Réduire l'activité" : "Afficher les détails d'activité")
                if let liveClaude = tracker.liveClaude {
                    Text("\(liveClaude) actives")
                        .font(theme.font(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .help("Processus Claude en cours d'exécution (source : Guardian) — ce n'est PAS le nombre de sessions tmux.")
                }
            }

            // The big number per harness is the 24h transcript count; only
            // Claude/Codex expose a live gauge. Labels made explicit so "32
            // actives" is no longer mistaken for tmux (Ben 2026-08-24).
            // Identity glyphs use the same BMP-safe alphabet as tmux:
            // ◆ (Claude), ◎ (Codex), K (Kimi), Q (Qwen), `tmux` for the
            // terminal sessions counter. The model abbreviation ("›M3",
            // "›S5", …) appears below the glyph when the LLMRuntimeInspector
            // surfaces a per-harness model id; otherwise the cell falls back
            // to the harness-only label. See
            // ~/repos/ClaudeBar/Sources/Domain/Provider/ModelAbbreviation.swift
            // and the same identity map in
            // ~/.tmux/scripts/agent-tmux-state.py (rules/81: one alphabet,
            // two surfaces).
            HStack(spacing: 0) {
                harnessCell("Claude", glyph: "◆", providerId: "claude",
                            live: tracker.liveClaude, day: tracker.counts24h?.claude)
                harnessCell("Codex", glyph: "◎", providerId: "codex",
                            live: tracker.liveCodex, day: tracker.counts24h?.codex)
                harnessCell("Kimi", glyph: "K", providerId: "kimi",
                            live: nil, day: tracker.counts24h?.kimi)
                harnessCell("Qwen", glyph: "Q", providerId: "qwen",
                            live: nil, day: tracker.counts24h?.qwen)
                harnessCell("tmux", glyph: "tmux", providerId: nil,
                            live: nil, day: tmuxCount, windowLabel: "sessions")
            }
            .task {
                // The tmux truth (default socket + configured extras),
                // cached 30 s — distinct from transcript counts.
                tmuxCount = await TmuxSessionCounter.count(
                    socketNames: settings.tmuxSocketNames
                )
                runtime = await LLMRuntimeInspector.read()
            }
            .help("Nombre par outil = sessions ayant écrit un transcript sur les dernières 24h (un fichier .jsonl par session/dossier). Répartition par backend (Claude-GLM, Claude-MiniMax…) + usage local : roadmap.")

            // OpenCode : sessions RÉELLEMENT ouvertes (fichier de liveness + PID
            // vérifié) et historique local, backend observé compris. Rien n'est
            // déduit : une session sans processus reste « récente », jamais
            // « fermée » (plan Cortex modulaire, règle d'honnêteté).
            if showsOpenCodeSessions {
                Divider().overlay(theme.glassBorder)
                openCodeSection
                    .task { await activityRefreshLoop() }
            }

            // Command Code & cmux : mêmes états, même cadence, même honnêteté que
            // la section OpenCode — une source absente le dit, elle ne compte
            // jamais zéro par défaut.
            if showsCommandCodeSessions {
                Divider().overlay(theme.glassBorder)
                activitySection(
                    toolId: "commandcode",
                    label: "Command Code",
                    icon: "chevron.left.forwardslash.chevron.right",
                    help: "Ouvertes = traceur vivant (aucun aujourd'hui) · en travail = transcript touché < 2 min · sur 24 h = historique local. Une activité trop ancienne reste « inconnue », jamais « fermée »."
                )
                .task { await activityRefreshLoop() }
            }

            if showsCmuxSessions {
                Divider().overlay(theme.glassBorder)
                activitySection(
                    toolId: "cmux",
                    label: "cmux",
                    icon: "rectangle.split.3x1",
                    help: "Panes terminaux présents dans l'état de session cmux. Ouvert = état encore frais ; un état trop vieux pour prouver la vie reste « inconnu », jamais « fermé »."
                )
                .task { await activityRefreshLoop() }
            }

            if isExpanded, let runtime {
                Divider().overlay(theme.glassBorder)
                HStack(spacing: 12) {
                    runtimeMetric("missions", value: runtime.activeMissions, icon: "flag.checkered")
                    runtimeMetric("hooks", value: runtime.configuredHooks, icon: "point.topleft.down.to.point.bottomright.curvepath")
                    runtimeMetric("skills", value: runtime.sharedSkills, icon: "books.vertical")
                    Spacer(minLength: 0)
                    Text("SSOT partagé")
                        .font(theme.font(size: 8, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                .help("Missions actives : agentctl · hooks : ~/.claude/settings.json · skills : ~/.claude/skills. Cortex lit ces autorités sans dupliquer leur état.")
            }

            if isExpanded, !sessionMonitor.recentNotableEvents.isEmpty {
                Divider().overlay(theme.glassBorder)
                ForEach(Array(sessionMonitor.recentNotableEvents.prefix(6).enumerated()), id: \.offset) { _, event in
                    timelineRow(event)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.glassBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.glassBorder, lineWidth: 1)
        )
    }

    // MARK: - Cells

    private func harnessCell(
        _ name: String,
        glyph: String,
        providerId: String?,
        live: Int?,
        day: Int?,
        windowLabel: String = "24h"
    ) -> some View {
        // Render the harness identity as a single Text line (e.g. "◆" or
        // "K" or the literal "tmux") so the cell matches the same alphabet
        // tmux uses in IDENTITY_GLYPH (BMP Plane 0, no Nerd Font PUA per
        // anthropics/claude-code#49270). When the LLMRuntimeInspector later
        // exposes per-harness model ids, look up
        // ProviderVisualIdentityLookup.abbreviation(for: modelId) and prepend
        // "›abbr" after the glyph. For now the abbreviation slot is reserved
        // but unused (no model id source yet).
        let abbr: String? = nil
        return VStack(spacing: 3) {
            HStack(spacing: 1) {
                Text(glyph)
                    .font(theme.font(size: 14, weight: .semibold))
                    .foregroundStyle(day.map { _ in theme.textPrimary } ?? theme.textTertiary)
                if let abbr {
                    Text("›\(abbr)")
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Text(name)
                .font(theme.font(size: 9))
                .foregroundStyle(theme.textTertiary)
            Text(windowLabel)
                .font(theme.font(size: 8))
                .foregroundStyle(theme.textTertiary.opacity(0.6))
            Text(day.map(String.init) ?? "·")
                .font(theme.font(size: 13, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - OpenCode (sessions réelles)

    /// Le module sessions et l'outil OpenCode sont-ils affichables ? « Masquer »
    /// gagne toujours ; « automatique » ne cache pas une section qui a des
    /// chiffres à montrer.
    private var showsOpenCodeSessions: Bool {
        guard settings.moduleVisibility(.sessions) != .hidden else { return false }
        return settings.moduleVisibility(id: "opencode-go", fallback: .automatic) != .hidden
    }

    private var showsCommandCodeSessions: Bool {
        guard settings.moduleVisibility(.sessions) != .hidden else { return false }
        return settings.moduleVisibility(id: "commandcode", fallback: .automatic) != .hidden
    }

    private var showsCmuxSessions: Bool {
        guard settings.moduleVisibility(.sessions) != .hidden else { return false }
        return settings.moduleVisibility(id: "cmux", fallback: .automatic) != .hidden
    }

    /// Cadence partagée des sources d'activité : 30 s, jamais bloquante.
    private func activityRefreshLoop() async {
        await sessionsActivity.refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            await sessionsActivity.refresh()
        }
    }

    /// Section compacte par source d'activité (Command Code, cmux) : mêmes états
    /// (ouvert / en travail / récent) et même règle d'honnêteté que la section
    /// OpenCode — la ligne d'échec reste visible, jamais un faux zéro.
    @ViewBuilder
    private func activitySection(toolId: String, label: String, icon: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.textSecondary)
                Text(label)
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                Text(activitySummary(toolId: toolId))
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
                    .help(help)
            }

            if let failure = sessionsActivity.failure(for: toolId) {
                Text(failure)
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.statusColor(for: .warning))
                    .lineLimit(2)
            }

            if isExpanded {
                ForEach(
                    Array(sessionsActivity.observations(for: toolId).prefix(6)),
                    id: \.identifier
                ) { observation in
                    openCodeRow(observation)
                }
            }
        }
    }

    private func activitySummary(toolId: String) -> String {
        let counts = sessionsActivity.counts(for: toolId)
        var parts = [
            "\(counts.open) ouvertes",
            "\(counts.working) en travail",
            "\(counts.recent) sur 24 h",
        ]
        if counts.subagents > 0 { parts.append("+\(counts.subagents) sous-agents") }
        return parts.joined(separator: " · ")
    }

    private var openCodeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.textSecondary)
                Text("OpenCode")
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                Text(openCodeSummary)
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
                    .help("Ouvertes = processus vivant vérifié · en travail = activité < 2 min · sur 24 h = historique local. Les sous-agents sont comptés à part.")
            }

            if let failure = sessionsActivity.failure(for: "opencode-go") {
                Text(failure)
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.statusColor(for: .warning))
                    .lineLimit(2)
            }

            if isExpanded {
                ForEach(
                    Array(sessionsActivity.observations(for: "opencode-go").prefix(6)),
                    id: \.identifier
                ) { observation in
                    openCodeRow(observation)
                }
            }
        }
    }

    private var openCodeSummary: String {
        let counts = sessionsActivity.counts(for: "opencode-go")
        var parts = [
            "\(counts.open) ouvertes",
            "\(counts.working) en travail",
            "\(counts.recent) sur 24 h",
        ]
        if counts.subagents > 0 { parts.append("+\(counts.subagents) sous-agents") }
        return parts.joined(separator: " · ")
    }

    private func openCodeRow(_ observation: SessionObservation) -> some View {
        HStack(spacing: 5) {
            Image(systemName: Self.activitySymbol(observation.activity))
                .font(theme.font(size: 8))
                .foregroundStyle(theme.textTertiary)
            Text(observation.title ?? observation.directory ?? observation.id)
                .font(theme.font(size: 9, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let model = observation.model {
                Text(model)
                    .font(theme.font(size: 8))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let updatedAt = observation.updatedAt {
                Text(updatedAt, style: .relative)
                    .font(theme.font(size: 8))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private static func activitySymbol(_ activity: SessionObservation.Activity) -> String {
        switch activity {
        case .open: "circle.fill"
        case .working: "circle.dotted"
        case .recent: "clock"
        case .unknown: "questionmark.circle"
        }
    }

    // MARK: - Timeline

    private func runtimeMetric(_ label: String, value: Int?, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(theme.font(size: 8))
            Text(value.map(String.init) ?? "—")
                .font(theme.font(size: 9, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(theme.font(size: 8))
        }
        .foregroundStyle(theme.textTertiary)
    }

    // MARK: - Timeline

    @ViewBuilder
    private func timelineRow(_ event: SessionEvent) -> some View {
        let presentation: (label: String, icon: String) = switch event.eventName {
        case .preCompact:
            ("Compaction…", "arrow.down.circle")
        case .postCompact:
            ("Compaction terminée", "checkmark.circle")
        case .sessionStart where event.source == "fork":
            ("Session forked", "arrow.triangle.branch")
        default:
            (event.eventName.rawValue, "circle")
        }
        HStack(spacing: 6) {
            Image(systemName: presentation.icon)
                .font(theme.font(size: 9))
                .foregroundStyle(theme.textTertiary)
            Text(presentation.label)
                .font(theme.font(size: 10, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(event.receivedAt, style: .relative)
                .font(theme.font(size: 9))
                .foregroundStyle(theme.textTertiary)
        }
    }
}
