import Foundation
import Observation

/// Events emitted during continuous monitoring
public enum MonitoringEvent: Sendable {
    /// A refresh cycle completed
    case refreshed
    /// An error occurred during refresh for a provider
    case error(providerId: String, Error)
}

/// One internally consistent menu-bar choice. The snapshot and optional
/// account always come from the same provider/account so the displayed quota
/// can never be paired with another profile's email.
public struct MenuBarSnapshotSelection: Sendable, Equatable {
    public let snapshot: UsageSnapshot
    public let account: ProviderAccount?

    public init(snapshot: UsageSnapshot, account: ProviderAccount?) {
        self.snapshot = snapshot
        self.account = account
    }
}

/// The main domain service that coordinates quota monitoring across AI providers.
/// Providers are rich domain models that own their own snapshots.
/// QuotaMonitor coordinates refreshes and alerts users when status changes.
///
/// Isolated to `@MainActor` because its `@Observable` state (`isMonitoring`,
/// `selectedProviderId`, …) is consumed by SwiftUI. This keeps the background
/// monitoring loop from mutating observable state off the main actor — the
/// crash in issue #182 — and lets the compiler reject any future off-main
/// mutation. Mirrors `SessionMonitor`, which is already `@MainActor @Observable`.
@MainActor
@Observable
public final class QuotaMonitor {
    /// The providers repository (internal - access via delegation methods)
    private let providers: any AIProviderRepository

    /// Optional alerter for quota changes (e.g., system notifications)
    private let alerter: (any QuotaAlerter)?

    /// Clock for scheduling intervals (injectable for tests)
    private let clock: any Clock

    /// Optional power-state source for energy-aware monitoring. `nil` disables
    /// energy-awareness entirely (the plain timed loop), which is the default for
    /// tests; the app injects a real provider via the convenience init.
    private let powerStateProvider: (any PowerStateProvider)?

    /// Fabrique pilotée par le catalogue (`ProviderComposition.makeProvider`).
    /// Injectée pour que l'activation d'un module optionnel puisse l'instancier
    /// à la demande, sans que la couche Domain ne connaisse la composition.
    private let providerFactory: ProviderFactory?

    /// Fabrique d'un provider à partir de son id de catalogue.
    public typealias ProviderFactory = @MainActor (String) -> (any AIProvider)?

    /// Optional Contract A exporter (v7.2): writes the credential-free roster
    /// llm-router reads back, after each completed overview refresh.
    private let cortexExporter: (any CortexAccountsExporting)?

    /// Previous status for change detection
    private var previousStatuses: [String: QuotaStatus] = [:]
    /// Last observed router time-tariff state per router-backed provider, so
    /// peak/discount transitions alert once and never re-fire every refresh.
    private var previousTimeStates: [String: String] = [:]

    /// Current monitoring task
    private var monitoringTask: Task<Void, Never>?

    private struct OverviewRefreshFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Coalesces popover-open, manual, and background overview requests. A
    /// stronger request queues one follow-up instead of spawning duplicate CLI
    /// trees and daily-usage scans.
    private var overviewRefreshFlight: OverviewRefreshFlight?
    private var activeOverviewKind: RefreshKind?
    private var pendingOverviewKind: RefreshKind?

    /// Whether monitoring is active
    public private(set) var isMonitoring: Bool = false

    /// The currently selected provider ID (for UI display)
    public var selectedProviderId: String = "claude"

    // MARK: - Initialization

    /// Creates a QuotaMonitor with a provider repository.
    /// Automatically validates the selected provider on initialization.
    public init(
        providers: any AIProviderRepository,
        alerter: (any QuotaAlerter)? = nil,
        clock: any Clock,
        powerStateProvider: (any PowerStateProvider)? = nil,
        providerFactory: ProviderFactory? = nil,
        cortexExporter: (any CortexAccountsExporting)? = nil
    ) {
        self.providers = providers
        self.alerter = alerter
        self.clock = clock
        self.powerStateProvider = powerStateProvider
        self.providerFactory = providerFactory
        self.cortexExporter = cortexExporter
        selectFirstEnabledIfNeeded()
    }

    // MARK: - Monitoring Operations

    /// Refreshes all enabled providers concurrently.
    /// Each provider updates its own snapshot.
    /// Disabled providers are skipped.
    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers.enabled {
                group.addTask {
                    await self.refreshProvider(provider)
                }
            }
        }
        // Contract A (v7.2): also publish the roster from the background loop,
        // not only when the overview is open — llm-router must have Ben's full
        // account picture even while the popover is closed (else it falls back
        // to the native single/dual-account probes).
        cortexExporter?.exportAfterRefresh(providers: providers.all)
    }

    /// Refreshes the overview's complete data set. Multi-account providers
    /// refresh every account, while ordinary providers keep their established
    /// active/single refresh behavior.
    public func refreshOverview(kind: RefreshKind = .interactive) async {
        if let flight = overviewRefreshFlight {
            if kind.priority > (activeOverviewKind?.priority ?? -1),
               kind.priority > (pendingOverviewKind?.priority ?? -1) {
                pendingOverviewKind = kind
            }
            await flight.task.value
            return
        }

        let id = UUID()
        let task = Task { await self.runOverviewRefreshQueue(startingWith: kind) }
        overviewRefreshFlight = OverviewRefreshFlight(id: id, task: task)
        await task.value
        if overviewRefreshFlight?.id == id {
            overviewRefreshFlight = nil
            activeOverviewKind = nil
            pendingOverviewKind = nil
        }
    }

    private func runOverviewRefreshQueue(startingWith initialKind: RefreshKind) async {
        var kind = initialKind
        while true {
            activeOverviewKind = kind
            pendingOverviewKind = nil
            await performOverviewRefresh(kind: kind)
            guard let next = pendingOverviewKind, next.priority > kind.priority else { return }
            kind = next
        }
    }

    private func performOverviewRefresh(kind: RefreshKind) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers.enabled {
                group.addTask {
                    if let multi = provider as? any MultiAccountProvider {
                        await multi.refreshAllAccounts(kind)
                    } else {
                        await self.refreshProvider(provider, kind: kind)
                    }
                }
            }
        }
        // Contract A (v7.2): publish the credential-free roster once the cycle
        // has settled, so llm-router reads the freshest windows.
        cortexExporter?.exportAfterRefresh(providers: providers.all)
    }

    /// Refreshes a single provider.
    /// `kind` defaults to `.interactive`; the background monitoring loop passes
    /// `.background` so providers can skip non-glanceable work (issue #204).
    private func refreshProvider(_ provider: any AIProvider, kind: RefreshKind = .interactive) async {
        guard provider.isEnabled else { return }
        guard await provider.isAvailable() else {
            return
        }

        if let multi = provider as? any MultiAccountProvider {
            await multi.refreshAllAccounts(kind)
            if let snapshot = multi.snapshot {
                await handleSnapshotUpdate(provider: provider, snapshot: snapshot)
            }
            return
        }

        do {
            let snapshot = try await provider.refresh(kind)
            await handleSnapshotUpdate(provider: provider, snapshot: snapshot)
        } catch {
            // Provider stores error in lastError - no need for external observer
        }
    }

    /// Handles snapshot update and alerts user if status changed
    private func handleSnapshotUpdate(provider: any AIProvider, snapshot: UsageSnapshot) async {
        let previousStatus = previousStatuses[provider.id] ?? .healthy
        let newStatus = snapshot.overallStatus

        previousStatuses[provider.id] = newStatus

        // Alert user only if status changed
        if previousStatus != newStatus, let alerter = alerter {
            await alerter.alert(
                providerId: provider.id,
                previousStatus: previousStatus,
                currentStatus: newStatus
            )
        }

        // Router time-tariff transitions (peak/discount, bible §15). Only
        // router-backed providers report one; alert once per real flip, never
        // on the first observation (previous == nil).
        if let reporting = provider as? RouterTimeStateReporting,
           let timeState = reporting.routerTimeState {
            let previous = previousTimeStates[provider.id]
            previousTimeStates[provider.id] = timeState.state
            if let previous, previous != timeState.state, let alerter {
                await alerter.alertTimeState(
                    providerId: provider.id, previous: previous, current: timeState
                )
            }
        }
    }

    /// Refreshes a single provider by its ID.
    public func refresh(providerId: String, kind: RefreshKind = .interactive) async {
        guard let provider = providers.provider(id: providerId) else {
            return
        }
        await refreshProvider(provider, kind: kind)
    }

    /// Refreshes the given providers once, preserving order and removing duplicates.
    public func refresh(providerIds: [String], kind: RefreshKind = .interactive) async {
        await refresh(providerIds: providerIds, allAccountsForProviderId: nil, kind: kind)
    }

    /// Refreshes a provider set and, for the designated menu-bar provider,
    /// refreshes all accounts so worst-account selection never goes stale.
    public func refresh(
        providerIds: [String],
        allAccountsForProviderId: String?,
        kind: RefreshKind = .interactive
    ) async {
        var seen = Set<String>()
        let uniqueProviderIds = providerIds.filter { providerId in
            seen.insert(providerId).inserted
        }
        // Resolve repository membership on the main actor before entering
        // child tasks. AIProvider instances are Sendable/MainActor-isolated;
        // the repository lookup itself is not valid from a task-group closure.
        let refreshTargets: [(providerId: String, provider: any AIProvider)] = uniqueProviderIds.compactMap { providerId in
            guard let provider = providers.provider(id: providerId) else { return nil }
            return (providerId, provider)
        }

        await withTaskGroup(of: Void.self) { group in
            for target in refreshTargets {
                group.addTask {
                    if target.providerId == allAccountsForProviderId,
                       let multi = target.provider as? any MultiAccountProvider {
                        await multi.refreshAllAccounts(kind)
                    } else {
                        await self.refreshProvider(target.provider, kind: kind)
                    }
                }
            }
        }
    }

    /// Refreshes all enabled providers except the specified one.
    public func refreshOthers(except providerId: String) async {
        let otherProviders = providers.enabled.filter { $0.id != providerId }

        await withTaskGroup(of: Void.self) { group in
            for provider in otherProviders {
                group.addTask {
                    await self.refreshProvider(provider)
                }
            }
        }
    }

    // MARK: - Queries

    /// Returns the provider with the given ID
    public func provider(for id: String) -> (any AIProvider)? {
        providers.provider(id: id)
    }

    /// Returns all providers
    public var allProviders: [any AIProvider] {
        providers.all
    }

    /// Returns only enabled providers
    public var enabledProviders: [any AIProvider] {
        providers.enabled
    }

    /// Adds a provider dynamically
    public func addProvider(_ provider: any AIProvider) {
        providers.add(provider)
    }

    /// Removes a provider by ID
    public func removeProvider(id: String) {
        providers.remove(id: id)
    }

    /// Active le SUIVI d'un module et le rend visible immédiatement.
    ///
    /// Si l'id n'a pas d'instance (module optionnel jamais instancié au
    /// lancement), la fabrique du catalogue le construit, la clé de suivi est
    /// persistée par le provider lui-même, puis une collecte part. Idempotent :
    /// une seule instance par id, jamais deux collecteurs.
    ///
    /// Retourne `false` quand aucune instance n'a pu être obtenue (id inconnu du
    /// catalogue ou fabrique absente) — l'appelant doit alors le dire à
    /// l'utilisateur plutôt que d'échouer en silence.
    @discardableResult
    public func follow(providerId: String) -> Bool {
        if let existing = providers.provider(id: providerId) {
            existing.isEnabled = true
            Task { await self.refresh(providerId: providerId, kind: .interactive) }
            return true
        }
        guard let provider = providerFactory?(providerId) else {
            return false
        }
        provider.isEnabled = true
        addProvider(provider)
        Task { await self.refresh(providerId: providerId, kind: .interactive) }
        return true
    }

    /// Arrête la collecte SANS retirer l'instance : la ligne et son dernier
    /// relevé restent visibles (rétention), les alertes cessent — un provider
    /// désactivé n'est plus parcouru par `refreshAll`.
    public func unfollow(providerId: String) {
        guard let provider = providers.provider(id: providerId) else { return }
        provider.isEnabled = false
        selectFirstEnabledIfNeeded()
    }

    /// Remplace l'instance d'un id (changement de source routeur ↔ natif) :
    /// l'ancienne quitte le repository avant que la nouvelle n'entre, donc une
    /// seule instance collecte à tout instant. L'état d'alerte de l'id est remis
    /// à zéro pour que la comparaison ne traverse jamais deux sources.
    ///
    /// Les rafraîchissements sont des appels `await` bornés (aucune tâche
    /// détachée par provider) : une instance retirée peut au pire écrire un
    /// dernier snapshot dans sa propre copie, jamais dans la nouvelle.
    @discardableResult
    public func replaceProvider(_ provider: any AIProvider) -> Bool {
        let id = provider.id
        removeProvider(id: id)
        previousStatuses.removeValue(forKey: id)
        previousTimeStates.removeValue(forKey: id)
        provider.isEnabled = true
        addProvider(provider)
        Task { await self.refresh(providerId: id, kind: .interactive) }
        return true
    }

    /// Returns the lowest quota across all enabled providers
    public func lowestQuota() -> UsageQuota? {
        providers.enabled
            .compactMap(\.snapshot?.lowestQuota)
            .min()
    }

    /// Returns the selected quota for a provider from enabled provider snapshots.
    public func quota(providerId: String, quotaKey: String) -> UsageQuota? {
        providers.enabled
            .first { $0.id == providerId }?
            .snapshot?
            .quota(forKey: quotaKey)
    }

    /// Selects the worst account snapshot for the requested menu-bar windows.
    /// Ties are stable by account ID, avoiding label/email flicker between ticks.
    public func menuBarSnapshotSelection(
        providerId: String,
        quotaKeys: [String]
    ) -> MenuBarSnapshotSelection? {
        guard let provider = providers.enabled.first(where: { $0.id == providerId }) else {
            return nil
        }
        guard let multi = provider as? any MultiAccountProvider else {
            return provider.snapshot.map { MenuBarSnapshotSelection(snapshot: $0, account: nil) }
        }

        let requestedKeys = quotaKeys.filter { !$0.isEmpty }
        let candidates = multi.accounts.compactMap { account -> (ProviderAccount, UsageSnapshot, Double)? in
            guard let snapshot = multi.accountSnapshots[account.accountId] else { return nil }
            let requestedPercents = requestedKeys.compactMap { snapshot.quota(forKey: $0)?.percentRemaining }
            guard let score = requestedPercents.min() else { return nil }
            return (account, snapshot, score)
        }
        let selected = candidates.min { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.0.accountId < rhs.0.accountId : lhs.2 < rhs.2
        }
        if let selected {
            return MenuBarSnapshotSelection(snapshot: selected.1, account: selected.0)
        }

        // No account exposes a requested window yet. Keep the active cached
        // snapshot as a deterministic compatibility fallback.
        guard let snapshot = multi.accountSnapshots[multi.activeAccount.accountId] ?? provider.snapshot else {
            return nil
        }
        return MenuBarSnapshotSelection(snapshot: snapshot, account: multi.activeAccount)
    }

    /// Returns the menu bar percentage display for a provider/quota selection.
    public func menuBarPercentageDisplay(
        providerId: String,
        quotaKey: String,
        mode: UsageDisplayMode,
        burnRateWarningEnabled: Bool = false,
        burnRateThreshold: Double = 1.5
    ) -> MenuBarPercentageDisplay? {
        guard let quota = quota(providerId: providerId, quotaKey: quotaKey) else {
            return nil
        }

        return MenuBarPercentageDisplay(
            quota: quota,
            mode: mode,
            burnRateWarningEnabled: burnRateWarningEnabled,
            burnRateThreshold: burnRateThreshold
        )
    }

    /// Returns the menu bar duration display for a provider/quota selection.
    /// Sibling to `menuBarPercentageDisplay`; both use the same selectors.
    public func menuBarDurationDisplay(
        providerId: String,
        quotaKey: String,
        burnRateWarningEnabled: Bool = false,
        burnRateThreshold: Double = 1.5
    ) -> MenuBarDurationDisplay? {
        guard let quota = quota(providerId: providerId, quotaKey: quotaKey) else {
            return nil
        }

        return MenuBarDurationDisplay(
            quota: quota,
            burnRateWarningEnabled: burnRateWarningEnabled,
            burnRateThreshold: burnRateThreshold
        )
    }

    /// Additional providers use their first quota and include a name so adjacent
    /// readouts remain distinguishable. Enabled providers awaiting data keep a placeholder.
    public func additionalMenuBarLabels(
        providerIds: [String],
        configurations: [String: MenuBarProviderSettings] = [:],
        showPercentage: Bool,
        showDuration: Bool,
        mode: UsageDisplayMode,
        burnRateWarningEnabled: Bool = false,
        burnRateThreshold: Double = 1.5
    ) -> [MenuBarProviderLabel] {
        guard showPercentage || showDuration else { return [] }
        var seen = Set<String>()
        return providerIds.filter { seen.insert($0).inserted }.prefix(2).compactMap { id in
            guard let provider = enabledProviders.first(where: { $0.id == id }) else { return nil }
            let config = configurations[id] ?? MenuBarProviderSettings()
            let key = config.primaryQuotaKey.isEmpty
                ? provider.snapshot?.quotas.first?.quotaType.quotaKey : config.primaryQuotaKey
            guard let key,
                  let label = menuBarLabel(
                    providerId: id, primaryQuotaKey: key, secondaryQuotaKey: config.secondaryQuotaKey,
                    showPercentage: showPercentage, showDuration: showDuration,
                    mode: mode, burnRateWarningEnabled: burnRateWarningEnabled,
                    burnRateThreshold: burnRateThreshold
                  ) else {
                return MenuBarProviderLabel(providerId: id, providerName: provider.name,
                                            label: MenuBarLabel(text: "—", status: .healthy))
            }
            return MenuBarProviderLabel(providerId: id, providerName: provider.name, label: label,
                                        stacked: config.stacked, stackedSize: MenuBarStackedSize(storedRawValue: config.stackedSize))
        }
    }

    /// Builds the fully composed menu bar label for one or two quota windows.
    ///
    /// The primary window renders exactly as the single-window label always has
    /// (percentage and/or duration joined by " · "). When `secondaryQuotaKey` is
    /// non-empty and differs from the primary, a second window is appended: each
    /// window is prefixed with the quota's `menuBarTitle` when the probe set one
    /// (a condensed form of labels too wide for the menu bar), otherwise its
    /// `QuotaType.shortLabel`, and the two are joined by " | ", e.g.
    /// "5h 12% | 7d 34%". The status is the most severe of the
    /// shown windows, and each window is also exposed individually via
    /// `MenuBarLabel.segments` for renderers that draw them on separate lines.
    ///
    /// Returns nil when neither percentage nor duration is enabled, or when no
    /// quota data is available for the requested windows.
    public func menuBarLabel(
        providerId: String,
        primaryQuotaKey: String,
        secondaryQuotaKey: String = "",
        showPercentage: Bool,
        showDuration: Bool,
        mode: UsageDisplayMode,
        burnRateWarningEnabled: Bool = false,
        burnRateThreshold: Double = 1.5
    ) -> MenuBarLabel? {
        // Upstream parity (U0 merge): an EMPTY primary key means "whatever the
        // provider's first quota is" — fall back to it before selection so a
        // fresh install without an explicit choice still shows a percentage.
        let effectivePrimaryKey = primaryQuotaKey.isEmpty
            ? (enabledProviders.first { $0.id == providerId }?
                .snapshot?.quotas.first?.quotaType.quotaKey ?? "")
            : primaryQuotaKey
        let selection = menuBarSnapshotSelection(
            providerId: providerId,
            quotaKeys: [effectivePrimaryKey, secondaryQuotaKey]
        )

        func selectedQuota(_ quotaKey: String) -> UsageQuota? {
            selection?.snapshot.quota(forKey: quotaKey)
        }

        func segment(forQuotaKey quotaKey: String) -> (text: String, status: QuotaStatus, percentRemaining: Double?)? {
            let quota = selectedQuota(quotaKey)
            let percentage = showPercentage ? quota.map {
                MenuBarPercentageDisplay(
                    quota: $0,
                    mode: mode,
                    burnRateWarningEnabled: burnRateWarningEnabled,
                    burnRateThreshold: burnRateThreshold
                )
            } : nil
            let duration = showDuration ? quota.map {
                MenuBarDurationDisplay(
                    quota: $0,
                    burnRateWarningEnabled: burnRateWarningEnabled,
                    burnRateThreshold: burnRateThreshold
                )
            } : nil
            // Pull the raw percent from the snapshot so progress-bar renderers
            // (Phase 7 dual-bar) have a number to draw — independent of the
            // percentage display setting above (which only affects the text).
            let percentRemaining: Double? = quota?.percentRemaining

            switch (percentage, duration) {
            case let (.some(percentage), .some(duration)):
                return ("\(percentage.text) · \(duration.text)", percentage.status, percentRemaining)
            case let (.some(percentage), .none):
                return (percentage.text, percentage.status, percentRemaining)
            case let (.none, .some(duration)):
                return (duration.text, duration.status, percentRemaining)
            case (.none, .none):
                return nil
            }
        }

        let primary = segment(forQuotaKey: effectivePrimaryKey)
        let secondary = (!secondaryQuotaKey.isEmpty && secondaryQuotaKey != effectivePrimaryKey)
            ? segment(forQuotaKey: secondaryQuotaKey)
            : nil

        switch (primary, secondary) {
        case let (.some(primary), .some(secondary)):
            // Window prefix: the quota's own condensed menu-bar title wins
            // (probes set it when the full label is too wide, e.g. a long
            // account discriminator), then the type's short label.
            func windowPrefix(forQuotaKey quotaKey: String) -> String {
                if let title = selectedQuota(quotaKey)?.menuBarTitle {
                    return title
                }
                return QuotaType(quotaKey: quotaKey)?.shortLabel ?? quotaKey
            }
            let primaryLabel = windowPrefix(forQuotaKey: effectivePrimaryKey)
            let secondaryLabel = windowPrefix(forQuotaKey: secondaryQuotaKey)
            // Each window becomes its own segment (prefixed text + that
            // window's status + raw percent) so stacked rendering can draw
            // and tint them independently; the joined text stays the canonical
            // single-line form and doubles as the tooltip.
            let primarySegment = MenuBarLabel.Segment(
                text: "\(primaryLabel) \(primary.text)",
                status: primary.status,
                percentRemaining: primary.percentRemaining
            )
            let secondarySegment = MenuBarLabel.Segment(
                text: "\(secondaryLabel) \(secondary.text)",
                status: secondary.status,
                percentRemaining: secondary.percentRemaining
            )
            return MenuBarLabel(
                text: "\(primarySegment.text) | \(secondarySegment.text)",
                status: max(primary.status, secondary.status),
                segments: [primarySegment, secondarySegment]
            )
        case let (.some(primary), .none):
            return MenuBarLabel(text: primary.text, status: primary.status)
        case let (.none, .some(secondary)):
            return MenuBarLabel(text: secondary.text, status: secondary.status)
        case (.none, .none):
            return nil
        }
    }

    /// Returns the overall status across enabled providers (worst status wins)
    public var overallStatus: QuotaStatus {
        providers.enabled
            .compactMap(\.snapshot?.overallStatus)
            .max() ?? .healthy
    }

    // MARK: - Selection

    /// The currently selected provider (from enabled providers)
    public var selectedProvider: (any AIProvider)? {
        providers.enabled.first { $0.id == selectedProviderId }
    }

    /// Status of the currently selected provider (for menu bar icon)
    public var selectedProviderStatus: QuotaStatus {
        selectedProvider?.snapshot?.overallStatus ?? .healthy
    }

    /// Whether any provider is currently refreshing
    public var isRefreshing: Bool {
        providers.all.contains { provider in
            if provider.isSyncing { return true }
            guard let multi = provider as? any MultiAccountProvider else { return false }
            return multi.accountRefreshStates.values.contains(.refreshing)
        }
    }

    /// Selects a provider by ID (must be enabled)
    public func selectProvider(id: String) {
        if providers.enabled.contains(where: { $0.id == id }) {
            selectedProviderId = id
        }
    }

    /// Sets a provider's enabled state.
    /// When disabling the currently selected provider, automatically switches
    /// to the first available enabled provider.
    public func setProviderEnabled(_ id: String, enabled: Bool) {
        guard let provider = providers.provider(id: id) else { return }
        provider.isEnabled = enabled
        if !enabled {
            selectFirstEnabledIfNeeded()
        }
    }

    /// Selects the first enabled provider if current selection is invalid.
    /// Called automatically during initialization and when providers are disabled.
    private func selectFirstEnabledIfNeeded() {
        if !providers.enabled.contains(where: { $0.id == selectedProviderId }),
           let firstEnabled = providers.enabled.first {
            selectedProviderId = firstEnabled.id
        }
    }

    // MARK: - Continuous Monitoring

    /// The hard lower bound on the monitoring interval. Background refresh must
    /// never poll faster than once a minute (energy — issue #67).
    public static let minimumInterval: Duration = .seconds(60)

    /// How much to stretch the background cadence while on battery, to reduce
    /// drain when unplugged (issue #204). Applied on top of the effective
    /// interval each tick, so plugging back in restores the normal cadence.
    public static let batteryIntervalMultiplier: Int = 2

    /// Clamps a requested interval to the 1-minute floor. Exposed so the floor
    /// can be unit-tested directly and so every caller funnels through one rule.
    public static func clampedInterval(_ interval: Duration) -> Duration {
        max(interval, minimumInterval)
    }

    /// The actual sleep interval for one background monitoring tick: the
    /// requested interval clamped to the 1-minute floor, then raised to the
    /// slowest provider-imposed `backgroundRefreshFloor` in the active set.
    ///
    /// The slowest floor wins for a multi-provider set (e.g. Claude in API mode
    /// floors the loop at 15 min — issue #204), which is acceptable for a
    /// background glance. Pure and static so it can be unit-tested directly.
    public static func effectiveInterval(requested: Duration, floors: [Duration]) -> Duration {
        max(clampedInterval(requested), floors.max() ?? .zero)
    }

    /// Refreshes only the currently selected provider.
    public func refreshSelected(kind: RefreshKind = .interactive) async {
        await refresh(providerId: selectedProviderId, kind: kind)
    }

    /// The `backgroundRefreshFloor`s declared by the providers refreshed each
    /// cycle — the supplied set, or the currently selected provider when none is
    /// given (mirroring how `startMonitoring` chooses what to refresh).
    ///
    /// Resolved fresh each tick so a live probe-mode switch (CLI↔API) is honored
    /// without restarting the loop: the menu-bar refresh key doesn't observe
    /// `probeMode`, so the cadence would otherwise stay stale (issue #204).
    private func backgroundRefreshFloors(for providerIds: [String]?) -> [Duration] {
        let ids = providerIds ?? [selectedProviderId]
        return ids.compactMap { providers.provider(id: $0)?.backgroundRefreshFloor }
    }

    /// Starts continuous monitoring at the specified interval.
    /// By default, refreshes the currently selected provider each cycle to minimize energy usage.
    /// When provider IDs are supplied, refreshes that de-duplicated provider set each cycle.
    /// The effective cadence is the requested interval clamped to a 1-minute
    /// floor, then raised to the slowest provider-imposed `backgroundRefreshFloor`
    /// in the active set (recomputed each tick so a live probe-mode switch is
    /// honored without restarting). Returns an AsyncStream of monitoring events.
    public func startMonitoring(
        interval: Duration = .seconds(60),
        providerIds: [String]? = nil,
        allAccountsForProviderId: String? = nil
    ) -> AsyncStream<MonitoringEvent> {
        // Stop any existing monitoring
        monitoringTask?.cancel()

        isMonitoring = true

        return AsyncStream { continuation in
            let task = Task {
                // Iterator over power transitions; nil when energy-awareness is
                // disabled (no power provider), so the loop below behaves exactly
                // like the plain timed loop in that case.
                var powerEvents = self.powerStateProvider?.events().makeAsyncIterator()

                while !Task.isCancelled {
                    // Energy awareness: while the display/system is asleep, pause
                    // — no refresh and no probe subprocess spawn — and wait for
                    // the next wake event so we can refresh immediately when the
                    // user returns (issue #204). A nil power provider skips this
                    // entirely. `AsyncStream.next()` resumes with nil on task
                    // cancellation, so `stopMonitoring()` unparks the loop.
                    while let power = self.powerStateProvider,
                          power.isDisplayAsleep,
                          !Task.isCancelled {
                        guard await powerEvents?.next() != nil else { break }
                        // Re-check `isDisplayAsleep`: a `.didWake` clears it and
                        // we fall through to an immediate refresh.
                    }
                    if Task.isCancelled { break }

                    // The continuous loop is the background poll: refresh with
                    // `.background` so providers skip non-glanceable work, and
                    // bind a low (`.utility`) QoS so any CLI subprocess spawned
                    // during the refresh runs on efficiency cores / throttled —
                    // both keep idle energy use low (issue #204).
                    await ProbeExecutionContext.$qualityOfService.withValue(.utility) {
                        if let providerIds {
                            await self.refresh(
                                providerIds: providerIds,
                                allAccountsForProviderId: allAccountsForProviderId,
                                kind: .background
                            )
                        } else {
                            await self.refreshSelected(kind: .background)
                        }
                    }
                    // Contract A (v7.2): publish the full roster every background
                    // tick (freshest-known windows for all providers), so
                    // llm-router has Ben's complete account picture even when the
                    // popover is closed — not just after an overview refresh.
                    self.cortexExporter?.exportAfterRefresh(providers: self.providers.all)
                    continuation.yield(.refreshed)

                    // Compute the sleep each tick: the requested interval clamped
                    // to the 1-minute floor, then raised to any provider-imposed
                    // background floor (e.g. Claude API → 15 min). Resolved per
                    // tick so a live CLI↔API switch is honored without restarting.
                    let floors = self.backgroundRefreshFloors(for: providerIds)
                    var sleepInterval = Self.effectiveInterval(requested: interval, floors: floors)

                    // Stretch the cadence while on battery to reduce drain (#204).
                    if self.powerStateProvider?.isOnBattery == true {
                        sleepInterval = sleepInterval * Self.batteryIntervalMultiplier
                    }

                    do {
                        try await clock.sleep(for: sleepInterval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }

            self.monitoringTask = task

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Stops continuous monitoring
    public func stopMonitoring() {
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }
}
