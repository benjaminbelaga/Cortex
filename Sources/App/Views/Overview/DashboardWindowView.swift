import SwiftUI
import Domain

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

    var body: some View {
        ZStack {
            theme.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(.vertical, showsIndicators: true) {
                    OverviewDashboardView(
                        providers: providers,
                        settings: settings,
                        onRemoveProvider: onRemoveProvider,
                        rendersAccountCatalog: false
                    )
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

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.accentPrimary)
            Text("Cortex Dashboard")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 0)
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

/// Bounded geometry for the Dashboard window: comfortably large on a desktop,
/// always smaller than the smallest laptop screen, and never derived from the
/// number of accounts (the previous window grew with its content).
enum DashboardWindowLayout {
    static let minWidth: CGFloat = 720
    static let idealWidth: CGFloat = 1040
    static let minHeight: CGFloat = 520
    static let idealHeight: CGFloat = 760
}
