import SwiftUI
import Domain
import Infrastructure

/// The standalone Cortex Dashboard window root.
///
/// The compact menu's overview used to be embedded here verbatim, so the window
/// had no scroll container and no window background: content taller than the
/// screen grew the window off-screen and the unthemed surface showed a bare
/// white system background (Ben 2026-10-03, "le mode grand est moche"). This
/// root wraps the SAME overview data in a themed, scrolling, bounded surface —
/// one window, always on-screen, readable in every theme.
struct DashboardWindowView: View {
    let providers: [any AIProvider]
    @Bindable var settings: AppSettings
    /// Removes a whole provider from Cortex; account-scoped rows use the
    /// catalogue's account removal instead.
    var onRemoveProvider: ((String) -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    @State private var surface: DashboardSurface = .resources
    /// Set when a row of the « À traiter » feed is opened; the inspector replaces
    /// the list in place (a real `.sheet` does not render from the NSPopover).
    @State private var inspectedMissionId: String?

    var body: some View {
        ZStack {
            theme.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(.vertical, showsIndicators: true) {
                    content
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(
            minWidth: DashboardWindowLayout.minWidth,
            idealWidth: DashboardWindowLayout.idealWidth,
            minHeight: DashboardWindowLayout.minHeight,
            idealHeight: DashboardWindowLayout.idealHeight
        )
    }

    /// The window hosts two surfaces: the existing quota list and the
    /// « À traiter » feed (what needs a decision now). The inspector takes over
    /// the whole surface while a mission is open.
    @ViewBuilder
    private var content: some View {
        if let missionId = inspectedMissionId {
            MissionInspectorView(missionId: missionId) {
                withAnimation(.easeOut(duration: 0.15)) { inspectedMissionId = nil }
            }
        } else if surface == .attention {
            AttentionFeedView(
                onOpenMission: { missionId in
                    withAnimation(.easeOut(duration: 0.15)) { inspectedMissionId = missionId }
                },
                onReconnectAccount: { provider, accountId in
                    reconnectAccount(provider: provider, accountId: accountId)
                }
            )
        } else {
            OverviewDashboardView(
                providers: providers,
                settings: settings,
                onRemoveProvider: onRemoveProvider,
                rendersAccountCatalog: false
            )
        }
    }

    /// The reconnect affordance's destination: the Settings window, where account
    /// reconnection lives.
    ///
    /// KNOWN LIMITATION: Cortex cannot yet steer Settings to the exact
    /// provider/account the feed names. The provider selection is local `@State`
    /// in `ProvidersPane`, and the account catalogue is only presented from
    /// `OverviewDashboardView` — both outside this file, and `"settings"` is a
    /// value-less `Window`. So the router's `provider`/`accountId` cannot change
    /// the destination yet; they are logged here rather than silently discarded.
    /// Deep-linking is a follow-up that needs the Settings window, not this file.
    private func reconnectAccount(provider: String?, accountId: String?) {
        AppLog.ui.debug(
            "Attention reconnect → Settings (router provider=\(provider ?? "-"), account=\(accountId ?? "-")): Settings is not yet deep-linkable to a specific account"
        )
        openWindow(id: "settings")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.accentPrimary)
            Text("Cortex Dashboard")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 0)

            if inspectedMissionId == nil {
                Picker("", selection: $surface) {
                    ForEach(DashboardSurface.allCases) { candidate in
                        Text(candidate.label).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.glassBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.glassBorder)
                .frame(height: 1)
        }
    }
}

/// The surfaces the Dashboard window can show.
enum DashboardSurface: String, CaseIterable, Identifiable {
    /// Providers and their quota windows (the historical overview).
    case resources
    /// The llm-router « À traiter » feed: what needs a decision now.
    case attention

    var id: String { rawValue }

    var label: String {
        switch self {
        case .resources: "Ressources"
        case .attention: "À traiter"
        }
    }
}

/// Bounded geometry for the Dashboard window: comfortably large on a desktop,
/// always smaller than the smallest laptop screen, and never derived from the
/// number of accounts (the previous window grew with its content).
enum DashboardWindowLayout {
    static let minWidth: CGFloat = 720
    static let idealWidth: CGFloat = 1040
    static let minHeight: CGFloat = 520
    static let idealHeight: CGFloat = 760
}
