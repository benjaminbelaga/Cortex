import Foundation
import Observation

/// Claude AI provider - a rich domain model.
/// Observable class with its own state (isSyncing, snapshot, error).
/// Supports dual probe modes: CLI (default) and API.
@MainActor
@Observable
public final class ClaudeProvider: AIProvider, MultiAccountProvider {
    // MARK: - Identity (Protocol Requirement)

    public let id: String = "claude"
    public let name: String = "Claude"
    public let cliCommand: String = "claude"

    public var dashboardURL: URL? {
        URL(string: "https://console.anthropic.com/settings/billing")
    }

    public var statusPageURL: URL? {
        URL(string: "https://status.anthropic.com")
    }

    /// Whether the provider is enabled (persisted via settingsRepository)
    public var isEnabled: Bool {
        didSet {
            settingsRepository.setEnabled(isEnabled, forProvider: id)
        }
    }

    // MARK: - State (Observable)

    /// Whether the provider is currently syncing data
    public private(set) var isSyncing: Bool = false

    /// The current usage snapshot (nil if never refreshed or unavailable)
    public private(set) var snapshot: UsageSnapshot?

    /// The last error that occurred during refresh
    public private(set) var lastError: Error?

    /// The current guest pass information (nil if never fetched)
    public private(set) var guestPass: ClaudePass?

    /// Whether the provider is currently fetching passes
    public private(set) var isFetchingPasses: Bool = false

    /// The last error from a guest pass fetch (nil when the last fetch succeeded).
    /// Kept separate from `lastError` so a failed invitation-link fetch never
    /// makes the provider's usage data look unavailable.
    public private(set) var passError: Error?

    // MARK: - Multi-Account State

    /// All configured Claude accounts. Always contains at least the default account.
    public private(set) var accounts: [ProviderAccount] = []

    /// The currently active account (whose snapshot is exposed via `snapshot`).
    public private(set) var activeAccount: ProviderAccount = ProviderAccount(
        accountId: ProviderAccount.defaultAccountId,
        providerId: "claude",
        label: "Default"
    )

    /// Snapshots for all accounts (keyed by account ID).
    public private(set) var accountSnapshots: [String: UsageSnapshot] = [:]

    /// Independent refresh lifecycle for every configured account.
    public private(set) var accountRefreshStates: [String: ProviderAccountRefreshState] = [:]

    /// Probes for each configured account.
    private var accountProbes: [String: AccountProbes] = [:]

    /// Factories for creating per-account probes.
    private let cliProbeFactory: (String?) -> any UsageProbe
    private let apiProbeFactory: (String?) -> (any UsageProbe)?
    /// Factory for the passive status-line probe (D2, opt-in). Nil disables
    /// the status-line tier entirely — the legacy initializer leaves it nil.
    private let statusLineProbeFactory: ((String?) -> (any UsageProbe)?)?

    /// Per-account probe triple.
    private struct AccountProbes {
        let cli: any UsageProbe
        let api: (any UsageProbe)?
        /// Passive status-line observation (D2, opt-in). Checked last, only
        /// when the adapter is enabled — the probe itself gates on the setting
        /// plus observation freshness, so a disabled adapter is invisible here.
        let statusLine: (any UsageProbe)?

        func active(for mode: ClaudeProbeMode) -> any UsageProbe {
            switch mode {
            case .cli:
                return cli
            case .api:
                return api ?? cli
            }
        }

        /// Ordered fallback tiers for the mode, each returned only when it
        /// reports itself available. Every tier that answers is offered in
        /// turn, so a failing CLI fallback still reaches the passive
        /// status-line tier instead of ending the chain.
        func fallbackTiers(for mode: ClaudeProbeMode, cliFallbackEnabled: Bool) async -> [any UsageProbe] {
            switch mode {
            case .cli:
                var tiers: [any UsageProbe] = []
                if let api, await api.isAvailable() { tiers.append(api) }
                if let statusLine, await statusLine.isAvailable() { tiers.append(statusLine) }
                return tiers
            case .api:
                var tiers: [any UsageProbe] = []
                if cliFallbackEnabled, await cli.isAvailable() { tiers.append(cli) }
                if let statusLine, await statusLine.isAvailable() { tiers.append(statusLine) }
                return tiers
            }
        }
    }

    // MARK: - Probe Mode

    /// The current probe mode (CLI or API)
    public var probeMode: ClaudeProbeMode {
        get {
            // Only use ClaudeSettingsRepository if available
            if let claudeSettings = settingsRepository as? ClaudeSettingsRepository {
                return claudeSettings.claudeProbeMode()
            }
            return .cli
        }
        set {
            if let claudeSettings = settingsRepository as? ClaudeSettingsRepository {
                claudeSettings.setClaudeProbeMode(newValue)
            }
        }
    }

    /// Background poll cadence floor. In API mode, background refreshes are
    /// floored at 15 min to match `ClaudeAPIUsageProbe`'s snapshot-cache TTL:
    /// polling faster only re-serves the cache (or, once expired, risks 429s),
    /// so there's no benefit to a tighter background cadence (issue #204). CLI
    /// mode keeps the user's chosen interval (no floor).
    public var backgroundRefreshFloor: Duration? {
        switch probeMode {
        case .api: return .seconds(900)
        case .cli: return nil
        }
    }

    // MARK: - Internal

    /// The CLI probe for fetching usage data via `claude /usage`
    private let cliProbe: any UsageProbe

    /// The API probe for fetching usage data via HTTP API (optional)
    private let apiProbe: (any UsageProbe)?

    /// The probe used to fetch guest pass data
    private let passProbe: (any ClaudePassProbing)?

    /// The settings repository for persisting provider settings
    private let settingsRepository: any ProviderSettingsRepository

    /// Optional analyzer for daily usage from JSONL session data
    private let dailyUsageAnalyzer: (any DailyUsageAnalyzing)?

    /// Returns the probe pair for the active account.
    private var activeProbes: AccountProbes {
        accountProbes[activeAccount.accountId]
            ?? AccountProbes(cli: cliProbe, api: apiProbe, statusLine: statusLineProbeFactory?(nil))
    }

    // MARK: - Initialization

    /// Creates a Claude provider with CLI probe only (legacy initializer)
    /// - Parameters:
    ///   - probe: The CLI probe to use for fetching usage data
    ///   - passProbe: The probe to use for fetching guest pass data (optional)
    ///   - settingsRepository: The repository for persisting settings
    public init(
        probe: any UsageProbe,
        passProbe: (any ClaudePassProbing)? = nil,
        settingsRepository: any ProviderSettingsRepository,
        dailyUsageAnalyzer: (any DailyUsageAnalyzing)? = nil
    ) {
        self.cliProbe = probe
        self.apiProbe = nil
        self.passProbe = passProbe
        self.settingsRepository = settingsRepository
        self.dailyUsageAnalyzer = dailyUsageAnalyzer
        self.cliProbeFactory = { _ in probe }
        self.apiProbeFactory = { _ in nil }
        self.statusLineProbeFactory = nil
        // Load persisted enabled state (defaults to true)
        self.isEnabled = settingsRepository.isEnabled(forProvider: "claude")
        self.accounts = [defaultAccount()]
        self.activeAccount = self.accounts[0]
        self.accountSnapshots = [:]
        self.accountRefreshStates = [ProviderAccount.defaultAccountId: .idle]
        self.accountProbes = [:]
    }

    /// Creates a Claude provider with both CLI and API probes
    /// - Parameters:
    ///   - cliProbe: The CLI probe for fetching usage via `claude /usage`
    ///   - apiProbe: The API probe for fetching usage via HTTP API
    ///   - passProbe: The probe to use for fetching guest pass data (optional)
    ///   - settingsRepository: The repository for persisting settings (must be ClaudeSettingsRepository for mode switching)
    ///   - dailyUsageAnalyzer: Optional daily usage analyzer
    ///   - cliProbeFactory: Optional factory for creating per-account CLI probes. Receives the account's
    ///     `probeConfig["claudeConfigDir"]` if configured, otherwise `nil` for the default account.
    ///   - apiProbeFactory: Optional factory for creating per-account API probes.
    ///   - statusLineProbeFactory: Optional factory for the passive status-line probe (D2,
    ///     opt-in). Receives the account's config dir like the CLI factory; return `nil`
    ///     to disable the tier. Consulted last, after the CLI/API fallback chain —
    ///     never fabricates (the probe throws when no fresh observation exists).
    public init(
        cliProbe: any UsageProbe,
        apiProbe: any UsageProbe,
        passProbe: (any ClaudePassProbing)? = nil,
        settingsRepository: any ClaudeSettingsRepository,
        dailyUsageAnalyzer: (any DailyUsageAnalyzing)? = nil,
        cliProbeFactory: ((String?) -> any UsageProbe)? = nil,
        apiProbeFactory: ((String?) -> (any UsageProbe)?)? = nil,
        statusLineProbeFactory: ((String?) -> (any UsageProbe)?)? = nil
    ) {
        self.cliProbe = cliProbe
        self.apiProbe = apiProbe
        self.passProbe = passProbe
        self.settingsRepository = settingsRepository
        self.dailyUsageAnalyzer = dailyUsageAnalyzer
        self.cliProbeFactory = cliProbeFactory ?? { _ in cliProbe }
        self.apiProbeFactory = apiProbeFactory ?? { _ in apiProbe }
        self.statusLineProbeFactory = statusLineProbeFactory
        // Load persisted enabled state (defaults to true)
        self.isEnabled = settingsRepository.isEnabled(forProvider: "claude")
        // Set up multi-account state if the repository supports it.
        reloadAccounts()
    }

    // MARK: - AIProvider Protocol

    public func isAvailable() async -> Bool {
        let probes = activeProbes
        switch probeMode {
        case .cli:
            if await probes.cli.isAvailable() {
                return true
            }
            if let api = probes.api, await api.isAvailable() {
                return true
            }
            if let statusLine = probes.statusLine, await statusLine.isAvailable() {
                return true
            }
            return false
        case .api:
            if let api = probes.api, await api.isAvailable() {
                return true
            }
            guard cliFallbackEnabled else {
                if let statusLine = probes.statusLine, await statusLine.isAvailable() {
                    return true
                }
                return false
            }
            if await probes.cli.isAvailable() {
                return true
            }
            if let statusLine = probes.statusLine, await statusLine.isAvailable() {
                return true
            }
            return false
        }
    }

    /// Refreshes the usage data and updates the snapshot.
    /// Interactive refresh: delegates to the kind-aware implementation.
    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        try await refresh(.interactive)
    }

    /// Refreshes the usage data and updates the snapshot.
    /// Uses the active probe based on current probe mode.
    /// Sets isSyncing during refresh and captures any errors.
    ///
    /// The probe and fallback behaviour are identical for both kinds — CLI stays
    /// CLI, the rate-limit short-circuit still holds. The only difference is that
    /// a `.background` refresh skips the daily-usage JSONL scan
    /// (`attachDailyReport`), which the menu-bar label never shows; that scan
    /// runs only when the dropdown is open, which always refreshes interactively
    /// (issue #204).
    @discardableResult
    public func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot {
        let snapshot = try await refreshAccount(activeAccount.accountId, kind: kind)
        return snapshot
    }

    /// Refreshes a specific account's usage data and updates its snapshot.
    /// If `accountId` matches the active account, the provider-level `snapshot`
    /// is also updated.
    @discardableResult
    private func refreshAccount(_ accountId: String, kind: RefreshKind) async throws -> UsageSnapshot {
        let probes = accountProbes[accountId] ?? activeProbes
        let isActive = accountId == activeAccount.accountId

        if isActive {
            isSyncing = true
        }
        accountRefreshStates[accountId] = .refreshing
        defer {
            if isActive {
                isSyncing = false
            }
        }

        do {
            let newSnapshot = try await probes.active(for: probeMode).probe()
            let reported = await report(for: newSnapshot, kind: kind)
            accountSnapshots[accountId] = reported
            accountRefreshStates[accountId] = .ready
            if isActive {
                snapshot = reported
                lastError = nil
            }
            return reported
        } catch let primaryError {
            if Self.shouldAttemptFallback(after: primaryError) {
                for fallback in await probes.fallbackTiers(
                    for: probeMode, cliFallbackEnabled: cliFallbackEnabled
                ) {
                    do {
                        let newSnapshot = try await fallback.probe()
                        let reported = await report(for: newSnapshot, kind: kind)
                        accountSnapshots[accountId] = reported
                        accountRefreshStates[accountId] = .ready
                        if isActive {
                            snapshot = reported
                            lastError = nil
                        }
                        return reported
                    } catch {
                        // This tier failed too — offer the next one before
                        // surfacing the primary error.
                        continue
                    }
                }
            }

            if isActive {
                lastError = primaryError
            }
            accountRefreshStates[accountId] = .failed(message: primaryError.localizedDescription)
            throw primaryError
        }
    }

    // MARK: - MultiAccountProvider Protocol

    @discardableResult
    public func switchAccount(to accountId: String) -> Bool {
        guard accounts.contains(where: { $0.accountId == accountId }) else {
            return false
        }
        activeAccount = accounts.first { $0.accountId == accountId } ?? activeAccount
        if let multiSettings = settingsRepository as? MultiAccountSettingsRepository {
            multiSettings.setActiveAccountId(accountId, forProvider: id)
        }
        // Surface the cached snapshot for the new active account if available.
        snapshot = accountSnapshots[accountId]
        return true
    }

    @discardableResult
    public func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
        try await refreshAccount(accountId, kind: .interactive)
    }

    public func refreshAllAccounts(_ kind: RefreshKind) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask {
                    _ = try? await self.refreshAccount(account.accountId, kind: kind)
                }
            }
            await group.waitForAll()
        }
    }

    @discardableResult
    public func addAccount(_ config: ProviderAccountConfig) -> Bool {
        guard !config.accountId.isEmpty,
              !config.label.isEmpty,
              let multiSettings = settingsRepository as? MultiAccountSettingsRepository else {
            return false
        }
        multiSettings.addAccount(config, forProvider: id)
        reloadAccounts()
        return true
    }

    /// Reloads account definitions from the settings repository and rebuilds
    /// per-account probes. Call this after adding/removing accounts.
    public func reloadAccounts() {
        guard let multiSettings = settingsRepository as? MultiAccountSettingsRepository else {
            // Repository doesn't support multi-account: keep the default single account.
            accounts = [defaultAccount()]
            activeAccount = accounts[0]
            accountProbes[ProviderAccount.defaultAccountId] = AccountProbes(
                cli: cliProbe, api: apiProbe, statusLine: statusLineProbeFactory?(nil)
            )
            accountRefreshStates = [ProviderAccount.defaultAccountId: accountRefreshStates[ProviderAccount.defaultAccountId] ?? .idle]
            return
        }

        let configs = multiSettings.accounts(forProvider: id)
        if configs.isEmpty {
            accounts = [defaultAccount()]
            activeAccount = accounts[0]
            accountProbes = [ProviderAccount.defaultAccountId: AccountProbes(
                cli: cliProbe, api: apiProbe, statusLine: statusLineProbeFactory?(nil)
            )]
            accountRefreshStates = [ProviderAccount.defaultAccountId: accountRefreshStates[ProviderAccount.defaultAccountId] ?? .idle]
            return
        }

        accounts = configs.map { $0.toProviderAccount(providerId: id) }
        accountProbes = [:]
        for config in configs {
            let configDir = config.probeConfig["claudeConfigDir"]
            accountProbes[config.accountId] = AccountProbes(
                cli: cliProbeFactory(configDir),
                api: apiProbeFactory(configDir),
                statusLine: statusLineProbeFactory?(configDir)
            )
        }

        let configuredIds = Set(configs.map(\.accountId))
        accountRefreshStates = accountRefreshStates
            .filter { configuredIds.contains($0.key) }
        for accountId in configuredIds where accountRefreshStates[accountId] == nil {
            accountRefreshStates[accountId] = .idle
        }

        let persistedActiveId = multiSettings.activeAccountId(forProvider: id)
        if let persistedActiveId,
           accounts.contains(where: { $0.accountId == persistedActiveId }) {
            activeAccount = accounts.first { $0.accountId == persistedActiveId } ?? accounts[0]
        } else {
            activeAccount = accounts[0]
            multiSettings.setActiveAccountId(activeAccount.accountId, forProvider: id)
        }

        // Ensure the active account's snapshot is surfaced at the provider level.
        snapshot = accountSnapshots[activeAccount.accountId]
    }

    private func defaultAccount() -> ProviderAccount {
        ProviderAccount(
            accountId: ProviderAccount.defaultAccountId,
            providerId: id,
            label: "Default"
        )
    }

    /// Decides whether the fallback probe should run after the primary fails.
    /// Rate-limit failures are an upstream per-token throttle: the CLI talks
    /// to the same Anthropic backend, so the fallback can't help and would
    /// just amplify the problem. Surface the rate-limit error immediately so
    /// the backoff window does its job. All other failure modes (auth,
    /// parse, network, etc.) still try the fallback — those can legitimately
    /// be recovered by the alternate probe path.
    private static func shouldAttemptFallback(after error: Error) -> Bool {
        if case ProbeError.rateLimited = error { return false }
        return true
    }

    /// Attaches the daily-usage report for interactive refreshes only.
    /// Background refreshes (the menu-bar poll) skip the JSONL scan to stay cheap
    /// — the menu-bar label never renders the daily report, and the dropdown that
    /// does always refreshes interactively (issue #204).
    private func report(for snapshot: UsageSnapshot, kind: RefreshKind) async -> UsageSnapshot {
        switch kind {
        case .interactive, .opening:
            return await attachDailyReport(to: snapshot)
        case .background:
            return snapshot
        }
    }

    /// Attaches daily usage report to snapshot if analyzer is available.
    private func attachDailyReport(to snapshot: UsageSnapshot) async -> UsageSnapshot {
        guard let analyzer = dailyUsageAnalyzer,
              let report = try? await analyzer.analyzeToday(),
              !report.today.isEmpty || !report.previous.isEmpty else {
            return snapshot
        }
        return UsageSnapshot(
            providerId: snapshot.providerId,
            quotas: snapshot.quotas,
            capturedAt: snapshot.capturedAt,
            accountEmail: snapshot.accountEmail,
            accountOrganization: snapshot.accountOrganization,
            loginMethod: snapshot.loginMethod,
            accountTier: snapshot.accountTier,
            costUsage: snapshot.costUsage,
            bedrockUsage: snapshot.bedrockUsage,
            dailyUsageReport: report
        )
    }

    private var cliFallbackEnabled: Bool {
        (settingsRepository as? ClaudeSettingsRepository)?
            .claudeCliFallbackEnabled() ?? true
    }

    // MARK: - Guest Pass

    /// Fetches the current guest pass information.
    /// Sets isFetchingPasses during fetch and captures any errors.
    @discardableResult
    public func fetchPasses() async throws -> ClaudePass {
        guard let passProbe else {
            throw PassError.probeNotConfigured
        }

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

    /// Dismisses the last guest pass error.
    public func clearPassError() {
        passError = nil
    }

    /// Whether the guest passes feature is available.
    /// Requires both a configured probe and a Max account — Anthropic issues
    /// invitation links to Max subscribers only, and an unknown tier is not
    /// evidence of one (issue #243).
    public var supportsGuestPasses: Bool {
        passProbe != nil && snapshot?.accountTier?.supportsGuestPasses == true
    }

    /// Whether API mode is available (API probe was provided)
    public var supportsApiMode: Bool {
        apiProbe != nil
    }
}

// MARK: - Pass Error

public enum PassError: Error, LocalizedError {
    case probeNotConfigured

    public var errorDescription: String? {
        switch self {
        case .probeNotConfigured:
            return "Guest pass probe is not configured"
        }
    }
}
