import SwiftUI
import Domain
import Infrastructure

/// "Failover chain" — the live OpenCode → Ollama failover order, read from
/// the files the opencode plugins actually write. Cortex only displays and
/// offers two minimal actions (reactivate a benched key, flip the Ollama
/// switch); routing stays owned by the plugins' SSOT (bible §15/§16).
///
/// Mounted in the reset sheet for `opencode-go` / `ollama`, replacing the
/// static FeaturePane line. Refreshes on a 30 s cadence, like the session card.
struct FailoverChainCard: View {
    @Environment(\.appTheme) private var theme
    @State private var state: FailoverChainState = .empty

    private let reader = FailoverChainReader()
    private let store = FailoverChainStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if state.slots.isEmpty {
                Text("No failover pool declared.")
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.textTertiary)
            } else {
                poolSection("OpenCode Go", slots: state.goSlots, pool: .go,
                            serving: state.servingGo)
                poolSection("Ollama Cloud (secours)", slots: state.ollamaSlots, pool: .ollama,
                            serving: state.ollamaSlots.first { !$0.isQuarantined })
                ollamaSwitch
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.glassBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.glassBorder, lineWidth: 1))
        .task { await refreshLoop() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textSecondary)
            Text("Failover chain")
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if let serving = state.servingGo {
                Text("sert : \(serving.label)")
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.statusColor(for: .healthy))
            }
        }
    }

    private func poolSection(_ title: String, slots: [FailoverChainState.Slot],
                             pool: FailoverChainState.Pool,
                             serving: FailoverChainState.Slot?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(theme.font(size: 10, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            ForEach(slots) { slot in
                HStack(spacing: 6) {
                    Circle().fill(badgeColor(slot)).frame(width: 7, height: 7)
                    Text(slot.label)
                        .font(theme.font(size: 11))
                        .foregroundStyle(theme.textSecondary)
                    if slot.id == serving?.id {
                        Text("lead")
                            .font(theme.font(size: 9, weight: .semibold))
                            .foregroundStyle(theme.statusColor(for: .healthy))
                    }
                    Spacer()
                    if case .quarantined(let until) = slot.status {
                        Text(countdown(to: until))
                            .font(theme.font(size: 9))
                            .foregroundStyle(theme.statusColor(for: .warning))
                            .monospacedDigit()
                        Button("Re-enable") { reactivate(slot, pool: pool) }
                            .buttonStyle(.plain)
                            .font(theme.font(size: 9, weight: .semibold))
                            .foregroundStyle(theme.accentPrimary)
                            .help("Remove quarantine from “\(slot.label)”")
                    }
                }
            }
        }
    }

    private var ollamaSwitch: some View {
        HStack(spacing: 6) {
            Image(systemName: state.ollamaArmed ? "bolt.fill" : "bolt.slash")
                .font(theme.font(size: 10))
                .foregroundStyle(state.ollamaArmed ? theme.statusColor(for: .healthy) : theme.textTertiary)
            Text(state.ollamaArmed
                 ? "Bascule Ollama armée · \(state.sessionsOnOllama) session\(state.sessionsOnOllama > 1 ? "s" : "") basculée\(state.sessionsOnOllama > 1 ? "s" : "")"
                 : "Ollama failover off")
                .font(theme.font(size: 10))
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Toggle("", isOn: Binding(get: { state.tier2Enabled },
                                     set: { setTier2($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Ollama failover switch (tier2.enabled)")
        }
    }

    // MARK: - Actions

    private func reactivate(_ slot: FailoverChainState.Slot, pool: FailoverChainState.Pool) {
        _ = store.reactivate(slot: slot.id, pool: pool)
        state = reader.read()
    }

    private func setTier2(_ enabled: Bool) {
        _ = store.setTier2(enabled: enabled)
        state = reader.read()
    }

    // MARK: - Poll

    private func refreshLoop() async {
        state = reader.read()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { return }
            state = reader.read()
        }
    }

    // MARK: - Presentation

    private func badgeColor(_ slot: FailoverChainState.Slot) -> Color {
        switch slot.status {
        case .head: return theme.statusColor(for: .healthy)
        case .healthy: return theme.statusColor(for: .healthy).opacity(0.4)
        case .quarantined: return theme.statusColor(for: .warning)
        }
    }

    private func countdown(to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))" }
        if minutes > 0 { return "\(minutes) min" }
        return "<1 min"
    }
}
