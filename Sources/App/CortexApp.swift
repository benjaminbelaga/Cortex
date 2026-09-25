import SwiftUI
import Domain
import Infrastructure
import MenuBarExtraAccess
#if ENABLE_SPARKLE
import Sparkle
#endif

extension Notification.Name {
    static let hookSettingsChanged = Notification.Name("fr.yoyaku.cortex.hookSettingsChanged")

    /// Posted by the Notify! pane when the device link or a stored surface
    /// handle changes. Those live outside observable state, so nothing the
    /// publish driver watches would otherwise tell it to try again.
    static let notifySettingsChanged = Notification.Name("fr.yoyaku.cortex.notifySettingsChanged")
}

@main
struct CortexApp: App {
    /// The main domain service - monitors all AI providers
    /// This is the single source of truth for providers and their state
    @State private var monitor: QuotaMonitor

    /// Monitors Claude Code sessions via hook events
    @State private var sessionMonitor: SessionMonitor

    /// Drives the menu-bar pixels and the background-refresh lifecycle
    /// imperatively, outside SwiftUI — the MenuBarExtra label hosting can
    /// permanently stop re-evaluating after system sleep (issue #192).
    private let statusItemDriver: StatusItemLabelDriver

    /// Draws Claude Code session and quota state into the notch. Comes up and
    /// goes down with `app.notchEnabled`; does nothing until it is turned on.
    private let notchDriver: NotchWindowDriver

    /// Exports quota and menu-bar status to ~/.claudebar/status.json for Touch Bar, BTT, and external scripts.
    private let statusExportDriver: StatusExportDriver
    /// Publishes quota state to a linked Notify! device. Comes up and goes down
    /// with `notify.enabled`; does nothing until a device is linked.
    private let notifyDriver: NotifyPublishDriver

    /// Binding required by `.menuBarExtraAccess`; also enables programmatic
    /// dropdown control if ever needed.
    @State private var isMenuPresented = false

    @Environment(\.openWindow) private var openWindow

    /// The hook HTTP server that receives events from Claude Code
    private let hookServer = HookHTTPServer()

    /// Task for the hook server event loop (allows cancellation on toggle off)
    @State private var hookServerTask: Task<Void, Never>?

    /// Alerts users when quota status degrades
    private let quotaAlerter = NotificationAlerter()

    /// Sends session start/end notifications
    private let sessionAlertSender = SystemAlertSender()

    /// D — the verified account catalogue façade (`+` panel + row reconnects).
    private let accountCatalog: AccountCatalogModel

    #if ENABLE_SPARKLE
    /// Sparkle updater for auto-updates
    @State private var sparkleUpdater = SparkleUpdater()
    #endif

    init() {
        if CortexRuntime.isTesting || AccountDiagnostics.requested {
            let settings = AppSettings.shared
            let monitor = QuotaMonitor(providers: AIProviders(providers: []), alerter: quotaAlerter)
            let sessions = SessionMonitor()
            self.monitor = monitor
            self.sessionMonitor = sessions
            self.statusItemDriver = StatusItemLabelDriver(monitor: monitor, settings: settings, sessionMonitor: sessions)
            self.notchDriver = NotchWindowDriver(monitor: monitor, sessionMonitor: sessions, settings: settings)
            self.statusExportDriver = StatusExportDriver(monitor: monitor, settings: settings)
            self.notifyDriver = NotifyPublishDriver(monitor: monitor, settings: settings)
            let resolver = ProfileResolver()
            self.accountCatalog = AccountCatalogModel(enrolmentService: AccountEnrolmentService(),
                discovery: AccountDiscoveryService(resolver: resolver, validator: CLIProfileIdentityValidator()),
                resolver: resolver, settingsRepository: JSONSettingsRepository.shared,
                homeDirectory: CortexRuntime.testDirectory.path, activateIntegration: { _ in })
            if AccountDiagnostics.requested {
                Task { exit(await AccountDiagnostics.run()) }
            }
            return
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let provenance = BuildProvenance.current
        AppLog.ui.info("Cortex v\(version) (\(build)) initializing — git \(provenance.gitSHA), built \(provenance.builtAtUTC), dirty=\(provenance.isDirty)")

        // Create the shared settings repository (JSON-backed: ~/.claudebar/settings.json)
        // JSONSettingsRepository implements all sub-protocols:
        // - AppSettingsRepository (app-level display/sync settings)
        // - ProviderSettingsRepository + all provider sub-protocols
        // - HookSettingsRepository
        let settingsRepository = JSONSettingsRepository.shared

        // E4 bundle-id migration (non-destructive, idempotent): copy Keychain
        // items and UserDefaults keys from the legacy com.tddworks.claudebar
        // namespace. Old items are preserved; explicit new values win.
        // RC gate enabler: `CORTEX_SKIP_LEGACY_MIGRATORS=1` skips both reads
        // (no system prompt on the real login keychain); default path unchanged.
        if LegacyMigratorGate.shouldSkip() {
            AppLog.credentials.notice(
                "\(LegacyMigratorGate.skipEnvVar)=1 — legacy Keychain/UserDefaults migrators skipped (RC gate mode)"
            )
        } else {
            KeychainServiceMigrator.migrateIfNeeded()
            UserDefaultsDomainMigrator.migrateIfNeeded()
        }
        // Seed known Claude profiles so each isolated config directory
        // (e.g. ~/.claude, ~/.claude-admin) appears as a separate account.
        // First-run discovery shells out per candidate — dispatched off the
        // init critical path (idempotent; B2 doctrine: never block startup).
        Task { @MainActor in
            await CortexApp.seedClaudeAccountsIfNeeded(
                settingsRepository: settingsRepository
            )
        }
        // Backfill email on accounts that were seeded before the resolver
        // was wired (Ben 2026-08-19: dashboard couldn't tell which Claude
        // account was at 0% because the email was missing).
        CortexApp.backfillClaudeAccountEmailsIfNeeded(settingsRepository: settingsRepository)
        // Site-specific row bindings (E1): remember the local router id and
        // extra tmux sockets detected on this machine. No-ops everywhere else.
        LegacyInstallMigration.seedLocalRouterIdIfNeeded(settingsRepository: settingsRepository)
        LegacyInstallMigration.seedTmuxSocketsIfNeeded(settingsRepository: settingsRepository)
        // Bake in the curated roster: hide niche native probe providers so a
        // fresh install stays curated. Keys already stored are never clobbered.
        CortexApp.seedCuratedProviderDefaultsIfNeeded(settingsRepository: settingsRepository)
        // v7.2: drop the removed `qwen-api` provider settings subtree (dead
        // router id `qwen_cloud_payg`). Idempotent — no-op on a clean install.
        QwenApiRemovalMigration.applyIfNeeded()

        // Détection machine : un registre llm-router présent garde la lecture
        // partagée (comportement historique de cette machine) ; une installation
        // vierge part en sondes natives et ne suit pas d'office les lignes
        // strictement routeur (elles restent activables depuis le `+`).
        let routerRegistryPresent = RouterSourceModeMigration.routerRegistryPresent()
        RouterSourceModeMigration.applyFreshInstallDefaultsIfNeeded(
            settingsRepository: settingsRepository,
            registryPresent: routerRegistryPresent
        )

        // llm-router is the only quota/catalog authority for the router-backed
        // providers. One shared actor reads its versioned v2 snapshot; every
        // provider remains a first-class Cortex row without issuing a second
        // API/CLI quota probe.
        //
        // C4-2: `compose()` is synchronous and side-effect-free (configuration
        // + catalogue → providers). The router availability cache warm-up is an
        // explicit, lifecycle-owned call below — no DispatchSemaphore, no
        // `@unchecked Sendable` box, no main-actor blocking in `App.init()`.
        let routerSnapshotClient = LLMRouterSnapshotClient()
        APIAccountCredentials.importLocalAccounts(settings: settingsRepository)

        let composition = ProviderComposition(
            routerSnapshotClient: routerSnapshotClient,
            settingsRepository: settingsRepository,
            defaultSourceMode: routerRegistryPresent ? .router : .autonomous
        )
        let providers = composition.compose()
        composition.warmRouterAvailability()
        let repository = AIProviders(providers: providers)
        AppLog.providers.info("Created \(repository.all.count) providers")

        // Initialize the domain service with quota alerter
        // QuotaMonitor automatically validates selected provider on init
        let monitor = QuotaMonitor(
            providers: repository,
            alerter: quotaAlerter,
            providerFactory: { composition.makeProvider(id: $0) },
            cortexExporter: CortexAccountsExporter()
        )
        self.monitor = monitor
        AppLog.monitor.info("QuotaMonitor initialized")

        // D — verified account catalogue behind the `+`: the single injection
        // point for the dashboard rows (typed reconnect) and the catalogue
        // panel. Adapters default to their production probes; the discovery
        // sweep only reads official status surfaces and masks identities.
        //
        // Activation is IMMEDIATE (plan Cortex modulaire): the composition has
        // already run during launch, so flipping the setting alone would leave
        // the module invisible until the next start. We instantiate through the
        // same catalog-driven composition, hand the instance to the monitor and
        // start one collection — one provider, never a duplicate.
        let refreshAccount: @MainActor (String, String) async throws -> Date? = { providerId, accountId in
            settingsRepository.setEnabled(true, forProvider: providerId)
            guard let provider = composition.makeProvider(id: providerId) else {
                throw ProbeError.executionFailed("Provider unavailable")
            }
            _ = monitor.replaceProvider(provider)
            if let multi = provider as? any MultiAccountProvider {
                return try await multi.refreshAccount(accountId).capturedAt
            }
            return try await provider.refresh().capturedAt
        }
        let enrolmentService = AccountEnrolmentService(onVerified: { descriptor in
            let providerId = descriptor.providerId
            let previous = settingsRepository.accounts(forProvider: providerId).first {
                $0.probeConfig["accountUUID"] == descriptor.uuid.uuidString
                    || $0.descriptor(providerId: providerId).profile == descriptor.profile
            }
            let accountId = previous?.accountId ?? descriptor.uuid.uuidString
            if descriptor.source == .router {
                guard let target = RouterAccountTarget(rawValue: providerId),
                      let path = descriptor.profile.localPath,
                      let identity = descriptor.verifiedIdentity else {
                    throw EnrolmentError.registryRejected(reason: "Local profile required")
                }
                _ = try await RouterRegistrarCLI().register(.init(target: target,
                    alias: previous?.probeConfig["routerAlias"] ?? descriptor.label,
                    authHome: path, verifiedIdentity: identity))
            }
            let config = ProviderAccountConfig.from(descriptor: descriptor, accountId: accountId,
                preserving: previous?.probeConfig ?? [:])
            if previous == nil { settingsRepository.addAccount(config, forProvider: providerId) }
            else { settingsRepository.updateAccount(config, forProvider: providerId) }
            // Source mode is a provider-wide preference. A newly enrolled local profile
            // must be collected immediately even when this installation used router mode.
            for current in settingsRepository.accounts(forProvider: providerId) {
                var pc = current.probeConfig
                pc["providers.\(providerId).sourceMode"] = descriptor.source == .native ? "autonomous" : "router"
                settingsRepository.updateAccount(.init(accountId: current.accountId, label: current.label,
                    email: current.email, organization: current.organization, probeConfig: pc), forProvider: providerId)
            }
            guard settingsRepository.accounts(forProvider: providerId).contains(where: { $0.accountId == accountId }) else {
                throw ProbeError.executionFailed("Account could not be saved")
            }
            return try await refreshAccount(providerId, accountId)
        })
        let profileResolver = ProfileResolver()
        accountCatalog = AccountCatalogModel(
            enrolmentService: enrolmentService,
            discovery: AccountDiscoveryService(
                resolver: profileResolver,
                validator: CLIProfileIdentityValidator()
            ),
            resolver: profileResolver,
            settingsRepository: settingsRepository,
            homeDirectory: NSHomeDirectory(),
            accountChanged: refreshAccount
        ) { providerId in
            settingsRepository.setEnabled(true, forProvider: providerId)
            if monitor.follow(providerId: providerId) {
                AppLog.providers.info(
                    "Activated \(providerId) — followed via catalogue (instantiated if needed)"
                )
            } else {
                AppLog.providers.error(
                    "Activation failed for \(providerId) — no provider could be built from the catalogue"
                )
            }
        }

        let sessionMonitor = SessionMonitor()
        self.sessionMonitor = sessionMonitor

        // The driver owns the menu-bar pixels and the refresh-loop lifecycle
        // (outside SwiftUI — see StatusItemLabelDriver). Pixels start flowing
        // once `.menuBarExtraAccess` hands over the NSStatusItem.
        statusItemDriver = StatusItemLabelDriver(
            monitor: monitor,
            settings: AppSettings.shared,
            sessionMonitor: sessionMonitor
        )
        statusItemDriver.startMonitoringLifecycle()
        statusItemDriver.startAttachLifecycle()

        notchDriver = NotchWindowDriver(
            monitor: monitor,
            sessionMonitor: sessionMonitor,
            settings: AppSettings.shared
        )
        notchDriver.startWhenLaunched()

        statusExportDriver = StatusExportDriver(
            monitor: monitor,
            settings: AppSettings.shared
        )
        statusExportDriver.start()

        NativeTouchBarDriver.shared.configure(monitor: monitor)

        PersistentTouchBarDriver.shared.configure(
            monitor: monitor,
            settings: AppSettings.shared,
            sessionMonitor: sessionMonitor
        )
        PersistentTouchBarDriver.shared.start()
        // Started here rather than deferred to `didFinishLaunching` like the
        // notch driver: the surface it drives is on the user's phone, so it
        // touches no AppKit window and has nothing to wait for.
        notifyDriver = NotifyPublishDriver(
            monitor: monitor,
            settings: AppSettings.shared
        )
        notifyDriver.start()

        // Load user extensions from ~/.claudebar/extensions/
        let extensionRegistry = ExtensionRegistry(
            settingsRepository: settingsRepository,
            configRepository: AppSettings.shared.extensionConfig
        )
        let extensionProviders = extensionRegistry.loadExtensions(into: monitor)
        if !extensionProviders.isEmpty {
            AppLog.providers.info("Loaded \(extensionProviders.count) extension provider(s): \(extensionProviders.map(\.name).joined(separator: ", "))")
        }

        // Start hook server if hooks are enabled
        if settingsRepository.isHookEnabled() {
            // Reconcile installed hooks so newly-added events (e.g.
            // UserPromptSubmit, which revives a stopped session) register for
            // existing users without re-toggling the setting. install() is
            // idempotent — it replaces only Cortex's own matcher entries
            // per event and preserves hooks from other tools.
            if HookInstaller.isInstalled() {
                try? HookInstaller.install()
            }
            startHookServer()
        }

        // Start the passive status-line observer when the adapter is enabled
        // so the shim installed by the Hooks toggle has a listener to POST
        // to. Without this the toggle installs a shim pointing at a dead
        // port. Idempotent — start() is a no-op when already listening.
        if settingsRepository.isClaudeStatusLineAdapterEnabled() {
            do {
                try StatusLineObserver.shared.start()
            } catch {
                AppLog.hooks.error("Status-line observer failed to start: \(error.localizedDescription)")
            }
        }

        // Note: Notification permission is requested in onAppear, not here
        // Menu bar apps need the run loop to be active before requesting permissions

        AppLog.ui.info("Cortex initialization complete")
    }

    /// App settings for theme
    @State private var settings = AppSettings.shared

    /// Current theme mode from settings
    private var currentThemeMode: ThemeMode {
        ThemeMode(rawValue: settings.themeMode) ?? .system
    }

    private func startHookServer() {
        // Cancel any existing server task
        hookServerTask?.cancel()
        hookServer.stop()

        hookServerTask = Task {
            do {
                let events = try await hookServer.start()
                AppLog.hooks.info("Hook server started, listening for events")
                for await event in events {
                    // Ignore Cortex's own background quota probe so routine
                    // polling doesn't spam "Claude Code Finished: Probe"
                    // notifications or pollute the recent-sessions list. (issue #172)
                    guard !event.isCortexProbe else { continue }
                    await sessionMonitor.processEvent(event)
                    await sendSessionNotification(for: event)
                }
            } catch {
                AppLog.hooks.error("Failed to start hook server: \(error.localizedDescription)")
            }
        }
    }

    func stopHookServer() {
        hookServerTask?.cancel()
        hookServerTask = nil
        hookServer.stop()
    }

    @MainActor private func sendSessionNotification(for event: SessionEvent) {
        let projectName = (event.cwd as NSString).lastPathComponent

        switch event.eventName {
        case .sessionStart:
            Task {
                try? await sessionAlertSender.send(
                    title: "Claude Code Started",
                    body: "Session started in \(projectName)",
                    categoryIdentifier: "SESSION_START"
                )
            }
        case .sessionEnd:
            let taskCount = sessionMonitor.recentSessions.first?.completedTaskCount ?? 0
            let duration = sessionMonitor.recentSessions.first?.durationDescription ?? ""
            let summary = taskCount > 0
                ? "Completed \(taskCount) task\(taskCount == 1 ? "" : "s") in \(duration)"
                : "Session ended after \(duration)"
            Task {
                try? await sessionAlertSender.send(
                    title: "Claude Code Finished",
                    body: "\(projectName) — \(summary)",
                    categoryIdentifier: "SESSION_END"
                )
            }
        default:
            break
        }
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) {
        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch action {
        case "refresh":
            Task {
                await monitor.refreshAll()
            }
        case "open":
            isMenuPresented = true
            NSApp.activate(ignoringOtherApps: true)
        case "settings":
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        default:
            AppLog.ui.info("Received unhandled URL: \(url.absoluteString)")
        }
    }

    /// Detects and validates isolated Claude config directories on first run.
    /// Existing accounts are authoritative and are never replaced or pruned.
    @MainActor
    static func seedClaudeAccountsIfNeeded(settingsRepository: any MultiAccountSettingsRepository) async {
        let existing = settingsRepository.accounts(forProvider: "claude")
        guard existing.isEmpty else { return }
        // Validation shells out to `claude auth status --json` per candidate —
        // async since upstream made CLIExecutor async, and run OFF the init
        // critical path (first-run seeding is idempotent and can land a beat
        // after the first frame; B2 doctrine: discovery never blocks startup).
        let discovered = await ClaudeAccountDiscovery().discover(existing: existing)
        for candidate in discovered {
            settingsRepository.addAccount(
                candidate,
                forProvider: "claude"
            )
        }
    }

    /// Backfills the `email` field on existing Claude accounts that were
    /// seeded before the resolver was wired. Runs unconditionally on
    /// every startup — cheap (one file read per account) and idempotent.
    /// Skips accounts that already have an email. Resolves via
    /// `ClaudeAccountInfoResolver` against `<configDir>/.claude.json`
    /// (or `~/.claude.json` for the default account where configDir == HOME).
    /// Ben 2026-08-19: needed to tell which Claude account was at 0%.
    static func backfillClaudeAccountEmailsIfNeeded(settingsRepository: any MultiAccountSettingsRepository) {
        for config in settingsRepository.accounts(forProvider: "claude") {
            guard config.email == nil else { continue }
            guard let configDir = config.probeConfig["claudeConfigDir"] else { continue }
            let jsonPath = (configDir as NSString).appendingPathComponent(".claude.json")
            guard FileManager.default.fileExists(atPath: jsonPath) else { continue }
            let resolver = ClaudeAccountInfoResolver(configURL: URL(fileURLWithPath: jsonPath))
            guard let email = resolver.resolve()?.email else { continue }
            settingsRepository.updateAccount(
                ProviderAccountConfig(
                    accountId: config.accountId,
                    label: config.label,
                    email: email,
                    organization: config.organization,
                    probeConfig: config.probeConfig
                ),
                forProvider: "claude"
            )
        }
    }

    /// Disables providers that a fresh install should not surface unprompted:
    /// native probe providers outside the default roster, PLUS the optional
    /// pay-as-you-go / credentialed connectors (Qwen API, AWS Bedrock, Local)
    /// which must be opted into explicitly via the `+` catalog rather than
    /// appearing as empty rows. Only writes when the `providers.<id>.isEnabled`
    /// key is absent — a later manual re-enable in Settings is honored and
    /// never clobbered on restart (an already-stored true/false is preserved).
    static func seedCuratedProviderDefaultsIfNeeded(settingsRepository: any ProviderSettingsRepository) {
        // NOTE 2026-09-20: "opencode-go" removed from this list — now a first-class
        // subscription (API probe + DB fallback), surfaced by default like "commandcode".
        let disabledByDefault = [
            "omp", "kiro", "ampcode",
            "grok", "cursor", "mistral", "deepseek", "vercel-gateway",
            // Optional connectors: available in the catalog, never auto-shown.
            "bedrock", "local",
        ]
        for id in disabledByDefault {
            // Key absent iff the two defaults disagree (each falls back to its own).
            let keyAbsent = settingsRepository.isEnabled(forProvider: id, defaultValue: true)
                != settingsRepository.isEnabled(forProvider: id, defaultValue: false)
            guard keyAbsent else { continue }
            settingsRepository.setEnabled(false, forProvider: id)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Group {
                #if ENABLE_SPARKLE
                MenuContentView(monitor: monitor, sessionMonitor: sessionMonitor, quotaAlerter: quotaAlerter) { enabled in
                        if enabled { startHookServer() } else { stopHookServer() }
                    }
                    .appThemeProvider(themeModeId: settings.themeMode)
                    .environment(\.sparkleUpdater, sparkleUpdater)
                    .environment(accountCatalog)
                #else
                MenuContentView(monitor: monitor, sessionMonitor: sessionMonitor, quotaAlerter: quotaAlerter) { enabled in
                        if enabled { startHookServer() } else { stopHookServer() }
                    }
                    .appThemeProvider(themeModeId: settings.themeMode)
                    .environment(accountCatalog)
                #endif
            }
            // Opening/closing the dropdown flips `isMenuPresented`, which makes
            // SwiftUI re-evaluate the scene and wipe the AppKit-drawn button
            // image. The dropdown's lifecycle maps 1:1 to those flips, so
            // re-assert the menu-bar pixels on both edges.
            .onAppear { statusItemDriver.reassertPresentation() }
            .onDisappear { statusItemDriver.reassertPresentation() }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
        } label: {
            // Deliberately static: the menu-bar pixels are drawn by
            // StatusItemLabelDriver into the status item's button image,
            // because this SwiftUI label hosting can permanently stop
            // re-evaluating after system sleep (issue #192). The placeholder
            // only gives the scene a label to anchor the dropdown to.
            Color.clear.frame(width: 1, height: 1)
        }
        // Must be the first scene modifier (extends MenuBarExtra, not Scene).
        .menuBarExtraAccess(isPresented: $isMenuPresented) { statusItem in
            statusItemDriver.attach(statusItem)
        }
        .menuBarExtraStyle(.window)

        // Standalone Settings window (opened from the popover's gear button).
        // Hidden title bar: the sidebar runs the full window height and the
        // traffic lights overlay its top — see SettingsWindowView.
        Window("Cortex Settings", id: "settings") {
            Group {
                #if ENABLE_SPARKLE
                SettingsWindowView(monitor: monitor, notifyDriver: notifyDriver) { enabled in
                    if enabled { startHookServer() } else { stopHookServer() }
                }
                .appThemeProvider(themeModeId: settings.themeMode)
                .environment(\.sparkleUpdater, sparkleUpdater)
                #else
                SettingsWindowView(monitor: monitor, notifyDriver: notifyDriver) { enabled in
                    if enabled { startHookServer() } else { stopHookServer() }
                }
                .appThemeProvider(themeModeId: settings.themeMode)
                #endif
            }
            .environment(accountCatalog)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 660)
        .windowResizability(.contentMinSize)
    }

}

private func sessionPhaseColor(_ phase: ClaudeSession.Phase) -> Color {
    phase.color
}

/// The menu bar icon that reflects the overall quota status.
/// When a Claude Code session is active, shows a terminal icon with phase color.
/// Uses theme's `statusBarIconName` if set, otherwise shows status-based icons.
struct StatusBarIcon: View {
    let status: QuotaStatus
    var activeSession: ClaudeSession? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        if let session = activeSession {
            // Active session: show terminal icon with phase color
            HStack(spacing: 3) {
                Image(systemName: "terminal.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(sessionPhaseColor(session.phase))
                Image(systemName: iconName)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(iconColor)
            }
        } else {
            Image(systemName: iconName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(iconColor)
        }
    }

    private var iconName: String {
        // Use theme's custom icon if provided
        if let themeIcon = theme.statusBarIconName {
            return themeIcon
        }
        // Otherwise use status-based icon
        switch status {
        case .depleted:
            return "chart.bar.xaxis"
        case .critical:
            return "exclamationmark.triangle.fill"
        case .warning, .healthy:
            return "chart.bar.fill"
        }
    }

    private var iconColor: Color {
        theme.statusColor(for: status)
    }
}

// MARK: - StatusBarIcon Preview

#Preview("StatusBarIcon - All States") {
    HStack(spacing: 30) {
        VStack {
            StatusBarIcon(status: .healthy)
            Text("HEALTHY")
                .font(.caption)
                .foregroundStyle(.green)
        }
        VStack {
            StatusBarIcon(status: .warning)
            Text("WARNING")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        VStack {
            StatusBarIcon(status: .critical)
            Text("CRITICAL")
                .font(.caption)
                .foregroundStyle(.red)
        }
        VStack {
            StatusBarIcon(status: .depleted)
            Text("DEPLETED")
                .font(.caption)
                .foregroundStyle(.red)
        }
        VStack {
            StatusBarIcon(status: .healthy)
                .appThemeProvider(themeModeId: "cli")
            Text("CLI")
                .font(.caption)
                .foregroundStyle(CLITheme().accentPrimary)
        }
        VStack {
            StatusBarIcon(status: .healthy)
                .appThemeProvider(themeModeId: "christmas")
            Text("CHRISTMAS")
                .font(.caption)
                .foregroundStyle(ChristmasTheme().accentPrimary)
        }
    }
    .padding(40)
    .background(Color.black)
}
