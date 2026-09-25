import SwiftUI
import Domain

/// "Priority" recommendation card at the top of the overview popover (bible §15).
/// Collapsed by default (Ben 2026-09-23: "petit par défaut, j'appuie sur un
/// bouton, ça se déplie, et je referme") — the collapsed line already answers
/// "quel modèle prendre maintenant ?" with the provider logo, the LLM family
/// logo and the exact model. Expanding reveals the profile picker (Plan fort /
/// Exécution éco / Flexible), the binding window, alternatives and "pourquoi".
/// Cortex NEVER computes a recommendation locally — when `route_now` is absent
/// the card says so.
struct PriorityCardView: View {
    let routeNow: RouterRouteNow?
    @Binding var profile: RouterRouteNow.Profile
    /// Persisted open/closed state of the card (default: collapsed).
    @Binding var expanded: Bool

    @Environment(\.appTheme) private var theme
    @State private var showReasons = true

    private var recommendation: RouterRecommendation? {
        routeNow?.recommendation(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded {
                SettingsSegmentedControl(
                    options: RouterRouteNow.Profile.allCases,
                    label: { $0.displayName },
                    selection: $profile
                )
                if let recommendation {
                    recommendationBody(recommendation)
                } else {
                    unavailable
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.glassBorder, lineWidth: 1))
    }

    /// One clickable line. Collapsed it carries the glanceable answer (provider
    /// + LLM logos, exact model, score); expanded it is the card's title bar.
    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.accentPrimary)
                Text("Priority")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                if !expanded {
                    if let rec = recommendation {
                        compactRecommendation(rec)
                    } else {
                        Text("llm-router unavailable")
                            .font(theme.font(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                if expanded, let generatedAt = routeNow?.generatedAt {
                    Text(generatedAt, style: .relative)
                        .font(theme.font(size: 8))
                        .foregroundStyle(theme.textTertiary)
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse priority" : "Expand priority")
    }

    /// The glanceable answer: [provider logo][LLM family logo] exact model + score.
    /// Provider and LLM are two different things (Ben 2026-09-23) — the provider
    /// icon is the rail, the family logo is the model behind it.
    private func compactRecommendation(_ rec: RouterRecommendation) -> some View {
        HStack(spacing: 5) {
            ProviderIconView(providerId: cortexId(rec.provider), size: 16, showGlow: true)
            if let family = ModelFamily(modelId: rec.model) {
                ModelFamilyLogo(family: family, size: 12)
            }
            Text(rec.model)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            scoreBadge(rec.score)
        }
    }

    private var unavailable: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.slash")
                .font(theme.font(size: 10))
                .foregroundStyle(theme.textTertiary)
            Text("llm-router unavailable")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func recommendationBody(_ rec: RouterRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Primary choice: provider rail · LLM family · exact model.
            HStack(spacing: 6) {
                ProviderIconView(providerId: cortexId(rec.provider), size: 18, showGlow: true)
                if let family = ModelFamily(modelId: rec.model) {
                    ModelFamilyLogo(family: family, size: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(providerName(rec.provider))
                            .font(theme.font(size: 12, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                        if let account = rec.account {
                            Text("· \(account)")
                                .font(theme.font(size: 10, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    Text(rec.model)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                scoreBadge(rec.score)
            }

            bindingLine(rec)
            contextLine(rec)

            if !rec.alternatives.isEmpty {
                alternatives(rec.alternatives)
            }

            if !rec.reasons.isEmpty || !rec.excluded.isEmpty {
                whyDisclosure(rec)
            }
        }
    }

    private func scoreBadge(_ score: Double) -> some View {
        Text(String(format: "%.0f", score))
            .font(theme.font(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(theme.accentPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.accentPrimary.opacity(0.14)))
    }

    @ViewBuilder
    private func bindingLine(_ rec: RouterRecommendation) -> some View {
        if let window = rec.bindingWindow {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(theme.font(size: 9))
                    .foregroundStyle(theme.textTertiary)
                Text("\(window.remainingPct) % · \(windowLabel(window.kind))")
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.statusColor(for: QuotaStatus.from(percentRemaining: Double(window.remainingPct))))
                    .monospacedDigit()
                if let reset = window.resetsAt {
                    Text("· reset \(reset, style: .relative)")
                        .font(theme.font(size: 9))
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// One compact context line: hour rule (peak/creuse + multiplier), promo
    /// window, and live-session count — the router's time/availability/session
    /// signals at a glance (bible §15 rules made visible by default).
    @ViewBuilder
    private func contextLine(_ rec: RouterRecommendation) -> some View {
        HStack(spacing: 5) {
            Image(systemName: timeIcon(rec.timeState))
                .font(theme.font(size: 9))
                .foregroundStyle(timeColor(rec.timeState))
            Text(timeLabel(rec))
                .font(theme.font(size: 9, weight: .medium))
                .foregroundStyle(timeColor(rec.timeState))
            if let slot = rec.nextBetterSlot {
                Text("· meilleur: \(slot.formatted(date: .omitted, time: .shortened))")
                    .font(theme.font(size: 8))
                    .foregroundStyle(theme.textTertiary)
            }
            if let promo = rec.promoExpiry {
                Text("· promo → \(promo)")
                    .font(theme.font(size: 8))
                    .foregroundStyle(theme.textTertiary)
            }
            if let sessions = rec.liveSessions {
                Text("· \(sessions) session\(sessions > 1 ? "s" : "") active\(sessions > 1 ? "s" : "")")
                    .font(theme.font(size: 8))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func alternatives(_ alts: [RouterRouteAlternative]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Alternatives")
                .font(theme.font(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            ForEach(alts.prefix(2)) { alt in
                HStack(spacing: 5) {
                    ProviderIconView(providerId: cortexId(alt.provider), size: 12, showGlow: false)
                    if let family = ModelFamily(modelId: alt.model) {
                        ModelFamilyLogo(family: family, size: 10)
                    }
                    Text(providerName(alt.provider))
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    if let account = alt.account {
                        Text("· \(account)")
                            .font(theme.font(size: 8))
                            .foregroundStyle(theme.textTertiary)
                    }
                    Text(alt.model)
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                    if alt.quotaHeadroomPct == nil {
                        Image(systemName: "questionmark.circle")
                            .font(theme.font(size: 8))
                            .foregroundStyle(theme.statusWarning)
                            .help("Unknown quota — no synced data: alternative not comparable to the rest. Sync before use.")
                    }
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f", alt.score))
                        .font(theme.font(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func whyDisclosure(_ rec: RouterRecommendation) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showReasons.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showReasons ? "chevron.down" : "chevron.right")
                    .font(theme.font(size: 8, weight: .bold))
                Text("Pourquoi")
                    .font(theme.font(size: 9, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showReasons {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rec.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "checkmark").font(theme.font(size: 7)).foregroundStyle(theme.statusHealthy)
                        Text(reason).font(theme.font(size: 8)).foregroundStyle(theme.textSecondary)
                    }
                }
                ForEach(rec.excluded) { exclusion in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "xmark").font(theme.font(size: 7)).foregroundStyle(theme.statusWarning)
                        Text(exclusionLabel(exclusion)).font(theme.font(size: 8)).foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .padding(.leading, 4)
        }
    }

    // MARK: - Labels

    /// `route_now` speaks router ids (`opencode_go`, `glm_pro`); the icon and
    /// the display name belong to the Cortex provider behind them (R37, one
    /// table). An id the table does not know stays raw — never guessed.
    private func cortexId(_ routerId: String) -> String {
        RouterProviderIdMap.cortexId(forRouter: routerId) ?? routerId
    }

    private func providerName(_ routerId: String) -> String {
        guard let id = RouterProviderIdMap.cortexId(forRouter: routerId) else { return routerId }
        return ProviderVisualIdentityLookup.name(for: id)
    }

    private func exclusionLabel(_ exclusion: RouterRouteExclusion) -> String {
        var head = providerName(exclusion.provider)
        if let account = exclusion.account { head += " · \(account)" }
        return "\(head) : \(exclusion.reason)"
    }

    private func windowLabel(_ kind: String) -> String {
        switch kind.lowercased() {
        case "rolling", "session", "5h": return "5 h"
        case "weekly", "7d": return "7 j"
        case "monthly": return "30 j"
        default: return kind
        }
    }

    private func timeLabel(_ rec: RouterRecommendation) -> String {
        let multiplier = String(format: "×%.2g", rec.timeMultiplier)
        switch rec.timeState {
        case "peak": return "peak \(multiplier)"
        case "discount": return "off-peak \(multiplier)"
        default: return "tarif normal \(multiplier)"
        }
    }

    private func timeIcon(_ state: String) -> String {
        switch state {
        case "peak": return "arrow.up.right.circle"
        case "discount": return "arrow.down.right.circle"
        default: return "clock"
        }
    }

    private func timeColor(_ state: String) -> Color {
        switch state {
        case "peak": return theme.statusWarning
        case "discount": return theme.statusHealthy
        default: return theme.textTertiary
        }
    }
}
