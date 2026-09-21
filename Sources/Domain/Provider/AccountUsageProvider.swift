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
    private var configs: [ProviderAccountConfig] {
        let stored = settings.accounts(forProvider: id)
        return stored.isEmpty ? defaultConfig.map { [$0] } ?? [] : stored
    }
    private let makeProbe: @Sendable (ProviderAccountConfig) -> any UsageProbe

    public init(id: String, name: String, cliCommand: String, dashboardURL: URL?,
                settings: any MultiAccountSettingsRepository,
                defaultConfig: ProviderAccountConfig? = nil,
                makeProbe: @escaping @Sendable (ProviderAccountConfig) -> any UsageProbe) {
        self.id = id
        self.name = name
        self.cliCommand = cliCommand
        self.dashboardURL = dashboardURL
        self.settings = settings
        self.defaultConfig = defaultConfig
        self.makeProbe = makeProbe
        self.isEnabled = settings.isEnabled(forProvider: id)
        let stored = settings.accounts(forProvider: id)
        let configs = stored.isEmpty ? defaultConfig.map { [$0] } ?? [] : stored
        self.accounts = configs.map { $0.toProviderAccount(providerId: id) }
        self.activeID = settings.activeAccountId(forProvider: id) ?? configs.first?.accountId ?? "default"
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
