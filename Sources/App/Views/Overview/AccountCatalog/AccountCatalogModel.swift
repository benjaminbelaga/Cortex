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
        activateIntegration: @escaping @MainActor (String) -> Void
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
        guard let config = settingsRepository.accounts(forProvider: providerId).first(where: {
            $0.accountId == alias || $0.probeConfig["routerAlias"] == alias || $0.label == alias
        }) else {
            return AsyncStream { continuation in
                continuation.yield(.failed(AccountDescriptor(providerId: providerId, label: alias,
                    profile: .none, source: .native), error: .underlying("Profil local introuvable. Ajoutez ce compte depuis le catalogue.")))
                continuation.finish()
            }
        }
        let descriptor = config.descriptor(providerId: providerId)
        return enrolmentService.reconnect(account: descriptor)
    }

    func present(providerId: String) {
        selectedProvider = providerId
        isPresented = true
    }

    /// Validate the key before storing it. The JSON settings receive only its Keychain reference.
    func addAPIAccount(providerId: String, label: String, apiKey: String) async {
        guard !isValidatingKey, ["opencode-go", "commandcode"].contains(providerId) else { return }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !key.isEmpty, !key.contains("*"), !key.contains(where: \.isWhitespace) else {
            proposalError = "Saisissez un libellé et une clé API complète."
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
            let reference = "account.\(providerId).\(descriptor.uuid.uuidString)"
            credentials.save(key, forKey: reference)
            guard credentials.get(forKey: reference) == key else {
                throw ProbeError.executionFailed("Impossible d’enregistrer la clé dans le Trousseau.")
            }
            let config = ProviderAccountConfig.from(descriptor: descriptor,
                accountId: descriptor.uuid.uuidString, email: reading.accountEmail,
                preserving: ["credentialKey": reference])
            settingsRepository.addAccount(config, forProvider: providerId)
            guard settingsRepository.accounts(forProvider: providerId).contains(where: { $0.accountId == config.accountId }) else {
                credentials.delete(forKey: reference)
                throw ProbeError.executionFailed("Impossible d’enregistrer le compte.")
            }
            activateIntegration(providerId)
            _ = try await accountChanged(providerId, config.accountId)
            addedAccountLabel = label
        } catch {
            proposalError = error.localizedDescription
        }
    }

    func removeAccount(providerId: String, accountId: String) async {
        guard let account = settingsRepository.accounts(forProvider: providerId).first(where: { $0.accountId == accountId }) else { return }
        settingsRepository.removeAccount(accountId: accountId, forProvider: providerId)
        if let reference = account.probeConfig["credentialKey"], reference.hasPrefix("account.\(providerId).") {
            credentials.delete(forKey: reference)
        }
        let next = settingsRepository.accounts(forProvider: providerId).first?.accountId ?? "default"
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
            return "Un autre compte possède déjà ce dossier — choisissez un autre libellé."
        case .unsupportedProvider(let providerId):
            return "Outil non pris en charge : \(providerId)."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
