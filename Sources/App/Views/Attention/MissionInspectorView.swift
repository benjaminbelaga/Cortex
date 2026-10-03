import SwiftUI
import Foundation
import Domain
import Infrastructure

/// The honesty chain of one mission: **Recommandé → Exécuté → Vérifié**.
///
/// This is the `llm-router mission inspect <id>` view. Its whole point is to make
/// the gaps visible instead of folding them into a success:
/// a recommendation that was never executed, an *observed* receipt that diverges
/// from the *requested* one, and a closed process that was **never evaluated**
/// (rc=0 is not a verdict). The view never invents a state — no green tick for an
/// unverified mission.
///
/// Self-contained, wired by the host through `onBack` (a real `.sheet` does not
/// render from an `NSPopover`, so the caller stays in-surface).
struct MissionInspectorView: View {
    let missionId: String
    /// "← Retour" affordance shown only when the host provides it.
    var onBack: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var inspection: MissionInspection?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let inspector = LLMRouterMissionInspector()

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let onBack {
                    Button {
                        onBack()
                    } label: {
                        Label("Retour", systemImage: "chevron.left")
                            .font(theme.font(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accentPrimary)
                }
                Image(systemName: "flag.checkered")
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text("Mission")
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }
            Text(missionId)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text("Recommandé → Exécuté → Vérifié")
                .font(theme.font(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .help("Trois temps de la chaîne : ce que le routeur a recommandé, ce qui a réellement été exécuté (reçu), et ce qui a été évalué. Rien n'est déduit d'un des trois.")
        }
    }

    // MARK: - Content / states

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            notFoundState(errorMessage)
        } else if let inspection {
            recommendationBlock(inspection)
            executedBlock(inspection)
            verifiedBlock(inspection)
        } else {
            loadingState
        }
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Lecture de la mission…")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .missionInspectorCard(theme)
    }

    private func notFoundState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.folder")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.statusWarning)
                Text("Mission introuvable")
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            Text(message)
                .font(theme.font(size: 10))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Réessayer") { Task { await load() } }
                .buttonStyle(.plain)
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(theme.accentPrimary)
                .help("Relancer llm-router mission inspect pour cet id.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .missionInspectorCard(theme)
        .help("Aucune inspection n'a pu être lue : Cortex n'affiche donc aucune étape. Un échec de lecture n'est jamais une mission vide.")
    }

    // MARK: - Recommandé

    private func recommendationBlock(_ inspection: MissionInspection) -> some View {
        block("Recommandé") {
            if inspection.hasRecommendation {
                let rec = inspection.recommended
                VStack(alignment: .leading, spacing: 2) {
                    kv("provider", rec.provider ?? "—")
                    kv("model", rec.model ?? "—")
                    kv("score", metric(rec.score))
                }
                accountLine(rec.account)
                if !rec.reasons.isEmpty {
                    reasonsList(rec.reasons)
                }
            } else {
                Text("aucune recommandation enregistrée")
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .help("Le routeur n'a nommé ni provider ni model pour cette mission : la première étape de la chaîne est un trou, pas un succès.")
            }
        }
    }

    @ViewBuilder
    private func accountLine(_ account: [String: RouterJSONValue]?) -> some View {
        if let account, !account.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("compte")
                    .font(theme.font(size: 8, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                kv("id", account["id"]?.displayText ?? "—")
                kv("alias", account["alias"]?.displayText ?? "—")
                kv("identity", account["identity"]?.displayText ?? "—")
            }
            .help("Identité du compte recommandé, telle que le routeur la déclare. Un champ absent s'affiche « — » : jamais un compte inventé.")
        }
    }

    private func reasonsList(_ reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("raisons")
                .font(theme.font(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(theme.font(size: 4))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, 4)
                    Text(reason)
                        .font(theme.font(size: 9))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Exécuté

    private func executedBlock(_ inspection: MissionInspection) -> some View {
        block("Exécuté") {
            HStack(spacing: 6) {
                Text("reçu")
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Text(receiptLabel(inspection.receiptState))
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(receiptColor(inspection.receiptState))
                    .help(receiptHelp(inspection.receiptState))
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 14) {
                pairColumn("demandé", inspection.requested)
                pairColumn("observé", inspection.observed)
            }
            if let divergence = inspection.divergence {
                divergenceCallout(divergence)
            }
        }
    }

    private func pairColumn(_ title: String, _ pairs: [String: RouterJSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(theme.font(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            if pairs.isEmpty {
                Text("—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(Array(pairs.keys.sorted().enumerated()), id: \.offset) { _, key in
                    HStack(alignment: .top, spacing: 4) {
                        Text(key)
                            .font(theme.font(size: 8))
                            .foregroundStyle(theme.textTertiary)
                        Text(pairs[key]?.displayText ?? "")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("« \(title) » : \(title == "demandé" ? "la liaison demandée — elle ne prouve pas l'exécution." : "ce qui a réellement tourné selon le reçu.")")
    }

    private func divergenceCallout(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(size: 10))
                .foregroundStyle(theme.statusCritical)
            VStack(alignment: .leading, spacing: 2) {
                Text("Divergence")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.statusCritical)
                Text(text)
                    .font(theme.font(size: 9))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.statusCritical.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.statusCritical.opacity(0.4), lineWidth: 1)
        )
        .help("Ce qui a été observé diverge de ce qui était demandé. Une divergence n'est jamais lissée : elle est montrée en haute sévérité.")
    }

    // MARK: - Vérifié

    private func verifiedBlock(_ inspection: MissionInspection) -> some View {
        block("Vérifié") {
            HStack(spacing: 6) {
                Text("état")
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Text(inspection.result.resultState.isEmpty ? "—" : inspection.result.resultState)
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }
            verdictLine(inspection.result)
            if let notes = inspection.result.processNotes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("notes de process")
                        .font(theme.font(size: 8, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Text(notes)
                        .font(theme.font(size: 9))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            metricsGrid(inspection.metrics)
        }
    }

    private func verdictLine(_ result: MissionInspection.ResultStage) -> some View {
        let presentation = verdict(result)
        return HStack(spacing: 6) {
            Image(systemName: presentation.icon)
                .font(theme.font(size: 10))
                .foregroundStyle(presentation.color)
            Text(presentation.label)
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(presentation.color)
            Spacer(minLength: 0)
        }
        .help(presentation.help)
    }

    /// Tri-state verdict. `success == nil` is **"jamais évalué"** (amber) and
    /// explicitly disclaims a clean exit — `isUnverifiedClose` marks a closed
    /// mission with no evaluation. No green tick is ever invented.
    private func verdict(_ result: MissionInspection.ResultStage) -> VerdictPresentation {
        if result.isVerified {
            return VerdictPresentation(
                label: "résultat vérifié",
                icon: "checkmark.seal.fill",
                color: theme.statusHealthy,
                help: "Une évaluation explicite a marqué ce résultat comme réussi."
            )
        }
        if result.isFailed {
            return VerdictPresentation(
                label: "résultat échoué",
                icon: "xmark.seal.fill",
                color: theme.statusCritical,
                help: "Une évaluation explicite a marqué ce résultat comme échoué."
            )
        }
        return VerdictPresentation(
            label: "jamais évalué",
            icon: "questionmark.circle",
            color: theme.statusWarning,
            help: result.isUnverifiedClose
                ? "La mission est close mais AUCUNE évaluation n'a eu lieu. Un code de sortie 0 (rc=0) ne vaut pas verdict : il ne prouve ni réussite ni échec. La validation reste à faire."
                : "Aucune évaluation explicite n'a eu lieu. Un code de sortie 0 (rc=0) ne vaut pas verdict : la validation reste à faire."
        )
    }

    private func metricsGrid(_ metrics: MissionInspection.Metrics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("métriques")
                .font(theme.font(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            kv("duration_s", metric(metrics.durationSeconds, suffix: " s"))
            kv("input_tokens", metric(metrics.inputTokens))
            kv("output_tokens", metric(metrics.outputTokens))
            kv("tests_passed", metric(metrics.testsPassed))
            kv("estimated_cost", metric(metrics.estimatedCost))
        }
        .help("Une métrique absente s'affiche « — », jamais un 0 inventé. estimated_cost reste une estimation, pas un relevé facturé.")
    }

    // MARK: - Building blocks

    private func block<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .missionInspectorCard(theme)
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(theme.font(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// A number as a compact string, `"—"` for a missing value (never `0`), and
    /// `"—"` for a non-finite value rather than an unsafe cast.
    private func metric(_ value: Double?, suffix: String = "") -> String {
        guard let value, value.isFinite else { return "—" }
        let text = value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
        return text + suffix
    }

    // MARK: - Labels

    private func receiptLabel(_ state: MissionInspection.ReceiptState) -> String {
        switch state {
        case .confirmed: "confirmé"
        case .unconfirmed: "non confirmé"
        case .divergent: "divergent"
        case .unknown: "inconnu"
        }
    }

    private func receiptColor(_ state: MissionInspection.ReceiptState) -> Color {
        switch state {
        case .confirmed: theme.statusHealthy
        case .unconfirmed: theme.statusWarning
        case .divergent: theme.statusCritical
        case .unknown: theme.textTertiary
        }
    }

    private func receiptHelp(_ state: MissionInspection.ReceiptState) -> String {
        switch state {
        case .confirmed: "Un reçu OBSERVÉ confirme que l'exécution a été liée."
        case .unconfirmed: "Un reçu demandé mais non observé : la liaison n'est pas prouvée."
        case .divergent: "Le reçu observé diverge de ce qui était demandé."
        case .unknown: "État du reçu inconnu de cette version de Cortex — affiché tel quel."
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await inspector.inspect(missionId: missionId)
            inspection = fresh
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The resolved look of the tri-state verdict: label, SF Symbol, colour and the
/// honest one-line tooltip. A plain value type so it is a `Sendable` snapshot,
/// never a view that could imply more than the data does.
private struct VerdictPresentation {
    let label: String
    let icon: String
    let color: Color
    let help: String
}

private extension View {
    /// The standard Cortex card recipe: card gradient fill + a 1pt glass border
    /// (identical to `.themeCard()`), inlined so each stage container is explicit.
    func missionInspectorCard(_ theme: any AppThemeProvider) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                    .fill(theme.cardGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                    .strokeBorder(theme.glassBorder, lineWidth: 1)
            )
    }
}
