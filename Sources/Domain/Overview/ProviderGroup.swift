import Foundation

/// One provider in the overview with all its account rows (Ben 2026-09-23:
/// "une flèche qui déplie les abonnements"). Pure value built from the sorted
/// rows — the view only decides whether to show the members.
public struct ProviderGroup: Identifiable, Sendable, Hashable {
    public let providerId: String
    /// Member rows, usable accounts first then by binding-window headroom
    /// descending (ties keep the builder's account order).
    public let rows: [ProviderSnapshot]
    /// The row a collapsed header renders: the most usable account, so the
    /// header answers "can I launch on this provider now?".
    public let representative: ProviderSnapshot
    /// Accounts whose every live window still has room.
    public let usableCount: Int
    /// Accounts waiting for a typed reconnect.
    public let reconnectCount: Int

    public var id: String { providerId }
    public var isMultiAccount: Bool { rows.count > 1 }
}

extension ProviderSnapshot {
    /// Remaining percentage of the BINDING window: the lowest live, non-dollar
    /// window regardless of the display filter. A full 5h window does not make
    /// an account usable when its week is exhausted (bible R36). nil when the
    /// row carries no live percentage at all.
    public var bindingRemaining: Double? {
        windows.filter { !$0.isDollarBased && !$0.isStale }.map(\.percentRemaining).min()
    }

    /// Usable now: no error, no pending reconnect, binding window above zero.
    /// A dollar-only row (credit pool) counts as usable while it has windows.
    public var isUsableNow: Bool {
        guard errorMessage == nil || !windows.isEmpty, !needsReconnect else { return false }
        if let binding = bindingRemaining { return binding > 0 }
        return windows.contains { $0.isDollarBased && !$0.isStale && $0.percentRemaining > 0 }
    }
}

extension OverviewBuilder {
    /// Groups already-sorted rows by provider, preserving the sort order of
    /// the groups and of the accounts inside each group.
    public static func groups(_ sortedRows: [ProviderSnapshot]) -> [ProviderGroup] {
        var order: [String] = []
        var members: [String: [ProviderSnapshot]] = [:]
        for row in sortedRows {
            if members[row.providerId] == nil { order.append(row.providerId) }
            members[row.providerId, default: []].append(row)
        }
        return order.compactMap { providerId in
            guard let rows = members[providerId], let first = rows.first else { return nil }
            let representative = rows.enumerated().max { lhs, rhs in
                let l = (lhs.element.isUsableNow ? 1 : 0, lhs.element.bindingRemaining ?? -1)
                let r = (rhs.element.isUsableNow ? 1 : 0, rhs.element.bindingRemaining ?? -1)
                if l != r { return l < r }
                return lhs.offset > rhs.offset  // ties keep the first account
            }?.element ?? first
            // Member order inside an expanded group: usable accounts first,
            // then by binding-window headroom descending, so the launchable
            // seats float to the top (Ben 2026-09-23). Ties keep account order.
            let sortedRows = rows.enumerated().sorted { lhs, rhs in
                let l = (lhs.element.isUsableNow ? 1 : 0, lhs.element.bindingRemaining ?? -1)
                let r = (rhs.element.isUsableNow ? 1 : 0, rhs.element.bindingRemaining ?? -1)
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            }.map(\.element)
            return ProviderGroup(
                providerId: providerId,
                rows: sortedRows,
                representative: representative,
                usableCount: rows.filter(\.isUsableNow).count,
                reconnectCount: rows.filter(\.needsReconnect).count
            )
        }
    }
}
