import SwiftUI
import Foundation
import Domain
import Infrastructure

/// "À traiter" — the read-only projection of the router's own attention feed
/// (`llm-router attention --json`).
///
/// This surface exists to keep the router's honesty split visible rather than
/// smoothed over: a *requested* binding is not an *observed* one, and a process
/// that exited cleanly (rc=0) validates nothing. A **failed** read shows the
/// error text and a retry — never a reassuring zero; the "Rien à traiter" state
/// is reserved for a *successful* read that genuinely returned no item.
///
/// It is wired by the host (`MenuContentView` / Dashboard window) through the two
/// closures below, so it stays a pure, self-contained surface — no `.sheet`, no
/// navigation stack of its own.
struct AttentionFeedView: View {
    /// Open a mission's inspector. Only rows carrying a `missionId` call this.
    var onOpenMission: ((String) -> Void)? = nil
    /// Reconnect an account. `provider`/`accountId` are the router's own ids
    /// (nil when the row does not name them — never a guessed target).
    var onReconnectAccount: ((_ provider: String?, _ accountId: String?) -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var feed: RouterAttentionFeed?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let client = LLMRouterAttentionClient()

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshLoop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.bubble")
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.accentPrimary)
            Text("À traiter")
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
            if isLoading {
                ProgressView().controlSize(.mini)
            }
            if let feed, !feed.items.isEmpty {
                Text("\(feed.decisionCount) décision\(feed.decisionCount > 1 ? "s" : "") · \(feed.items.count) au total")
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }
        }
        .help("Projection en lecture seule du flux d'attention de llm-router. Cortex n'invente aucune décision : il affiche ce que le routeur signale, tel quel.")
    }

    // MARK: - Content / states

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            // A failed read is NOT an empty feed: show the error, not a zero.
            errorState(errorMessage)
        } else if let feed, !feed.items.isEmpty {
            let indexed = RouterAttentionFeed.sorted(feed.items)
                .enumerated()
                .map { IndexedAttentionItem(index: $0.offset, item: $0.element) }
            ForEach(indexed) { entry in
                if entry.index == 0
                    || indexed[entry.index - 1].item.severity.rank != entry.item.severity.rank {
                    severityHeader(entry.item.severity)
                }
                row(entry.item)
            }
        } else if feed != nil {
            emptyState
        } else {
            loadingState
        }
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Lecture du flux d'attention…")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .attentionFeedCard(theme)
    }

    /// Honest empty state: only reached after a *successful* read that returned
    /// no item. It never stands in for a failure.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal")
                .font(theme.font(size: 16))
                .foregroundStyle(theme.statusHealthy)
            Text("Rien à traiter")
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text("llm-router n'a signalé aucun élément d'attention à cet instant.")
                .font(theme.font(size: 10))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .attentionFeedCard(theme)
        .help("Un flux vide est le résultat d'une LECTURE RÉUSSIE : le routeur n'a rien signalé. Une lecture en échec affiche l'erreur ci-dessus, jamais ce zéro rassurant.")
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.statusWarning)
                Text("Lecture impossible")
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
                .help("Relancer la lecture de llm-router attention.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .attentionFeedCard(theme)
        .help("L'état d'attention est INCONNU : la lecture a échoué. Aucun zéro n'est affiché, pour ne pas faire croire qu'il n'y a rien à traiter.")
    }

    // MARK: - Rows

    private func severityHeader(_ severity: RouterAttentionSeverity) -> some View {
        HStack(spacing: 6) {
            Text(severity.label.uppercased())
                .font(theme.font(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Rectangle()
                .fill(theme.glassBorder)
                .frame(height: 1)
        }
        .help("Sévérité \(severity.label) — les éléments les plus urgents viennent en premier.")
    }

    private func row(_ item: RouterAttentionItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(severityColor(item.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 3)
                .help("Sévérité \(item.severity.label)")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.kind.label)
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .help(item.kind.summary)
                    if item.kind.isDecision {
                        decisionPill
                    }
                    Spacer(minLength: 0)
                    if item.missionId != nil {
                        Image(systemName: "chevron.right")
                            .font(theme.font(size: 9, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Text(item.detail)
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let target = item.target {
                    Text(target)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if item.kind == .launchDivergence {
                    divergenceLine(item)
                }

                reconnectAffordance(item)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let missionId = item.missionId { onOpenMission?(missionId) }
        }
        .attentionFeedCard(theme)
    }

    private var decisionPill: some View {
        Text("à décider")
            .font(theme.font(size: 8, weight: .semibold))
            .foregroundStyle(theme.accentPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.accentPrimary.opacity(0.14)))
            .help("Cette attention demande une décision humaine. Cortex ne décide pas à ta place.")
    }

    /// `launchDivergence` rows show what was *requested* beside what was
    /// *observed* — the router's own honesty split, compactly.
    private func divergenceLine(_ item: RouterAttentionItem) -> some View {
        let requested = compactPairs(item.requested)
        let observed = compactPairs(item.observed)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                Text("demandé")
                    .font(theme.font(size: 8, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Text(requested.isEmpty ? "—" : requested)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 4) {
                Text("observé")
                    .font(theme.font(size: 8, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Text(observed.isEmpty ? "—" : observed)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(theme.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("« demandé » = la liaison demandée par la recommandation ; « observé » = ce qui a réellement tourné. Une liaison demandée n'est PAS une liaison observée : tout l'écart est affiché ici.")
    }

    @ViewBuilder
    private func reconnectAffordance(_ item: RouterAttentionItem) -> some View {
        if item.kind == .accountReconnect, let onReconnectAccount {
            Button {
                onReconnectAccount(item.provider, item.accountId)
            } label: {
                Label("Reconnecter", systemImage: "arrow.clockwise")
                    .font(theme.font(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accentPrimary)
            .help("Reconnecter le compte pour le rendre à nouveau routable. Une reconnexion demandée ne prouve pas la reconnexion tant qu'aucun reçu ne l'observe.")
        }
    }

    // MARK: - Presentation

    private func severityColor(_ severity: RouterAttentionSeverity) -> Color {
        switch severity {
        case .high: theme.statusCritical
        case .medium: theme.statusWarning
        case .low: theme.textTertiary
        }
    }

    /// "k=v, k=v" for a router JSON object, via `RouterJSONValue.displayText`.
    private func compactPairs(_ pairs: [String: RouterJSONValue]) -> String {
        pairs.keys.sorted()
            .map { "\($0)=\(pairs[$0]?.displayText ?? "")" }
            .joined(separator: ", ")
    }

    // MARK: - Load / poll

    /// 60 s refresh cadence, never blocking the main actor (same convention as
    /// the sessions/failover cards).
    private func refreshLoop() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.attention()
            feed = fresh
            errorMessage = nil
        } catch {
            // Keep `feed` for a later retry, but let the error dominate the UI —
            // a stale list is NOT shown as if it were a fresh, honest zero.
            errorMessage = error.localizedDescription
        }
    }
}

/// One enumerated row, kept `Identifiable` by the item's own stable id so the
/// list does not jump between refreshes (and so no tuple key-path is needed).
private struct IndexedAttentionItem: Identifiable {
    let index: Int
    let item: RouterAttentionItem
    var id: String { item.id }
}

private extension View {
    /// The standard Cortex card recipe: card gradient fill + a 1pt glass border
    /// (identical to `.themeCard()`), inlined so the row container is explicit.
    func attentionFeedCard(_ theme: any AppThemeProvider) -> some View {
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
