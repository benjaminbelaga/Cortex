import Foundation
import Observation

/// A first-class ClaudeBar provider backed by one entry in llm-router's v2
/// snapshot. All instances share a single `RouterQuotaSnapshotProviding`
/// client, so a refresh cycle executes the expensive CLI command only once.
@MainActor
@Observable
public final class RouterBackedProvider: AIProvider, MultiAccountProvider, GroupErrorReporting, ClaudeSupplementProviding, RouterResourceReporting, AccountStateReporting {
    /// The exact inline message for a disconnected account. The overview row
    /// matches on it to render a "Connecter" button instead of dead text.
    public static let reconnectMessage = "Reconnexion requise"

    public let id: String
    public let name: String
    public let cliCommand: String
    public let dashboardURL: URL?
    public let statusPageURL: URL?
    public let routerProviderId: String

    public var isEnabled: Bool {
        didSet { settingsRepository.setEnabled(isEnabled, forProvider: id) }
    }

    public private(set) var isSyncing = false
    public private(set) var snapshot: UsageSnapshot?

    /// The last aggregate router snapshot (the shared brain state, including
    /// the v6 `usage` + `cost_estimate` sections) — exposed read-only for the
    /// global panel; every RouterBackedProvider instance sees the same one.
    public private(set) var quotaSnapshot: RouterQuotaSnapshot?
    public var routerResource: RouterProviderQuota? {
        quotaSnapshot?.providers[routerProviderId]
    }
    public private(set) var lastError: Error?

    public private(set) var accounts: [ProviderAccount] = []
    public private(set) var activeAccount: ProviderAccount
    public private(set) var accountSnapshots: [String: UsageSnapshot] = [:]
    public private(set) var lastGroupErrors: [String: String] = [:]
    /// Typed auth verdict per account, derived from the router's own
    /// `present`/`auth_state` fields — replaces the error-string heuristics
    /// that used to decide reconnect affordances.
    public private(set) var accountAuthStates: [String: AccountAuthState] = [:]

    /// Router-backed accounts refresh together through one shared snapshot,
    /// so the per-account lifecycle is derived from the provider-level state.
    public var accountRefreshStates: [String: ProviderAccountRefreshState] {
        var states: [String: ProviderAccountRefreshState] = [:]
        for account in accounts {
            if accountSnapshots[account.accountId] != nil {
                // Cache-first: a last-known snapshot exists, so show its bars
                // immediately — even while a refresh is in flight. Blanking
                // cached bars behind "Syncing…" on every popover open (isSyncing
                // flips true each open) was the exact friction Ben reported
                // 2026-08-24 ("montrer le truc d'avant"). The background refresh
                // is signalled by the header pill's PulsingStatusDot, not by
                // hiding the row. Only a cold account (no cached snapshot yet)
                // renders the syncing placeholder.
                states[account.accountId] = .ready
            } else if isSyncing {
                states[account.accountId] = .refreshing
            } else if let message = lastGroupErrors[account.accountId] {
                states[account.accountId] = .failed(message: message)
            } else {
                states[account.accountId] = .idle
            }
        }
        return states
    }

    public private(set) var guestPass: ClaudePass?
    public private(set) var isFetchingPasses = false
    public private(set) var passError: Error?
    public var supportsGuestPasses: Bool { guestPassEnabled && passProbe != nil }

    private let source: any RouterQuotaSnapshotProviding
    private let settingsRepository: any MultiAccountSettingsRepository
    private let dailyUsageAnalyzer: (any DailyUsageAnalyzing)?
    private let passProbe: (any ClaudePassProbing)?
    private let guestPassEnabled: Bool

    public init(
        id: String,
        name: String,
        routerProviderId: String,
        cliCommand: String,
        dashboardURL: URL? = nil,
        statusPageURL: URL? = nil,
        source: any RouterQuotaSnapshotProviding,
        settingsRepository: any MultiAccountSettingsRepository,
        dailyUsageAnalyzer: (any DailyUsageAnalyzing)? = nil,
        passProbe: (any ClaudePassProbing)? = nil,
        guestPassEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.routerProviderId = routerProviderId
        self.cliCommand = cliCommand
        self.dashboardURL = dashboardURL
        self.statusPageURL = statusPageURL
        self.source = source
        self.settingsRepository = settingsRepository
        self.dailyUsageAnalyzer = dailyUsageAnalyzer
        self.passProbe = passProbe
        self.guestPassEnabled = guestPassEnabled
        self.isEnabled = settingsRepository.isEnabled(forProvider: id)
        self.activeAccount = ProviderAccount(providerId: id, label: name)
    }

    public func isAvailable() async -> Bool {
        await source.isAvailable()
    }

    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        try await refresh(.interactive)
    }

    @discardableResult
    public func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot {
        isSyncing = true
        defer { isSyncing = false }

        do {
            if quotaSnapshot == nil,
               let lastKnown = await source.lastKnownSnapshot(),
               let provider = lastKnown.providers[routerProviderId] {
                rebuildState(from: provider, aggregate: lastKnown)
                snapshot = accountSnapshots[activeAccount.accountId]
                    ?? makeSnapshot(
                        windows: provider.windows,
                        capturedAt: provider.capturedAt,
                        isStale: true
                    )
            }

            let policy: (force: Bool, usageMaxAge: TimeInterval) = switch kind {
            case .interactive: (true, 0)
            case .opening: (true, 60)
            case .background: (false, 60)
            }
            let aggregate = try await source.snapshot(
                forceRefresh: policy.force,
                usageMaxAgeSeconds: policy.usageMaxAge
            )
            guard let provider = aggregate.providers[routerProviderId] else {
                throw RouterQuotaIssue("llm-router snapshot is missing provider \(routerProviderId)")
            }
            rebuildState(from: provider, aggregate: aggregate)

            let activeSnapshot = accountSnapshots[activeAccount.accountId]
                ?? makeSnapshot(
                    windows: provider.windows,
                    capturedAt: provider.capturedAt,
                    isStale: provider.isStale || provider.error != nil
                )
            snapshot = activeSnapshot

            if activeSnapshot.quotas.isEmpty, let message = provider.error {
                lastError = RouterQuotaIssue(message)
            } else {
                lastError = nil
            }
            return activeSnapshot
        } catch {
            lastError = error
            throw error
        }
    }

    @discardableResult
    public func switchAccount(to accountId: String) -> Bool {
        guard let account = accounts.first(where: { $0.accountId == accountId }) else {
            return false
        }
        activeAccount = account
        settingsRepository.setActiveAccountId(accountId, forProvider: id)
        snapshot = accountSnapshots[accountId]
        return true
    }

    @discardableResult
    public func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
        _ = try await refresh(.interactive)
        guard let accountSnapshot = accountSnapshots[accountId] else {
            let message = lastGroupErrors[accountId] ?? "No quota available for account \(accountId)"
            throw RouterQuotaIssue(message)
        }
        return accountSnapshot
    }

    public func refreshAllAccounts() async {
        _ = try? await refresh(.interactive)
    }

    public func refreshAllAccounts(_ kind: RefreshKind) async {
        _ = try? await refresh(kind)
    }

    /// Account membership is owned by the upstream credential tools, not by
    /// ClaudeBar. Authentication actions therefore never mutate this roster.
    public func addAccount(_ config: ProviderAccountConfig) -> Bool { false }

    @discardableResult
    public func fetchPasses() async throws -> ClaudePass {
        guard let passProbe else { throw PassError.probeNotConfigured }
        isFetchingPasses = true
        defer { isFetchingPasses = false }
        do {
            let pass = try await passProbe.probe()
            guestPass = pass
            passError = nil
            return pass
        } catch {
            passError = error
            throw error
        }
    }

    public func clearPassError() {
        passError = nil
    }

    private func rebuildState(from provider: RouterProviderQuota, aggregate: RouterQuotaSnapshot) {
        quotaSnapshot = aggregate
        let localConfigs = settingsRepository.accounts(forProvider: id)
        let localByAlias = localAccountMap(localConfigs)
        var newAccounts: [ProviderAccount] = []
        var newSnapshots: [String: UsageSnapshot] = [:]
        var newErrors: [String: String] = [:]
        var newAuthStates: [String: AccountAuthState] = [:]

        if provider.accounts.isEmpty {
            let account = ProviderAccount(providerId: id, label: name)
            newAccounts = [account]
            if !provider.windows.isEmpty {
                // Single-account provider: an errored reading (e.g. Kimi's
                // expired credential emitting a phantom 0% session) is stale
                // for health purposes even when the age is fresh.
                newSnapshots[account.accountId] = makeSnapshot(
                    windows: provider.windows,
                    capturedAt: provider.capturedAt,
                    isStale: provider.isStale || provider.error != nil
                )
            }
            if let error = provider.error {
                newErrors[account.accountId] = error
            }
            newAuthStates[account.accountId] = provider.error == nil ? .connected : .unknown
        } else {
            for routerAccount in provider.accounts {
                let alias = routerAccount.alias.uppercased()
                let local = localByAlias[alias]
                let accountId = routerAccount.accountId ?? alias
                let account = ProviderAccount(
                    accountId: accountId,
                    providerId: id,
                    label: alias,
                    email: routerAccount.identity ?? local?.email,
                    organization: local?.organization
                )
                newAccounts.append(account)

                // Typed verdict from the router's own fields — the reconnect
                // affordance reads this, never a message-string heuristic.
                let authState: AccountAuthState
                if !routerAccount.present || routerAccount.authState == "error" {
                    authState = .reconnectRequired
                } else {
                    authState = .connected
                }
                newAuthStates[accountId] = authState

                // A standby account (`!active`) KEEPS its reading — "En veille"
                // is a warning, not data loss. The reading is flagged stale
                // because the router only refreshes the active seat.
                if routerAccount.present, !routerAccount.windows.isEmpty {
                    // Per-account staleness: the provider reading may be fresh
                    // and one account still stale/errored (never conflate the
                    // multi-account provider-level error, which is a union).
                    newSnapshots[accountId] = makeSnapshot(
                        windows: routerAccount.windows,
                        capturedAt: provider.capturedAt,
                        email: routerAccount.identity ?? local?.email,
                        organization: local?.organization,
                        isStale: provider.isStale
                            || !routerAccount.active
                            || routerAccount.stale
                            || routerAccount.error != nil
                    )
                }

                var messages: [String] = []
                if !routerAccount.present {
                    // Real disconnection: the cswap slot lost its credential
                    // lineage — native `claude logout`/`login` overwrites the
                    // live token outside cswap's stash, so the rotating refresh
                    // token dies (invalid_grant → relogin_required). Actionable,
                    // not alarming (Ben 2026-08-24 "reste connecté"). The row
                    // renders a "Connecter" button for this exact message, so
                    // the "(cswap add)" hint is no longer spelled out here.
                    messages.append(Self.reconnectMessage)
                } else if routerAccount.authState == "error" {
                    // Present but the seat's refresh token is dead (broker
                    // auth_state=error, e.g. cswap "re-login needed — refresh
                    // token dead"). NOT a healthy standby: show the guided
                    // "Connecter" button instead of the veille message
                    // (a dead seat used to display only the raw broker error).
                    messages.append(Self.reconnectMessage)
                } else if !routerAccount.active {
                    // Present + valid, simply not the currently-active cswap
                    // slot. This is the NORMAL single-active model, not a
                    // failure — never render "Account is disabled" for a healthy
                    // standby account (was the alarming banner Ben saw).
                    messages.append("En veille — actif sur un autre compte")
                }
                if routerAccount.stale { messages.append("Lecture obsolète") }
                if let error = routerAccount.error { messages.append(error) }
                if !messages.isEmpty {
                    newErrors[accountId] = Array(Set(messages)).sorted().joined(separator: "; ")
                }
            }
        }

        // RETENTION (D — "un compte encore listé perd ses derniers quotas dès
        // qu'une collecte échoue") : an account still on the roster whose
        // current cycle produced no window keeps its previous reading, every
        // quota flagged stale, capture date PRESERVED so the age badge shows
        // the true age of the last good reading.
        for account in newAccounts where newSnapshots[account.accountId] == nil {
            if let previous = accountSnapshots[account.accountId], !previous.quotas.isEmpty {
                newSnapshots[account.accountId] = Self.retainedSnapshot(previous)
            }
        }

        if aggregate.isStale {
            let message = "Using last known llm-router snapshot"
                + (aggregate.fallbackError.map { ": \($0)" } ?? "")
            for account in newAccounts where newErrors[account.accountId] == nil {
                newErrors[account.accountId] = message
            }
        }

        accounts = newAccounts
        accountSnapshots = newSnapshots
        lastGroupErrors = newErrors
        accountAuthStates = newAuthStates

        let persisted = settingsRepository.activeAccountId(forProvider: id)
        let preferred = persisted.flatMap { wanted in
            newAccounts.first { $0.accountId == wanted && newSnapshots[wanted] != nil }
        }
        activeAccount = preferred
            ?? newAccounts.first { newSnapshots[$0.accountId] != nil }
            ?? newAccounts.first
            ?? ProviderAccount(providerId: id, label: name)
        settingsRepository.setActiveAccountId(activeAccount.accountId, forProvider: id)
    }

    /// Retains a previous reading for an account whose current cycle produced
    /// no window: every quota survives re-flagged stale, with the ORIGINAL
    /// capture date (a failed refresh must never reset the age badge).
    private static func retainedSnapshot(_ previous: UsageSnapshot) -> UsageSnapshot {
        UsageSnapshot(
            providerId: previous.providerId,
            quotas: previous.quotas.map { quota in
                UsageQuota(
                    percentRemaining: quota.percentRemaining,
                    quotaType: quota.quotaType,
                    providerId: quota.providerId,
                    resetsAt: quota.resetsAt,
                    resetText: quota.resetText,
                    windowDuration: quota.windowDuration,
                    dollarRemaining: quota.dollarRemaining,
                    dollarUsed: quota.dollarUsed,
                    dollarCap: quota.dollarCap,
                    group: quota.group,
                    compactTitle: quota.compactTitle,
                    menuBarTitle: quota.menuBarTitle,
                    currency: quota.currency,
                    isStale: true
                )
            },
            capturedAt: previous.capturedAt,
            accountEmail: previous.accountEmail,
            accountOrganization: previous.accountOrganization,
            loginMethod: previous.loginMethod,
            accountTier: previous.accountTier,
            costUsage: previous.costUsage,
            bedrockUsage: previous.bedrockUsage,
            dailyUsageReport: previous.dailyUsageReport,
            extensionMetrics: previous.extensionMetrics
        )
    }

    private func localAccountMap(_ configs: [ProviderAccountConfig]) -> [String: ProviderAccountConfig] {
        var result: [String: ProviderAccountConfig] = [:]
        for config in configs {
            // Alias membership belongs to llm-router. Local account metadata is
            // joined only through an explicit alias binding so labels/emails can
            // never silently redefine the shared roster.
            guard let alias = config.probeConfig["routerAlias"]?.uppercased(),
                  !alias.isEmpty, result[alias] == nil else { continue }
            result[alias] = config
        }
        return result
    }

    private func makeSnapshot(
        windows: [RouterQuotaWindow],
        capturedAt: Date,
        email: String? = nil,
        organization: String? = nil,
        isStale: Bool = false
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerId: id,
            quotas: windows.compactMap { window in
                guard let fraction = window.remainingFraction else { return nil }
                return UsageQuota(
                    percentRemaining: (fraction * 100.0).rounded(),
                    quotaType: Self.quotaType(for: window.kind),
                    providerId: id,
                    resetsAt: window.resetsAt,
                    resetText: window.note,
                    compactTitle: Self.compactTitle(for: window.kind),
                    isStale: isStale
                )
            },
            capturedAt: capturedAt,
            accountEmail: email,
            accountOrganization: organization
        )
    }

    private func attachDailyReport(to base: UsageSnapshot) async -> UsageSnapshot {
        guard let dailyUsageAnalyzer,
              let report = try? await dailyUsageAnalyzer.analyzeToday(),
              !report.today.isEmpty || !report.previous.isEmpty else {
            return base
        }
        return UsageSnapshot(
            providerId: base.providerId,
            quotas: base.quotas,
            capturedAt: base.capturedAt,
            accountEmail: base.accountEmail,
            accountOrganization: base.accountOrganization,
            loginMethod: base.loginMethod,
            accountTier: base.accountTier,
            costUsage: base.costUsage,
            bedrockUsage: base.bedrockUsage,
            dailyUsageReport: report,
            extensionMetrics: base.extensionMetrics
        )
    }

    static func quotaType(for kind: String) -> QuotaType {
        let normalized = kind.lowercased()
        if normalized.contains("week") || normalized.contains("seven") || normalized.contains("7d") {
            return .weekly
        }
        if normalized.contains("hour") || normalized.contains("5h") || normalized.contains("session") {
            return .session
        }
        if normalized.contains("scoped") || normalized.contains("model") {
            return .modelSpecific(kind)
        }
        return .timeLimit(kind)
    }

    static func compactTitle(for kind: String) -> String {
        switch quotaType(for: kind) {
        case .session: "5h"
        case .weekly: "7d"
        case .modelSpecific, .timeLimit: kind
        }
    }
}
