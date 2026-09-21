import SwiftUI
import Domain
import Infrastructure

/// All-providers overview dashboard ("ce qu'il me reste").
///
/// Comprehension-first layout (Ben, 2026-08-18): rows sorted by worst
/// remaining percentage (or soonest reset), one-click window selector
/// Session 5h / Semaine / Tout driving both the headline number and the
/// ordering, relative reset times only, one stylized row per LLM identity.
struct OverviewDashboardView: View {
    let providers: [any AIProvider]
    @Bindable var settings: AppSettings

    @Environment(\.appTheme) private var theme
    @Environment(AccountCatalogModel.self) private var catalogModel
    @State private var calendarSnapshot: ProviderSnapshot?

    private var rows: [ProviderSnapshot] {
        OverviewBuilder.sort(
            OverviewBuilder.build(providers: providers),
            by: settings.overviewSort,
            filter: settings.overviewWindowFilter
        )
    }

    /// Count of filtered windows under 10% remaining — the "act now" footer.
    /// Stale windows are excluded (a multi-day-old manual sync or an errored
    /// provider's phantom 0% is not a real low), matching the health glyph.
    private var criticalCount: Int {
        OverviewBuilder.build(providers: providers)
            .flatMap { $0.windows }
            .filter { settings.overviewWindowFilter.matches($0.scope) && $0.percentRemaining < 10 && !$0.isDollarBased && !$0.isStale }
            .count
    }

    var body: some View {
        // In-popover detail swap (Ben 2026-08-24): tapping a row used to open a
        // SwiftUI `.sheet`, which never renders from an NSPopover-backed
        // MenuBarExtra — the popover just greyed out with nothing on top (the
        // "click Kimi → écran gris" bug). We now swap the list for the resets
        // detail *inside* the same popover, which always renders.
        Group {
            if let detail = calendarSnapshot {
                ResetsCalendarSheet(snapshot: detail, onClose: { calendarSnapshot = nil })
            } else {
                overviewList
            }
        }
    }

    private var overviewList: some View {
        VStack(spacing: 8) {
            controls
            if catalogModel.isPresented {
                AccountCatalogView(model: catalogModel) {
                    withAnimation(.easeOut(duration: 0.15)) { catalogModel.isPresented = false }
                }
            }
            // Tight 4pt gaps between the thin single-line rows (R8) — the
            // controls/footer keep the wider 8pt breathing room above/below.
            VStack(spacing: 4) {
                ForEach(rows) { row in
                    ProviderSnapshotRow(snapshot: row, filter: settings.overviewWindowFilter)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            AppLog.ui.info("Overview row tapped: \(row.providerName) windows=\(row.windows.count) session=\(String(describing: row.windows.first { $0.scope == .session }?.percentRemaining))")
                            calendarSnapshot = row
                        }
                }
            }
            if criticalCount > 0 {
                footer
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            // One-click window selector (R11) — drives display AND sort key.
            Picker("Fenêtre", selection: Binding(
                get: { settings.overviewWindowFilter },
                set: { settings.overviewWindowFilter = $0 }
            )) {
                ForEach(OverviewWindowFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Sort mode: % restant (default) / Reset le plus proche.
            Menu {
                ForEach(OverviewSort.allCases) { sort in
                    Button {
                        settings.overviewSort = sort
                    } label: {
                        if settings.overviewSort == sort {
                            Label(sort.displayName, systemImage: "checkmark")
                        } else {
                            Text(sort.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.glassBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.glassBorder, lineWidth: 1)
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                withAnimation(.easeOut(duration: 0.15)) { catalogModel.isPresented.toggle() }
            } label: {
                Image(systemName: catalogModel.isPresented ? "minus" : "plus")
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundStyle(theme.accentPrimary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.glassBackground))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.glassBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Ajouter un compte (catalogue vérifié) ou activer une connexion")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(theme.font(size: 10))
                .foregroundStyle(theme.statusColor(for: .critical))
            Text("\(criticalCount) fenêtre\(criticalCount > 1 ? "s" : "") sous 10%")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
