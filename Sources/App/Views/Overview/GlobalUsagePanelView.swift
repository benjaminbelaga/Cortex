import SwiftUI
import Domain

/// Collapsible global usage panel pinned at the bottom of the popover.
/// Token truth is rendered independently from pricing, so an unpriced backend
/// such as Qwen can never disappear from the UI.
struct GlobalUsagePanelView: View {
    let snapshot: RouterQuotaSnapshot?

    @State private var expanded = false
    @State private var window: UsageWindow = .last24h

    @Environment(\.appTheme) private var theme

    enum UsageWindow: String, CaseIterable, Identifiable {
        case last24h = "24h"
        case last7d = "7d"
        var id: String { rawValue }
    }

    private var usageSnapshot: RouterUsageSnapshot? { snapshot?.usage }
    private var usage: RouterUsageWindow? {
        window == .last24h ? usageSnapshot?.last24h : usageSnapshot?.last7d
    }
    private var cost: RouterCostWindow? {
        window == .last24h ? snapshot?.costEstimate?.last24h : snapshot?.costEstimate?.last7d
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                content
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        } label: {
            header
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.glassBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.glassBorder, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage & dépense théorique")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                if let usageSnapshot {
                    Text(freshnessLabel(usageSnapshot))
                        .font(theme.font(size: 8, weight: .medium))
                        .foregroundStyle(usageSnapshot.isStale ? theme.statusWarning : theme.textTertiary)
                }
            }
            Spacer()
            if let cost {
                Text("≈ \(formattedMoney(cost)) · \(formattedCoverage(cost.coveragePct))")
                    .font(theme.font(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
            } else if let usage {
                Text(formatTokens(usage.totals.totalTokens))
                    .font(theme.font(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
            } else if !(snapshot?.usageAnomalies ?? []).isEmpty {
                Text("\((snapshot?.usageAnomalies ?? []).count) anomalie(s)")
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundStyle(theme.statusWarning)
            } else {
                Text("—")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
            Text(window.rawValue)
                .font(theme.font(size: 8))
                .foregroundStyle(theme.textTertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                ForEach(UsageWindow.allCases) { value in
                    chip(value.rawValue, selected: window == value) { window = value }
                }
                Spacer()
                freshnessBadges
            }

            if let usage {
                HStack(spacing: 12) {
                    metric("tokens", formatTokens(usage.totals.totalTokens))
                    metric("messages", formatCount(usage.totals.messages))
                    metric("sessions", formatCount(usage.sessionsByHarness.values.reduce(0, +)))
                }

                Divider().overlay(theme.glassBorder)
                Text("Usage réel par backend")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)

                let sorted = usage.byBackend.sorted { $0.value.totalTokens > $1.value.totalTokens }
                let total = max(usage.totals.totalTokens, 1)
                ForEach(Array(sorted.enumerated()), id: \.offset) { _, entry in
                    backendRow(entry.key, usage: entry.value, total: total)
                }

                let anomalies = snapshot?.usageAnomalies ?? []
                if !anomalies.isEmpty {
                    Divider().overlay(theme.glassBorder)
                    Text("Anomalies d’usage")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    ForEach(anomalies) { anomaly in
                        anomalyRow(anomaly)
                    }
                }
            } else {
                Text("Aucun usage local agrégé — le prochain refresh réessaiera automatiquement.")
                    .font(theme.font(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }

            if let cost {
                Divider().overlay(theme.glassBorder)
                Text("Part tarifée de la dépense théorique")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)

                let priced = (cost.byModelEur.isEmpty ? cost.byModelUsd : cost.byModelEur)
                    .sorted { $0.value > $1.value }.prefix(5)
                let maxValue = priced.first?.value ?? 1
                ForEach(Array(priced.enumerated()), id: \.offset) { _, entry in
                    costRow(
                        entry.key,
                        value: entry.value,
                        maxValue: maxValue,
                        currency: cost.byModelEur.isEmpty ? "$" : "€"
                    )
                }

                HStack(spacing: 10) {
                    if let perMtok = cost.eurPerMtok ?? cost.usdPerMtok {
                        ratio(cost.eurPerMtok == nil ? "$/Mtok" : "€/Mtok", formatted(perMtok))
                    }
                    if let perSession = cost.eurPerSession ?? cost.usdPerSession {
                        ratio(cost.eurPerSession == nil ? "$/session" : "€/session", formatted(perSession))
                    }
                    ratio("tarifé", formattedCoverage(cost.coveragePct))
                }

                if let estimate = snapshot?.costEstimate,
                   estimate.reportingCurrency == "EUR",
                   let observed = estimate.fxObservedAt {
                    Text("Conversion EUR · référence BCE du \(observed)")
                        .font(theme.font(size: 8))
                        .foregroundStyle(theme.textTertiary)
                        .help(estimate.fxSourceURL ?? "Taux de référence BCE")
                }

                if !cost.unpricedModels.isEmpty {
                    Text("Non pricés : \(cost.unpricedModels.joined(separator: ", "))")
                        .font(theme.font(size: 8))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var freshnessBadges: some View {
        if let usageSnapshot, usageSnapshot.isStale {
            badge("périmé", color: theme.statusWarning, icon: "exclamationmark.triangle")
        } else if let usageSnapshot, usageSnapshot.isPartial {
            badge("partiel", color: theme.statusWarning, icon: "circle.lefthalf.filled")
        }
        if let cost, !cost.verified {
            badge("prix non vérifiés", color: theme.statusWarning, icon: "dollarsign.circle")
        }
    }

    private func backendRow(_ name: String, usage: RouterModelUsage, total: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(backendColor(name)).frame(width: 6, height: 6)
            Text(name)
                .font(theme.font(size: 9, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(backendColor(name))
                    .frame(width: max(3, geometry.size.width * CGFloat(usage.totalTokens) / CGFloat(total)))
            }
            .frame(height: 4)
            Text(formatTokens(usage.totalTokens))
                .font(theme.font(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .frame(minWidth: 48, alignment: .trailing)
            Text("\(usage.messages) msg")
                .font(theme.font(size: 8))
                .foregroundStyle(theme.textTertiary)
                .frame(minWidth: 48, alignment: .trailing)
        }
    }

    private func costRow(_ name: String, value: Double, maxValue: Double, currency: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(theme.font(size: 9, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.progressGradient(for: 55))
                    .frame(width: max(3, geometry.size.width * CGFloat(value / max(maxValue, 0.01))))
            }
            .frame(height: 4)
            Text("\(currency)\(formatted(value))")
                .font(theme.font(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .frame(minWidth: 46, alignment: .trailing)
        }
    }

    private func anomalyRow(_ anomaly: RouterUsageAnomaly) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(size: 8))
                .foregroundStyle(theme.statusWarning)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(anomaly.backend)
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    Text("· \(anomaly.window)")
                        .font(theme.font(size: 8))
                        .foregroundStyle(theme.textTertiary)
                }
                Text(anomaly.flags.map(anomalyLabel).joined(separator: " · "))
                    .font(theme.font(size: 8))
                    .foregroundStyle(theme.statusWarning)
            }
            Spacer()
            Text(formatTokens(anomaly.inputTokens + anomaly.cacheReadTokens))
                .font(theme.font(size: 8, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func anomalyLabel(_ flag: String) -> String {
        switch flag {
        case "partial": return "source partielle"
        case "large_context": return "contexte énorme"
        case "high_fresh_ratio": return "ratio fresh élevé"
        default: return flag
        }
    }

    private func backendColor(_ backend: String) -> Color {
        let value = backend.lowercased()
        if value.contains("local") { return .purple }
        if value.contains("qwen") { return .teal }
        if value.contains("minimax") { return .orange }
        if value.contains("glm") { return .pink }
        if value.contains("codex") { return .green }
        if value.contains("kimi") { return .cyan }
        if value.contains("claude") { return theme.accentPrimary }
        return .gray
    }

    private func freshnessLabel(_ usage: RouterUsageSnapshot) -> String {
        if usage.isStale {
            return usage.refreshError.map { "périmé · \($0)" } ?? "données périmées"
        }
        let age = max(usage.cacheAgeSeconds ?? 0, Date().timeIntervalSince(usage.generatedAt))
        if age < 60 { return "mis à jour à l’instant" }
        if age < 3600 { return "mis à jour il y a \(Int(age / 60)) min" }
        return "mis à jour il y a \(Int(age / 3600)) h"
    }

    private func badge(_ label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(theme.font(size: 7))
            Text(label).font(theme.font(size: 7, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(theme.font(size: 8)).foregroundStyle(theme.textTertiary)
            Text(value)
                .font(theme.font(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func ratio(_ label: String, _ value: String) -> some View {
        metric(label, value)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.font(size: 9, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.textPrimary : theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? theme.accentPrimary.opacity(0.18) : theme.glassBackground))
        }
        .buttonStyle(.plain)
    }

    private func formatted(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private func formattedMoney(_ cost: RouterCostWindow) -> String {
        if let eur = cost.totalEur { return "€\(formatted(eur))" }
        return "$\(formatted(cost.totalUsd))"
    }

    private func formattedCoverage(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%% tarifés", value) : "\(Int(value.rounded()))% tarifés"
    }

    private func formatTokens(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...: String(format: "%.2fB", Double(value) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }

    private func formatCount(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1fk", Double(value) / 1_000) : "\(value)"
    }
}
