import Foundation
import Observation

/// Independent observations for credentials or CLI profiles belonging to one service.
/// A failed account keeps its last reading and cannot cancel another account's refresh.
@MainActor @Observable
public final class AccountUsageProvider: MultiAccountProvider {
    public let id: String
    public let name: String
    public let cliCommand: String
    public let dashboardURL: URL?
    public var isEnabled: Bool {
        didSet { settings.setEnabled(isEnabled, forProvider: id) }
    }
    public private(set) var accounts: [ProviderAccount]
    public private(set) var accountSnapshots: [String: UsageSnapshot] = [:]
    public private(set) var accountRefreshStates: [String: ProviderAccountRefreshState] = [:]
    public private(set) var lastError: Error?
    @ObservationIgnored private var refreshTasks: [String: Task<UsageSnapshot, Error>] = [:]
    private var activeID: String
    private let settings: any MultiAccountSettingsRepository
    private let defaultConfig: ProviderAccountConfig?
    /// Settings file to watch so an external (CLI) account add/remove is picked
    /// up live, instead of only at init/in-process add (the anchor gap). nil
    /// disables watching (tests, single-account providers).
    @ObservationIgnored private let settingsFileURL: URL?
    @ObservationIgnored private var settingsWatcher: DispatchSourceFileSystemObject?
    /// Accounts to collect for this provider. Empty while the provider is
    /// disabled: "Remove from Cortex" must make the row disappear, and a
    /// synthetic `defaultConfig` (e.g. qwen's "Token Plan") must never
    /// resurrect it — without this guard the row came back on the very next
    /// refresh (Ben 2026-09-26: "ça ne le remove pas"). Enrolled accounts still
    /// keep their last reading while enabled-but-unfollowed via `unfollow`.
    private var configs: [ProviderAccountConfig] {
        guard isEnabled else { return [] }
        let stored = settings.accounts(forProvider: id)
        return stored.isEmpty ? defaultConfig.map { [$0] } ?? [] : stored
    }
    private let makeProbe: @Sendable (ProviderAccountConfig) -> any UsageProbe

    public init(id: String, name: String, cliCommand: String, dashboardURL: URL?,
                settings: any MultiAccountSettingsRepository,
                defaultConfig: ProviderAccountConfig? = nil,
                settingsFileURL: URL? = nil,
                makeProbe: @escaping @Sendable (ProviderAccountConfig) -> any UsageProbe) {
        self.id = id
        self.name = name
        self.cliCommand = cliCommand
        self.dashboardURL = dashboardURL
        self.settings = settings
        self.defaultConfig = defaultConfig
        self.settingsFileURL = settingsFileURL
        self.makeProbe = makeProbe
        let enabled = settings.isEnabled(forProvider: id)
        self.isEnabled = enabled
        let stored = settings.accounts(forProvider: id)
        let configs = enabled
            ? (stored.isEmpty ? defaultConfig.map { [$0] } ?? [] : stored)
            : []
        self.accounts = configs.map { $0.toProviderAccount(providerId: id) }
        self.activeID = settings.activeAccountId(forProvider: id) ?? configs.first?.accountId ?? "default"
        startWatchingSettings()
    }

    deinit {
        settingsWatcher?.cancel()
    }

    // MARK: - Live roster reload (external CLI writes)

    /// Rebuilds the published `accounts` from settings when the roster changed.
    /// Snapshots keyed by `accountId` survive; a new account has none until its
    /// next refresh; the active id falls back if it vanished. No-op when the
    /// account ids are unchanged, so it is cheap to call on every popover open.
    public func reloadAccounts() {
        let refreshed = configs.map { $0.toProviderAccount(providerId: id) }
        guard refreshed.map(\.accountId) != accounts.map(\.accountId) else { return }
        accounts = refreshed
        if !refreshed.contains(where: { $0.accountId == activeID }) {
            activeID = settings.activeAccountId(forProvider: id)
                ?? refreshed.first?.accountId
                ?? activeID
        }
    }

    /// Popover-appear hook: pick up any external roster change immediately,
    /// without waiting for a file-system event.
    public func reloadOnAppear() { reloadAccounts() }

    /// Watches the settings file for external writes (CLI add/remove account).
    /// Re-arms on every event so an atomic rename/delete (which swaps the watched
    /// inode) keeps a live watcher on the path.
    ///
    /// The event handler captures ONLY `[weak self]` — never the source — so the
    /// source's sole owner is `settingsWatcher`. deinit then cancels it before
    /// its last release, honoring libdispatch's cancel-before-release contract.
    private func startWatchingSettings() {
        guard let settingsFileURL else { return }
        settingsWatcher?.cancel()
        settingsWatcher = nil
        let fd = open(settingsFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        // @Sendable prevents MainActor inference: libdispatch invokes these on
        // the utility queue, so an isolated closure would trap (SIGTRAP,
        // _dispatch_assert_queue_fail) on every settings write / cancel.
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadAccounts()
                // Re-arm: an atomic write renames a temp over the file, so the
                // current fd now points at a dead inode. Re-open the path.
                self.startWatchingSettings()
            }
        }
        source.setCancelHandler { @Sendable in close(fd) }
        settingsWatcher = source
        source.resume()
    }

    public var activeAccount: ProviderAccount {
        accounts.first { $0.accountId == activeID } ?? accounts.first
            ?? ProviderAccount(providerId: id, label: "Default")
    }
    public var snapshot: UsageSnapshot? { accountSnapshots[activeAccount.accountId] }
    public var isSyncing: Bool { accountRefreshStates.values.contains(.refreshing) }

    public func isAvailable() async -> Bool {
        for config in configs {
            if await makeProbe(config).isAvailable() { return true }
        }
        return false
    }

    @discardableResult public func switchAccount(to accountId: String) -> Bool {
        guard accounts.contains(where: { $0.accountId == accountId }) else { return false }
        activeID = accountId
        settings.setActiveAccountId(accountId, forProvider: id)
        return true
    }

    @discardableResult public func addAccount(_ config: ProviderAccountConfig) -> Bool {
        guard !accounts.contains(where: { $0.accountId == config.accountId }) else { return false }
        settings.addAccount(config, forProvider: id)
        accounts = settings.accounts(forProvider: id).map { $0.toProviderAccount(providerId: id) }
        return accounts.contains { $0.accountId == config.accountId }
    }

    @discardableResult public func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
        guard isEnabled else { throw ProbeError.executionFailed("Provider disabled") }
        guard let config = configs.first(where: { $0.accountId == accountId }) else {
            throw ProbeError.authenticationRequired
        }
        if let existing = refreshTasks[accountId] { return try await existing.value }
        accountRefreshStates[accountId] = .refreshing
        let probe = makeProbe(config)
        let task = Task { try await probe.probe() }
        refreshTasks[accountId] = task
        defer { refreshTasks[accountId] = nil }
        do {
            let value = try await task.value
            // A toggle while a request is in flight must not republish disabled rows.
            guard isEnabled else { throw CancellationError() }
            accountSnapshots[accountId] = value
            accountRefreshStates[accountId] = .ready
            if accountId == activeAccount.accountId { lastError = nil }
            return value
        } catch {
            accountRefreshStates[accountId] = .failed(message: error.localizedDescription)
            if accountId == activeAccount.accountId { lastError = error }
            throw error
        }
    }

    public func refreshAllAccounts(_ kind: RefreshKind) async {
        guard isEnabled else { return }
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { _ = try? await self.refreshAccount(account.accountId) }
            }
        }
    }

    @discardableResult public func refresh() async throws -> UsageSnapshot {
        try await refreshAccount(activeAccount.accountId)
    }
}
