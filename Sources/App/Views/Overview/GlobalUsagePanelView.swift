import SwiftUI
import Charts
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
                Text("Usage & theoretical spend")
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

                dailyMonitor

                Divider().overlay(theme.glassBorder)
                Text("Actual usage by backend")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)

                // Ordering (Ben 2026-09-23): one system — rows with a real
                // amount first (desc), then benchmark estimates, then rows with
                // no amount at all. Never bury a metered figure under a guess.
                let sorted = usage.byBackend.sorted { lhs, rhs in
                    func rank(_ key: String) -> Int {
                        if cost?.byBackendRecordedUsd[key] != nil { return 0 }  // metered
                        if cost?.byBackendSpendUsd[key] != nil { return 1 }     // benchmark
                        return 2                                                // unknown
                    }
                    let (lr, rr) = (rank(lhs.key), rank(rhs.key))
                    if lr != rr { return lr < rr }
                    return lhs.value.totalTokens > rhs.value.totalTokens
                }
                let total = max(usage.totals.totalTokens, 1)
                if hasSpendByBackend {
                    HStack(spacing: 6) {
                        Spacer()
                        Text(hasEstimatedSpend ? "spend · ≈ estimated" : "recorded cost")
                            .font(theme.font(size: 8, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                ForEach(Array(sorted.enumerated()), id: \.offset) { _, entry in
                    backendRow(entry.key, usage: entry.value, total: total,
                               spend: spendValue(for: entry.key),
                               estimated: cost?.estimatedBackends.contains(entry.key) ?? false)
                }

                // Usage attributed by MODEL FAMILY (the weights that ran), not by
                // subscription — so DeepSeek reached through OpenCode Go / Ollama
                // / Command Code reads as one DeepSeek line (Ben 2026-09-23).
                if !usage.byFamily.isEmpty {
                    Divider().overlay(theme.glassBorder)
                    HStack {
                        Text("Actual usage by model")
                            .font(theme.font(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                        Spacer()
                        Text("family · executed weights")
                            .font(theme.font(size: 8))
                            .foregroundStyle(theme.textTertiary)
                    }
                    let families = usage.byFamily.sorted { $0.value.totalTokens > $1.value.totalTokens }
                    let familyTotal = max(families.reduce(0) { $0 + $1.value.totalTokens }, 1)
                    ForEach(Array(families.enumerated()), id: \.offset) { _, entry in
                        familyRow(entry.key, usage: entry.value, total: familyTotal)
                    }
                    familyPie(families)
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
                Text("No local usage aggregated — the next refresh will retry automatically.")
                    .font(theme.font(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }

            if let cost {
                Divider().overlay(theme.glassBorder)
                Text("Billed share of theoretical spend")
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
                    ratio("billed", formattedCoverage(cost.coveragePct))
                    if let recorded = cost.recordedUsd {
                        ratio("actual cost", "$\(formatted(recorded))")
                    }
                    // "Combien j'ai dépensé" — recorded + benchmark estimates,
                    // the one figure that is never blank (v7.4).
                    if let spend = cost.spendUsd, hasEstimatedSpend {
                        if let eur = cost.spendEur {
                            ratio("spend ≈", "€\(formatted(eur))")
                        } else {
                            ratio("spend ≈", "$\(formatted(spend))")
                        }
                    }
                }

                if let estimate = snapshot?.costEstimate,
                   estimate.reportingCurrency == "EUR",
                   let observed = estimate.fxObservedAt {
                    Text("EUR conversion · ECB reference of \(observed)")
                        .font(theme.font(size: 8))
                        .foregroundStyle(theme.textTertiary)
                        .help(estimate.fxSourceURL ?? "ECB reference rate")
                }

                if !cost.unpricedModels.isEmpty {
                    Text("Unpriced: \(cost.unpricedModels.joined(separator: ", "))")
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
            badge("stale", color: theme.statusWarning, icon: "exclamationmark.triangle")
        } else if let usageSnapshot, usageSnapshot.isPartial {
            badge("partiel", color: theme.statusWarning, icon: "circle.lefthalf.filled")
        }
        if let cost, !cost.verified {
            badge("unverified prices", color: theme.statusWarning, icon: "dollarsign.circle")
        }
    }

    /// True when the router priced any backend's spend for the selected window —
    /// recorded (provider ledger) or benchmark estimate (pricing SSOT, v7.4).
    /// Gates the spend column (hidden otherwise).
    private var hasSpendByBackend: Bool {
        !(cost?.byBackendSpendUsd.isEmpty ?? true) || !(cost?.byBackendRecordedUsd.isEmpty ?? true)
    }

    /// True when at least one backend's figure is a benchmark estimate rather
    /// than a metered cost — drives the "≈ estimée" header wording.
    private var hasEstimatedSpend: Bool {
        !(cost?.estimatedBackends.isEmpty ?? true)
    }

    /// Recorded spend wins; the benchmark estimate fills the gap (bible R41).
    private func spendValue(for backend: String) -> Double? {
        if let recorded = cost?.byBackendRecordedUsd[backend] { return recorded }
        return cost?.byBackendSpendUsd[backend]
    }

    /// Sessions/day + tokens/day over the last days (the "usage monitor",
    /// Ben 2026-09-23: "combien de sessions par jour, combien de tokens").
    @ViewBuilder
    private var dailyMonitor: some View {
        let daily = (usageSnapshot?.daily ?? [:]).sorted { $0.key < $1.key }
        let recent = Array(daily.suffix(7))
        if recent.count >= 2 {
            let sessionsPerDay = Double(recent.reduce(0) { $0 + $1.value.sessions }) / Double(recent.count)
            let tokensPerDay = Double(recent.reduce(0) { $0 + $1.value.tokens }) / Double(recent.count)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text("Moyenne \(recent.count) j")
                        .font(theme.font(size: 8, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    metric("sessions/j", formatted(sessionsPerDay))
                    metric("tokens/j", formatTokens(Int(tokensPerDay)))
                }
                Chart(recent, id: \.key) { point in
                    BarMark(
                        x: .value("Day", String(point.key.suffix(5))),
                        y: .value("Sessions", point.value.sessions)
                    )
                    .foregroundStyle(theme.accentPrimary.opacity(0.7))
                    .cornerRadius(2)
                }
                .frame(height: 46)
            }
        }
    }

    /// Family icon: the DeepSeek whale asset when present, else an SF Symbol.
    @ViewBuilder
    private func familyIcon(_ family: String, size: CGFloat) -> some View {
        if let asset = ModelFamilyVisual.iconAssetName(for: family),
           let image = NSImage(named: asset) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: ModelFamilyVisual.symbolIcon(for: family))
                .font(theme.font(size: size * 0.8))
                .foregroundStyle(ModelFamilyVisual.color(for: family))
        }
    }

    private func familyRow(_ family: String, usage: RouterModelUsage, total: Int) -> some View {
        HStack(spacing: 6) {
            familyIcon(family, size: 12)
            Text(ModelFamilyVisual.displayName(for: family))
                .font(theme.font(size: 9, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .frame(width: 86, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(ModelFamilyVisual.color(for: family))
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

    /// Camembert of the family split (CORTEX_BIBLE §15: "tasks by model" is a
    /// separate pie from "spend by provider").
    @ViewBuilder
    private func familyPie(_ families: [(key: String, value: RouterModelUsage)]) -> some View {
        let data = families
            .map { (family: $0.key, tokens: $0.value.totalTokens) }
            .filter { $0.tokens > 0 }
        if data.count >= 2 {
            Chart(data, id: \.family) { point in
                SectorMark(
                    angle: .value("Tokens", point.tokens),
                    innerRadius: .ratio(0.55),
                    angularInset: 1
                )
                .cornerRadius(2)
                .foregroundStyle(ModelFamilyVisual.color(for: point.family))
            }
            .chartLegend(position: .bottom, spacing: 6)
            .frame(height: 120)
            .padding(.top, 4)
        }
    }

    private func backendRow(_ name: String, usage: RouterModelUsage, total: Int,
                            spend: Double?, estimated: Bool) -> some View {
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
            // Spend beside the token count: the metered cost when the provider
            // ledger has one, else the benchmark estimate from the pricing SSOT
            // (v7.4, bible R41 — an unknown price is not zero). "≈" flags an
            // estimate so a guess never reads as a billed figure.
            if hasSpendByBackend {
                Text(spend.map { estimated ? "≈$\(formatted($0))" : "$\(formatted($0))" } ?? "—")
                    .font(theme.font(size: 8, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(estimated ? theme.textTertiary : theme.textSecondary)
                    .frame(minWidth: 56, alignment: .trailing)
                    .help(estimated
                          ? "Benchmark estimate (SSOT prices) — not billed by the provider"
                          : "Cost recorded by the provider")
            }
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
        case "large_context": return "huge context"
        case "high_fresh_ratio": return "high fresh ratio"
        default: return flag
        }
    }

    private func backendColor(_ backend: String) -> Color {
        let value = backend.lowercased()
        // Most specific compound backends first, so "claude-llm" / "qwen-natif"
        // never fall through to the bare "claude" / "qwen" branch.
        if value.contains("opencode") { return .indigo }
        if value.contains("commandcode") { return .brown }
        if value.contains("ollama") { return .purple }
        if value.contains("zai") { return .pink }
        if value.contains("bailian") { return .teal }
        if value.contains("claude-llm") { return .mint }
        if value.contains("qwen-natif") || value.contains("qwen_natif") { return .teal }
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
            return usage.refreshError.map { "périmé · \($0)" } ?? "stale data"
        }
        let age = max(usage.cacheAgeSeconds ?? 0, Date().timeIntervalSince(usage.generatedAt))
        if age < 60 { return "updated just now" }
        if age < 3600 { return "updated \(Int(age / 60)) min ago" }
        return "updated \(Int(age / 3600)) h ago"
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
        value < 10 ? String(format: "%.1f%% billed", value) : "\(Int(value.rounded()))% tarifés"
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
