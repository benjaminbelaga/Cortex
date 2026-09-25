import SwiftUI
import AppKit
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
    /// Removes a whole provider from Cortex (account-scoped rows use the
    /// catalog's account removal instead). Never touches the tool's own config.
    var onRemoveProvider: ((String) -> Void)? = nil

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

    /// The router's `route_now` block, read from any router-backed provider's
    /// shared snapshot (all instances see the same one). nil → the "Priority"
    /// card renders "llm-router unavailable", never a local computation.
    private var routeNow: RouterRouteNow? {
        providers.compactMap { ($0 as? RouterBackedProvider)?.quotaSnapshot }.first?.routeNow
    }

    /// Shared router snapshot (all RouterBackedProvider instances see the same
    /// one); source of the live catalog families for the preferred-model picker.
    private var routerQuotaSnapshot: RouterQuotaSnapshot? {
        providers.compactMap { ($0 as? RouterBackedProvider)?.quotaSnapshot }.first
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
                ResetsCalendarSheet(
                    snapshot: detail,
                    onClose: { calendarSnapshot = nil },
                    onAddAccountFromPasteboard: ProviderCatalog.apiKeyAccountIDs.contains(detail.providerId)
                        ? { addAccountFromPasteboard(providerId: detail.providerId, providerName: detail.providerName) }
                        : nil,
                    onRemove: {
                        let parts = detail.id.split(separator: "|")
                        let accountId = parts.count > 1 ? String(parts[1]) : nil
                        calendarSnapshot = nil
                        if let accountId {
                            Task { await catalogModel.removeAccount(providerId: detail.providerId, accountId: accountId) }
                        } else {
                            onRemoveProvider?(detail.providerId)
                        }
                    },
                    onOpenConsole: consoleURL(for: detail.providerId) == nil
                        ? nil
                        : { openConsole(providerId: detail.providerId) }
                )
            } else {
                overviewList
            }
        }
    }

    /// The provider's real web console (billing / usage / login), surfaced from
    /// the detail sheet's "Open console" button — NOT from the footer's
    /// Dashboard button, which opens Cortex's own window (Ben 2026-09-26).
    private func consoleURL(for providerId: String) -> URL? {
        providers.first(where: { $0.id == providerId })?.dashboardURL
    }

    private func openConsole(providerId: String) {
        guard let url = consoleURL(for: providerId) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Back to the list with the account catalog open on this provider, then
    /// enrol the pasteboard key there so validation feedback stays visible.
    private func addAccountFromPasteboard(providerId: String, providerName: String) {
        calendarSnapshot = nil
        catalogModel.present(providerId: providerId)
        let fallback = "\(providerName) \(rows.filter { $0.providerId == providerId }.count + 1)"
        Task { await catalogModel.addAPIAccountsFromPasteboard(providerId: providerId, fallbackLabel: fallback) }
    }

    private var overviewList: some View {
        VStack(spacing: 8) {
            PriorityCardView(
                routeNow: routeNow,
                profile: Binding(
                    get: { settings.routeProfile },
                    set: { settings.routeProfile = $0 }
                ),
                expanded: Binding(
                    get: { settings.priorityCardExpanded },
                    set: { settings.priorityCardExpanded = $0 }
                )
            )
            controls
            if catalogModel.isPresented {
                AccountCatalogView(model: catalogModel) {
                    withAnimation(.easeOut(duration: 0.15)) { catalogModel.isPresented = false }
                }
            }
            // Tight 4pt gaps between the thin single-line rows (R8) — the
            // controls/footer keep the wider 8pt breathing room above/below.
            VStack(spacing: 4) {
                ForEach(OverviewBuilder.groups(rows)) { group in
                    if group.isMultiAccount {
                        groupHeader(group)
                        if settings.overviewExpandedGroups.contains(group.providerId) {
                            ForEach(group.rows) { row in
                                accountRow(row, showsPreferred: false).padding(.leading, 12)
                            }
                        }
                    } else if let row = group.rows.first {
                        accountRow(row)
                    }
                }
            }
            if criticalCount > 0 {
                footer
            }
        }
        .onAppear {
            // Pick up any external (CLI) roster change immediately on open,
            // without waiting for a file-system event.
            for provider in providers {
                (provider as? AccountUsageProvider)?.reloadOnAppear()
            }
        }
    }

    // MARK: - Rows

    /// One dashboard row. Member rows of a multi-account group pass
    /// `showsPreferred: false`: the provider's preferred-LLM logo lives ONCE on
    /// the group header (Ben 2026-09-23: "on n'a pas le logo répété 20 000 fois").
    private func accountRow(_ row: ProviderSnapshot, showsPreferred: Bool = true) -> some View {
        ProviderSnapshotRow(
            snapshot: row, filter: settings.overviewWindowFilter,
            preferredModels: showsPreferred ? preferredBadges(forProvider: row.providerId, rowId: row.id) : [],
            onTogglePreferred: showsPreferred ? { togglePreferred($0, rowId: row.id) } : nil,
            offeredFamilies: offeredFamilies(forProvider: row.providerId)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            AppLog.ui.info("Overview row tapped: \(row.providerName) windows=\(row.windows.count)")
            calendarSnapshot = row
        }
    }

    /// Model families the router catalog reports for this provider, so the
    /// picker reflects new families without a Cortex release. Empty when the
    /// router has not reported a family → `ModelFamily.offered` falls back to
    /// the static set.
    private func offeredFamilies(forProvider providerId: String) -> [ModelFamily] {
        let catalogFamilies = routerQuotaSnapshot?.providers.values
            .compactMap(\.family) ?? []
        return ModelFamily.offered(catalogFamilies: catalogFamilies)
    }

    /// Provider-level preferred LLM (Settings → provider) wins; the legacy
    /// row-level multi-select is the fallback so existing choices keep
    /// rendering. A display preference only — never a routing guarantee
    /// (bible §6).
    private func preferredBadges(forProvider providerId: String, rowId: String) -> [ModelFamily] {
        if let raw = settings.providerPreferredModel[providerId],
           let family = ModelFamily(rawValue: raw) {
            return [family]
        }
        return ModelFamily.families(from: settings.preferredModels[rowId] ?? [])
    }

    /// Collapsed-by-default header of a multi-account provider: the most usable
    /// account's bars + "k/N dispo". Tap toggles; the members keep every action.
    private func groupHeader(_ group: ProviderGroup) -> some View {
        let expanded = settings.overviewExpandedGroups.contains(group.providerId)
        var summary = "\(group.usableCount)/\(group.rows.count) available"
        if group.reconnectCount > 0 { summary += " · \(group.reconnectCount) to reconnect" }
        let ids = [group.providerId] + group.rows.map(\.id)
        let union = ids.flatMap { settings.preferredModels[$0] ?? [] }
        let badges: [ModelFamily]
        if let raw = settings.providerPreferredModel[group.providerId],
           let family = ModelFamily(rawValue: raw) {
            badges = [family]
        } else {
            badges = ModelFamily.families(from: union)
        }
        return ProviderSnapshotRow(
            snapshot: group.representative, filter: settings.overviewWindowFilter,
            disclosure: expanded, groupSummary: summary,
            groupCount: group.rows.count,
            preferredModels: badges,
            onTogglePreferred: { togglePreferred($0, rowId: group.providerId) },
            offeredFamilies: offeredFamilies(forProvider: group.providerId)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                if expanded { settings.overviewExpandedGroups.remove(group.providerId) }
                else { settings.overviewExpandedGroups.insert(group.providerId) }
            }
        }
    }

    private func togglePreferred(_ family: ModelFamily, rowId: String) {
        settings.preferredModels[rowId] = PreferredModelsToggle.toggled(
            family, in: settings.preferredModels[rowId]
        )
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            // One-click window selector (R11) — drives display AND sort key.
            Picker("Window", selection: Binding(
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
                Image(systemName: catalogModel.isPresented ? "minus" : "more")
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundStyle(theme.accentPrimary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.glassBackground))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.glassBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Add an account (verified catalog) or enable a connection")

            // Global paste: shapes route themselves (oc_… → OpenCode Go,
            // Ollama form → Ollama). Never forces a provider choice up front.
            Button {
                Task { await catalogModel.addAPIAccountsFromPasteboard(
                    providerId: "opencode-go", fallbackLabel: "Account", autoRoute: true) }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accentPrimary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.glassBackground))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.glassBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Paste API keys: each key joins its provider (OpenCode Go, Ollama)")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(theme.font(size: 10))
                .foregroundStyle(theme.statusColor(for: .critical))
            Text("\(criticalCount) window\(criticalCount > 1 ? "s" : "") under 10%")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
