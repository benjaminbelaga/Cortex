import AppKit
import Foundation
import Observation
import Domain
import Infrastructure

/// Façade behind the `+` catalogue (D tranche): detected profiles, new-account
/// enrolment through the verified `AccountEnrolmentService` state machine, and
/// reconnect for existing rows. The view never launches a terminal directly
/// and never treats "terminal opened" as success — every outcome is a typed
/// `EnrolmentState`.
@Observable
@MainActor
final class AccountCatalogModel {

    private let enrolmentService: AccountEnrolmentService
    private let discovery: AccountDiscoveryService
    private let resolver: any ProfileResolving
    private let settingsRepository: any MultiAccountSettingsRepository
    private let homeDirectory: String
    private let credentials: any CredentialRepository
    private let accountChanged: @MainActor (String, String) async throws -> Date?
    private let probeAPIKey: @Sendable (String, String) async throws -> UsageSnapshot
    var selectedProvider = "claude"
    var isPresented = false
    private(set) var isValidatingKey = false
    private(set) var addedAccountLabel: String?

    /// Activation hook for optional integrations (qwen-api / bedrock / local):
    /// flips the explicit `isEnabled` key. Injected by the app so the model
    /// stays repository-agnostic.
    private let activateIntegration: @MainActor (String) -> Void

    /// Called when removing an account leaves the provider with no stored
    /// account at all: the provider itself is then removed from Cortex (no
    /// synthetic `defaultConfig` row may survive, and no forced re-enable may
    /// resurrect it). Injected by the app; a no-op under test.
    private let providerRemoved: @MainActor (String) -> Void

    private(set) var detectedProfiles: [AccountProposal] = []
    private(set) var isSearching = false
    /// Non-fatal feedback for path-proposal failures (collision etc.).
    private(set) var proposalError: String?

    private var streamTasks: [UUID: Task<Void, Never>] = [:]

    init(
        enrolmentService: AccountEnrolmentService,
        discovery: AccountDiscoveryService,
        resolver: any ProfileResolving,
        settingsRepository: any MultiAccountSettingsRepository,
        homeDirectory: String,
        credentials: any CredentialRepository = KeychainCredentialRepository.shared,
        accountChanged: @escaping @MainActor (String, String) async throws -> Date? = { _, _ in nil },
        probeAPIKey: @escaping @Sendable (String, String) async throws -> UsageSnapshot = {
            try await APIAccountCredentials.probe(providerId: $0, apiKey: $1).probe()
        },
        activateIntegration: @escaping @MainActor (String) -> Void,
        providerRemoved: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.credentials = credentials
        self.accountChanged = accountChanged
        self.probeAPIKey = probeAPIKey
        self.enrolmentService = enrolmentService
        self.discovery = discovery
        self.resolver = resolver
        self.settingsRepository = settingsRepository
        self.homeDirectory = homeDirectory
        self.activateIntegration = activateIntegration
        self.providerRemoved = providerRemoved
    }

    // MARK: - Observable surface (the service owns the live state)

    var states: [UUID: EnrolmentState] {
        enrolmentService.states
    }

    // MARK: - Discovery

    /// Sweeps the profile directories for authenticated newcomers. Bounded by
    /// the discovery service itself (per-candidate + total budget); proposals
    /// already tracked or rejected never come back.
    func search() async {
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        var proposals: [AccountProposal] = []
        for providerId in ["claude", "codex"] {
            if Task.isCancelled { break }
            proposals += await discovery.discover(
                forProvider: providerId,
                homeDirectory: homeDirectory,
                existing: existingDescriptors(forProvider: providerId)
            )
        }
        detectedProfiles = proposals
    }

    // MARK: - Enrolment

    /// Follows a discovered profile: the read-back identity (already verified
    /// by the sweep) is proposed as the expected identity so a mismatch
    /// between sweep time and enrolment time still fails closed.
    func follow(_ proposal: AccountProposal) {
        let descriptor = AccountDescriptor(
            providerId: proposal.providerId,
            label: label(forPath: proposal.canonicalPath),
            profile: proposal.profile,
            source: .native
        )
        start(EnrolmentIntent(
            descriptor: descriptor,
            expectedIdentityEmail: proposal.email,
            targetSource: .native
        ))
    }

    /// Creates a NEW isolated profile for the chosen tool, then runs the
    /// verified enrolment (terminal login → poll → identity read-back →
    /// optional registrar). The optional expected email only serves the
    /// mismatch check — it is never treated as proof of identity.
    func enrolNew(providerId: String, label: String, expectedEmail: String?) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let owned = existingDescriptors(forProvider: providerId)
            .compactMap(\.profile.localPath)
        switch resolver.proposePath(
            forProvider: providerId,
            label: trimmed,
            homeDirectory: homeDirectory,
            ownedPaths: owned
        ) {
        case .success(let profile):
            proposalError = nil
            start(EnrolmentIntent(
                descriptor: AccountDescriptor(
                    providerId: providerId,
                    label: trimmed,
                    profile: profile,
                    source: .native
                ),
                expectedIdentityEmail: expectedEmail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                targetSource: .native
            ))
        case .failure(let error):
            proposalError = Self.proposalMessage(error)
        }
    }

    /// Reconnect for an existing dashboard row (router alias seat). Returns
    /// the live stream so the row can surface the typed outcome in place.
    func reconnect(providerId: String, alias: String) -> AsyncStream<EnrolmentState> {
        guard let config = Self.matchAccount(
            alias: alias,
            providerId: providerId,
            accounts: settingsRepository.accounts(forProvider: providerId)
        ) else {
            return AsyncStream { continuation in
                continuation.yield(.failed(AccountDescriptor(providerId: providerId, label: alias,
                    profile: .none, source: .native), error: .underlying("Local profile not found. Add this account from the catalog.")))
                continuation.finish()
            }
        }
        let descriptor = config.descriptor(providerId: providerId)
        if ["claude", "codex"].contains(providerId), let routerAlias = config.probeConfig["routerAlias"] {
            return routerSeatReconnect(providerId: providerId, config: config,
                routerAlias: routerAlias, descriptor: descriptor)
        }
        return enrolmentService.reconnect(account: descriptor)
    }

    /// The dashboard row carries the ROUTER account id (`claude-tech`) while
    /// settings hold `accountId "tech"` + `routerAlias "TECH"` — the old
    /// exact-string match dead-ended on that mismatch and the row showed only
    /// "Erreur inattendue" (defect observed 2026-09-22). Match on the
    /// de-prefixed, case-folded forms.
    static func matchAccount(alias: String, providerId: String, accounts: [ProviderAccountConfig]) -> ProviderAccountConfig? {
        let needle = normalizeAlias(alias, providerId: providerId)
        guard !needle.isEmpty else { return nil }
        return accounts.first { config in
            [config.accountId, config.probeConfig["routerAlias"] ?? "", config.label]
                .contains { normalizeAlias($0, providerId: providerId) == needle }
        }
    }

    private static func normalizeAlias(_ raw: String, providerId: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["\(providerId.lowercased())-", "\(providerId.lowercased())_"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        return value
    }

    /// A router seat (claude-swap / llm-router) is repaired by the FULL guided
    /// sequence — login in the account's declared auth home, then `cswap add`
    /// and the registrar — not by a bare CLI login that leaves the seat dead
    /// (R14, design doc §"Gestes Ben restants": `cswap add` clears
    /// `relogin_required`). The stream polls the live refresh until the seat
    /// answers again, and reports a timeout instead of claiming success from a
    /// launched terminal.
    private func routerSeatReconnect(
        providerId: String,
        config: ProviderAccountConfig,
        routerAlias: String,
        descriptor: AccountDescriptor
    ) -> AsyncStream<EnrolmentState> {
        AsyncStream { continuation in
            Task { @MainActor in
                continuation.yield(.authRequired(descriptor, reason: .explicitReconnect))
                continuation.yield(.loginInProgress(descriptor, stage: .launching))
                let provider: AccountConnectRunner.Provider = providerId == "codex" ? .codex : .claude
                let profile = config.probeConfig["claudeConfigDir"] ?? config.probeConfig["codexHome"]
                let launch = await AccountConnectRunner.connect(
                    provider: provider,
                    alias: routerAlias,
                    identity: config.email,
                    profileOverride: profile
                )
                guard launch.succeeded else {
                    continuation.yield(.failed(descriptor, error: .underlying(launch.message)))
                    continuation.finish()
                    return
                }
                continuation.yield(.loginInProgress(descriptor, stage: .waitingForUser))
                let deadline = Date().addingTimeInterval(Self.routerSeatPollTimeout)
                while Date() < deadline, !Task.isCancelled {
                    do {
                        if let observedAt = try await accountChanged(providerId, config.accountId) {
                            continuation.yield(.quotaReceived(descriptor, observedAt: observedAt))
                            continuation.finish()
                            return
                        }
                    } catch {
                        // A refresh failure is not the reconnect verdict — keep polling.
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
                continuation.yield(.failed(descriptor, error: .timeout(afterSeconds: Self.routerSeatPollTimeout)))
                continuation.finish()
            }
        }
    }

    private static let routerSeatPollTimeout: TimeInterval = 120

    /// Whether a row's account exposes a copyable API key. Metadata-only: the
    /// value itself is read only inside `apiKey(...)`, on the operator's click —
    /// never during view rendering.
    func canCopyAPIKey(providerId: String, accountId: String) -> Bool {
        guard let config = settingsRepository.accounts(forProvider: providerId)
            .first(where: { $0.accountId == accountId }) else { return false }
        return config.probeConfig["credentialKey"] != nil || config.probeConfig["externalSlot"] != nil
    }

    /// The copyable key of one account, through the same references the probe
    /// uses. nil when the account vanished or has no copyable key.
    func apiKey(providerId: String, accountId: String) -> String? {
        guard let config = settingsRepository.accounts(forProvider: providerId)
            .first(where: { $0.accountId == accountId }) else { return nil }
        return APIAccountCredentials.key(providerId: providerId, config: config, credentials: credentials,
                                         homeDirectory: homeDirectory)
    }

    func present(providerId: String) {
        selectedProvider = providerId
        isPresented = true
    }

    /// Validate the key before storing it. The JSON settings receive only a reference
    /// (pool slot for OpenCode Go / Ollama / Command Code, Keychain item otherwise).
    func addAPIAccount(providerId: String, label: String, apiKey: String) async {
        guard !isValidatingKey, ProviderCatalog.apiKeyAccountIDs.contains(providerId) else { return }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !key.isEmpty, !key.contains("*"), !key.contains(where: \.isWhitespace) else {
            proposalError = "Enter a label and a complete API key."
            return
        }
        // Same key twice = same subscription twice, never extra credit (bible R40).
        // Compared in-process against every existing account, imported slots included.
        if let existing = settingsRepository.accounts(forProvider: providerId).first(where: {
            APIAccountCredentials.key(providerId: providerId, config: $0, credentials: credentials,
                                      homeDirectory: homeDirectory) == key
        }) {
            proposalError = "This key is already enrolled (“\(existing.label)”)."
            return
        }
        isValidatingKey = true
        proposalError = nil
        addedAccountLabel = nil
        defer { isValidatingKey = false }
        let descriptor = AccountDescriptor(providerId: providerId, label: label, profile: .none, source: .native)
        do {
            let reading = try await probeAPIKey(providerId, key)
            try Task.checkCancellation()
            // A different key of an already-enrolled identity is the same
            // account again (CLI slot + console key), not a new subscription.
            if let identity = reading.accountEmail?.lowercased(), !identity.isEmpty,
               let twin = settingsRepository.accounts(forProvider: providerId)
                   .first(where: { $0.email?.lowercased() == identity }) {
                proposalError = "This account is already followed (“\(twin.label)”)."
                return
            }
            // OpenCode Go, Ollama Cloud and Command Code keys join the shared
            // failover pools so the CLIs rotate onto them too; Cortex then reads
            // the slot (no Keychain prompt). Other providers keep a Keychain reference.
            let reference = "account.\(providerId).\(descriptor.uuid.uuidString)"
            let preserving: [String: String]
            if providerId == "commandcode" {
                // Command Code keys join the CLI failover pool (auth-pool.json).
                let slot = try CommandCodeFailoverPool(loader: CommandCodeCredentialLoader(
                    homeDirectory: homeDirectory, environment: [:])).enroll(label: label, key: key)
                preserving = ["externalSlot": slot]
            } else if providerId == "opencode-go" || providerId == "ollama" {
                // Scoped to the model's home so tests never touch the real pool.
                // Ollama keys feed the opencode `ollama-cloud` rotation (tier-2
                // fallback target) and never need a Keychain prompt.
                let loader = providerId == "ollama"
                    ? OpenCodeCredentialLoader.ollamaCloud(homeDirectory: homeDirectory)
                    : OpenCodeCredentialLoader(homeDirectory: homeDirectory)
                let pool = OpenCodeFailoverPool(loader: loader)
                let slot = try pool.enroll(label: label, key: key)
                preserving = ["externalSlot": slot]
            } else {
                credentials.save(key, forKey: reference)
                guard credentials.get(forKey: reference) == key else {
                    throw ProbeError.executionFailed("Could not save the key in the Keychain.")
                }
                preserving = ["credentialKey": reference]
            }
            let config = ProviderAccountConfig.from(descriptor: descriptor,
                accountId: descriptor.uuid.uuidString, email: reading.accountEmail,
                preserving: preserving)
            settingsRepository.addAccount(config, forProvider: providerId)
            guard settingsRepository.accounts(forProvider: providerId).contains(where: { $0.accountId == config.accountId }) else {
                if preserving["credentialKey"] != nil { credentials.delete(forKey: reference) }
                throw ProbeError.executionFailed("Could not save the account.")
            }
            activateIntegration(providerId)
            _ = try await accountChanged(providerId, config.accountId)
            addedAccountLabel = label
        } catch {
            proposalError = error.localizedDescription
        }
    }

    /// One-gesture enrolment: every "label line + key line" pair on the
    /// pasteboard goes through `addAPIAccount` (same validation, dedupe, live
    /// probe). The pasteboard is cleared once at least one key was added.
    ///
    /// `autoRoute` lets the global paste button send each key to the provider
    /// its shape belongs to (`oc_…` → OpenCode Go, Ollama form → Ollama)
    /// instead of forcing the caller to pick one provider up front.
    func addAPIAccountsFromPasteboard(providerId: String, fallbackLabel: String, autoRoute: Bool = false) async {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            proposalError = "Presse-papiers vide."
            return
        }
        let entries = APIKeyPasteParser.parse(text, fallbackLabel: fallbackLabel)
        guard !entries.isEmpty else {
            proposalError = "No key found: copy the “label” then the key on the next line."
            return
        }
        var added: [String] = []
        var failures: [String] = []
        for entry in entries {
            let target = (autoRoute ? entry.providerHint : nil) ?? providerId
            guard ProviderCatalog.apiKeyAccountIDs.contains(target) else {
                failures.append("\(entry.label): no provider recognises this key shape")
                continue
            }
            await addAPIAccount(providerId: target, label: entry.label, apiKey: entry.key)
            if addedAccountLabel == entry.label {
                added.append(entry.label)
            } else {
                failures.append("\(entry.label): \(proposalError ?? "failed")")
            }
        }
        if !added.isEmpty { NSPasteboard.general.clearContents() }
        addedAccountLabel = added.isEmpty ? nil : added.joined(separator: ", ")
        proposalError = failures.isEmpty ? nil : failures.joined(separator: " · ")
    }

    func removeAccount(providerId: String, accountId: String) async {
        guard let account = settingsRepository.accounts(forProvider: providerId).first(where: { $0.accountId == accountId }) else {
            // No stored account (router-backed rows keep their accounts in the
            // router roster): removing the row means removing the provider.
            providerRemoved(providerId)
            return
        }
        settingsRepository.removeAccount(accountId: accountId, forProvider: providerId)
        if let reference = account.probeConfig["credentialKey"], reference.hasPrefix("account.\(providerId).") {
            credentials.delete(forKey: reference)
        }
        let remaining = settingsRepository.accounts(forProvider: providerId)
        guard let next = remaining.first?.accountId else {
            // Last stored account gone: remove the provider itself. Calling
            // `accountChanged` here used to force `setEnabled(true)` and
            // re-instantiate the row, so "Remove from Cortex" never stuck.
            providerRemoved(providerId)
            return
        }
        do { _ = try await accountChanged(providerId, next) }
        catch { proposalError = error.localizedDescription }
    }

    func setSource(providerId: String, mode: QuotaSourceMode) async {
        var configs = settingsRepository.accounts(forProvider: providerId)
        if configs.isEmpty {
            var profile: [String: String] = [:]
            if providerId == "claude" { profile["claudeConfigDir"] = (homeDirectory as NSString).appendingPathComponent(".claude") }
            if providerId == "codex" { profile["codexHome"] = (homeDirectory as NSString).appendingPathComponent(".codex") }
            configs = [.init(accountId: "default", label: "Default", probeConfig: profile)]
        }
        for config in configs {
            var pc = config.probeConfig
            pc["providers.\(providerId).sourceMode"] = mode.rawValue
            pc["source"] = mode == .autonomous ? "native" : "router"
            settingsRepository.addAccount(.init(accountId: config.accountId, label: config.label,
                email: config.email, organization: config.organization, probeConfig: pc), forProvider: providerId)
        }
        do { _ = try await accountChanged(providerId, configs[0].accountId) }
        catch { proposalError = error.localizedDescription }
    }

    func configureQwen(profile: String, site: String, region: String) async {
        let account = settingsRepository.accounts(forProvider: "qwen").first
        settingsRepository.addAccount(.init(accountId: account?.accountId ?? "default", label: "Token Plan",
            probeConfig: ["bailianProfile": profile, "consoleSite": site, "consoleRegion": region,
                "providers.qwen.sourceMode": "autonomous", "source": "native"]), forProvider: "qwen")
        do { _ = try await accountChanged("qwen", account?.accountId ?? "default") }
        catch { proposalError = error.localizedDescription }
    }

    func cancel(uuid: UUID) {
        enrolmentService.cancel(uuid: uuid)
    }

    func forget(uuid: UUID) {
        enrolmentService.forget(uuid: uuid)
    }

    // MARK: - Integrations

    func activate(_ providerId: String) {
        activateIntegration(providerId)
    }

    var integrationDescriptors: [ProviderDescriptor] {
        ProviderCatalog.all.filter { $0.category == .integration }
    }

    /// Un module est « actif » quand son suivi est activé. Le défaut vient du
    /// descripteur : une connexion suivie d'office est active sans clé stockée,
    /// une connexion optionnelle attend une activation explicite.
    func isActiveIntegration(_ providerId: String) -> Bool {
        let descriptorDefault = ProviderCatalog.descriptor(forId: providerId)?.defaultEnabled ?? false
        return settingsRepository.isEnabled(forProvider: providerId, defaultValue: descriptorDefault)
    }

    // MARK: - Private

    private func start(_ intent: EnrolmentIntent) {
        let uuid = intent.descriptor.uuid
        let stream = enrolmentService.enrol(intent: intent)
        streamTasks[uuid] = Task { [weak self] in
            for await _ in stream {}
            self?.streamTasks[uuid] = nil
        }
    }

    private func existingDescriptors(forProvider providerId: String) -> [AccountDescriptor] {
        settingsRepository.accounts(forProvider: providerId)
            .map { $0.descriptor(providerId: providerId) }
    }

    private func label(forPath path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.nilIfEmpty ?? path
    }

    private static func proposalMessage(_ error: ProfileResolutionError) -> String {
        switch error {
        case .profileCollision:
            return "Another account already owns this folder — choose another label."
        case .unsupportedProvider(let providerId):
            return "Unsupported tool: \(providerId)."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
