import Foundation

/// Pure projection from live providers to overview dashboard rows.
///
/// One row per provider; multi-account providers (e.g., Claude's isolated
/// config directories) contribute one row per account so each identity keeps
/// its own windows. Sort keys honor the window filter and sort mode selected
/// in the dashboard header.
public enum OverviewBuilder {

    // MARK: - Build

    /// Reads @MainActor provider state — call from the main actor (views,
    /// tests marked @MainActor).
    @MainActor
    public static func build(providers: [any AIProvider]) -> [ProviderSnapshot] {
        providers.filter(\.isEnabled).flatMap { provider -> [ProviderSnapshot] in
            let resource = (provider as? any RouterResourceReporting)?.routerResource
            if let multi = provider as? any MultiAccountProvider, !multi.accounts.isEmpty {
                return multi.accounts.map { account in
                    // Per-account refresh lifecycle (ClaudeProvider) unioned
                    // with per-account group errors (router-backed providers):
                    // group errors carry warnings even when a snapshot exists.
                    let refreshState = multi.accountRefreshStates[account.accountId] ?? .idle
                    let accountError = (provider as? any GroupErrorReporting)?
                        .lastGroupErrors[account.accountId]
                        ?? (provider as? any GroupErrorReporting)?
                        .lastGroupErrors[account.displayName]
                    let authState = (provider as? any AccountStateReporting)?
                        .accountAuthStates[account.accountId] ?? .unknown
                    let errorClass = (provider as? any AccountErrorClassReporting)?
                        .accountErrorClasses[account.accountId]
                    guard let snapshot = multi.accountSnapshots[account.accountId] else {
                        // Missing/expired expected accounts stay visible as
                        // warnings; they must not become fake healthy rows.
                        return ProviderSnapshot(
                            id: "\(provider.id)|\(account.accountId)",
                            providerId: provider.id,
                            providerName: provider.name,
                            accountLabel: account.displayName,
                            accountEmail: account.email,
                            windows: [],
                            isSyncing: refreshState == .refreshing,
                            errorMessage: accountError
                                ?? refreshState.errorMessage
                                ?? provider.lastError?.localizedDescription,
                            errorClass: errorClass,
                            authState: authState,
                            resource: resource
                        )
                    }
                    return row(
                        providerId: provider.id,
                        providerName: provider.name,
                        rowId: "\(provider.id)|\(account.accountId)",
                        accountLabel: multi.accounts.count > 1 ? account.displayName : nil,
                        accountEmail: multi.accounts.count > 1 ? account.email : nil,
                        snapshot: snapshot,
                        isSyncing: refreshState == .refreshing,
                        errorMessage: accountError ?? refreshState.errorMessage,
                        errorClass: errorClass,
                        authState: authState,
                        resource: resource
                    )
                }
            }
            // Single-account provider: one row per quota group (aggregating
            // providers like llm-router get one row per upstream LLM),
            // falling back to a single row when no groups are set.
            guard let snapshot = provider.snapshot else {
                if provider.isSyncing {
                    return [ProviderSnapshot(
                        id: provider.id,
                        providerId: provider.id,
                        providerName: provider.name,
                        accountLabel: nil,
                        windows: [],
                        isSyncing: true,
                        errorMessage: provider.lastError?.localizedDescription,
                        resource: resource
                    )]
                }
                return [ProviderSnapshot(
                    id: provider.id,
                    providerId: provider.id,
                    providerName: provider.name,
                    accountLabel: nil,
                    windows: [],
                    isSyncing: false,
                    errorMessage: provider.lastError?.localizedDescription,
                    resource: resource
                )]
            }
            var rows = groupedRows(
                providerId: provider.id,
                providerName: provider.name,
                snapshot: snapshot,
                resource: resource
            )
            // Errored upstream groups (no windows, e.g. Kimi creds expired)
            // become badge rows — visible, never faked.
            if let reporting = provider as? any GroupErrorReporting {
                let withWindows = Set(rows.compactMap(\.accountLabel))
                for (group, message) in reporting.lastGroupErrors.sorted(by: { $0.key < $1.key })
                where !withWindows.contains(group) {
                    rows.append(ProviderSnapshot(
                        id: "\(provider.id)|\(group)",
                        providerId: provider.id,
                        providerName: group,
                        accountLabel: nil,
                        windows: [],
                        isSyncing: false,
                        errorMessage: message,
                        resource: resource
                    ))
                }
            }
            return rows
        }
    }

    /// Splits a snapshot into one row per quota `group`; ungrouped quotas
    /// collapse into a single provider-named row.
    ///
    /// Grouping normalizes nil to "" so the keys are plain Strings (a
    /// nil-keyed dictionary would make every access double-optional).
    private static func groupedRows(
        providerId: String,
        providerName: String,
        snapshot: UsageSnapshot,
        resource: RouterProviderQuota? = nil
    ) -> [ProviderSnapshot] {
        let grouped = Dictionary(grouping: snapshot.quotas) { $0.group ?? "" }
        guard !grouped.isEmpty else {
            return [ProviderSnapshot(
                id: providerId,
                providerId: providerId,
                providerName: providerName,
                accountLabel: nil,
                windows: [],
                resource: resource
            )]
        }
        // A single ""-group bucket keeps the provider's own name; named
        // groups each get their identity as the row title.
        if grouped.count == 1, grouped.keys.first?.isEmpty == true {
            let quotas = grouped[""] ?? []
            return [rowFromQuotas(providerId: providerId, providerName: providerName, rowId: providerId, accountLabel: nil, quotas: quotas, resource: resource)]
        }
        return grouped.keys
            .filter { !$0.isEmpty }
            .sorted()
            .map { key in
                let quotas = grouped[key] ?? []
                return ProviderSnapshot(
                    id: "\(providerId)|\(key)",
                    providerId: providerId,
                    providerName: key,
                    accountLabel: nil,
                    windows: quotas.map(windowSnapshot(rowId: "\(providerId)|\(key)")),
                    resource: resource
                )
            }
    }

    private static func windowSnapshot(rowId: String) -> (UsageQuota) -> WindowSnapshot {
        { quota in
            WindowSnapshot(
                id: "\(rowId)|\(quota.quotaType.displayName)|\(quota.group ?? "")",
                title: quota.compactTitle ?? quota.quotaType.shortLabel,
                percentRemaining: quota.percentRemaining,
                resetsAt: quota.resetsAt,
                compactReset: quota.compactResetTime,
                scope: WindowScope(quotaType: quota.quotaType),
                isDollarBased: quota.isDollarBased,
                formattedDollarRemaining: quota.formattedDollarRemaining,
                isStale: quota.isStale
            )
        }
    }

    private static func rowFromQuotas(
        providerId: String,
        providerName: String,
        rowId: String,
        accountLabel: String?,
        accountEmail: String? = nil,
        quotas: [UsageQuota],
        resource: RouterProviderQuota? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: rowId,
            providerId: providerId,
            providerName: providerName,
            accountLabel: accountLabel,
            accountEmail: accountEmail,
            windows: quotas.map(windowSnapshot(rowId: rowId)),
            resource: resource
        )
    }

    /// Builds one row from a usage snapshot (multi-account path — one row per
    /// account; groups stay together because each account is its own identity).
    private static func row(
        providerId: String,
        providerName: String,
        rowId: String,
        accountLabel: String?,
        accountEmail: String? = nil,
        snapshot: UsageSnapshot,
        isSyncing: Bool = false,
        errorMessage: String? = nil,
        errorClass: String? = nil,
        authState: AccountAuthState = .unknown,
        resource: RouterProviderQuota? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: rowId,
            providerId: providerId,
            providerName: providerName,
            accountLabel: accountLabel,
            accountEmail: accountEmail,
            windows: snapshot.quotas.map(windowSnapshot(rowId: rowId)),
            isSyncing: isSyncing,
            errorMessage: errorMessage,
            errorClass: errorClass,
            authState: authState,
            capturedAt: snapshot.capturedAt,
            resource: resource
        )
    }

    // MARK: - Fleet summary

    /// Menu-bar synthesis of the whole fleet. Honest by construction:
    /// stale windows never color the glyph (a stale 0 % is not an
    /// exhaustion), rows without a reading count as unknown, and a fleet
    /// with no exploitable measurement answers `.unknown` — grey dot,
    /// "Unknown state" — instead of borrowing a green it has no data for.
    public static func fleetSummary(
        rows: [ProviderSnapshot],
        filter: OverviewWindowFilter
    ) -> FleetAvailabilitySummary {
        var usable = 0
        var needsAction = 0
        var unknownCount = 0
        var worst: QuotaStatus?

        for row in rows {
            switch row.dataState {
            case .neverReceived:
                unknownCount += 1
            case .failed:
                needsAction += 1
            case .stale:
                // Known but old: never colors the glyph; still counts as
                // needing action when the credential itself is broken.
                if row.authState == .reconnectRequired { needsAction += 1 }
            case .fresh:
                if row.authState == .reconnectRequired { needsAction += 1 }
                let matching = row.windows
                    .filter { filter.matches($0.scope) && !$0.isDollarBased && !$0.isStale }
                // Windows that do not match the filter (or are dollar-based)
                // feed neither the glyph nor the usable count — they are not
                // fabricated into a status they cannot support.
                guard let worstPercent = matching.map(\.percentRemaining).min() else {
                    continue
                }
                let status = QuotaStatus.from(percentRemaining: worstPercent)
                worst = worst.map { current in
                    current < status ? status : current
                } ?? status
                if status != .depleted { usable += 1 }
            }
        }

        guard let status = worst else {
            if needsAction > 0 {
                return .known(
                    status: .warning,
                    usable: 0,
                    needsAction: needsAction,
                    unknownCount: unknownCount
                )
            }
            return .unknown
        }
        return .known(
            status: status,
            usable: usable,
            needsAction: needsAction,
            unknownCount: unknownCount
        )
    }

    // MARK: - Sort

    /// Sorts rows by the selected mode, using each row's worst window that
    /// matches the filter. Rows without matching windows sink to the bottom
    /// (they are still listed — never hidden).
    ///
    /// Accounts of the same provider travel as ONE group (Ben 2026-09-22:
    /// "il faut qu'ils soient l'un à côté de l'autre") — the group sorts by its
    /// most critical member, so a provider still floats up by severity while
    /// its accounts stay adjacent in account order.
    public static func sort(
        _ snapshots: [ProviderSnapshot],
        by mode: OverviewSort,
        filter: OverviewWindowFilter
    ) -> [ProviderSnapshot] {
        var groupOrder: [String] = []
        var groups: [String: [(offset: Int, snapshot: ProviderSnapshot)]] = [:]
        for (offset, snapshot) in snapshots.enumerated() {
            if groups[snapshot.providerId] == nil { groupOrder.append(snapshot.providerId) }
            groups[snapshot.providerId, default: []].append((offset, snapshot))
        }
        let sortedGroups = groupOrder
            .map { ($0, groups[$0] ?? []) }
            .sorted { lhs, rhs in
                let lhsKey = groupKey(lhs.1, mode: mode, filter: filter)
                let rhsKey = groupKey(rhs.1, mode: mode, filter: filter)
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                return (lhs.1.first?.offset ?? 0) < (rhs.1.first?.offset ?? 0)
            }
        return sortedGroups.flatMap { $0.1.map { $0.snapshot } }
    }

    /// The most critical member key of one provider group.
    private static func groupKey(
        _ members: [(offset: Int, snapshot: ProviderSnapshot)],
        mode: OverviewSort,
        filter: OverviewWindowFilter
    ) -> (rank: Int, value: Double) {
        var best: (rank: Int, value: Double)?
        for member in members {
            let key = sortKey(member.snapshot, mode: mode, filter: filter)
            if best == nil || key < best! { best = key }
        }
        return best ?? (1, 0)
    }

    /// Comparable sort key: nil sorts after every real value.
    private static func sortKey(
        _ snapshot: ProviderSnapshot,
        mode: OverviewSort,
        filter: OverviewWindowFilter
    ) -> (rank: Int, value: Double) {
        guard let worst = snapshot.worstWindow(matching: filter) else {
            return (1, 0) // no matching windows → bottom, stable-ish by id upstream
        }
        switch mode {
        case .percentRemaining:
            let value = worst.isDollarBased ? 101 : worst.percentRemaining
            return (0, value)
        case .timeToReset:
            guard let resetsAt = worst.resetsAt else {
                return (1, 0) // unknown reset → bottom with the no-window rows
            }
            return (0, resetsAt.timeIntervalSince1970)
        }
    }
}

private extension ProviderAccountRefreshState {
    var errorMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}
