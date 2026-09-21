import Foundation
import Domain
import Infrastructure
import ServiceManagement

/// Observable settings manager for ClaudeBar preferences.
/// Thin `@Observable` wrapper around `AppSettingsRepository` for SwiftUI reactivity.
/// All persistence is delegated to the repository (`~/.claudebar/settings.json`).
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    /// The underlying repository (internal - views access settings through AppSettings properties/methods)
    private let repository: JSONSettingsRepository

    // MARK: - Theme Settings

    /// The current theme mode (light, dark, system, christmas)
    public var themeMode: String {
        didSet {
            repository.setThemeMode(themeMode)
            if !isInitializing {
                userHasChosenTheme = true
            }
        }
    }

    /// Whether the user has explicitly chosen a theme (vs auto-enabled Christmas)
    public var userHasChosenTheme: Bool {
        didSet {
            repository.setUserHasChosenTheme(userHasChosenTheme)
        }
    }

    // MARK: - Display Settings

    /// Whether to show quota as remaining, used, or pace-aware.
    public var usageDisplayMode: UsageDisplayMode {
        didSet {
            repository.setUsageDisplayMode(usageDisplayMode.rawValue)
        }
    }

    /// Whether the menu bar label should show a selected quota percentage instead of the icon.
    public var menuBarPercentageEnabled: Bool {
        didSet {
            repository.setMenuBarPercentageEnabled(menuBarPercentageEnabled)
        }
    }

    /// Whether the menu bar label should show the compact reset duration for the
    /// selected quota. Independent of `menuBarPercentageEnabled`; both can be on
    /// simultaneously (in which case they are joined by " · ").
    public var menuBarDurationEnabled: Bool {
        didSet {
            repository.setMenuBarDurationEnabled(menuBarDurationEnabled)
        }
    }

    /// Whether a dual-window menu bar label should render as two stacked
    /// smaller lines (one per quota window) instead of one long "A | B" line,
    /// roughly halving the menu bar width it occupies. Opt-in, default off;
    /// has no effect while only a single quota window is shown.
    public var menuBarStackedEnabled: Bool {
        didSet {
            repository.setMenuBarStackedEnabled(menuBarStackedEnabled)
        }
    }

    /// Text size for the stacked menu bar lines. Small is the original 9pt
    /// rendering and the default; Medium (10pt) and Large (11pt) trade some of
    /// the inter-line breathing room for legibility. Only consulted while
    /// `menuBarStackedEnabled` is actually rendering two lines.
    public var menuBarStackedSize: MenuBarStackedSize {
        didSet {
            repository.setMenuBarStackedSize(menuBarStackedSize.rawValue)
        }
    }

    /// Provider used for the menu bar percentage label.
    public var menuBarPercentageProviderId: String {
        didSet {
            repository.setMenuBarPercentageProviderId(menuBarPercentageProviderId)
            menuBarAdditionalProviderIds = repository.menuBarAdditionalProviderIds()
        }
    }

    /// Up to two extra providers; the primary keeps its existing quota settings.
    public var menuBarAdditionalProviderIds: [String] {
        didSet {
            repository.setMenuBarAdditionalProviderIds(menuBarAdditionalProviderIds)
            let normalized = repository.menuBarAdditionalProviderIds()
            if menuBarAdditionalProviderIds != normalized {
                menuBarAdditionalProviderIds = normalized
            }
        }
    }

    public var menuBarProviderSettings: [String: MenuBarProviderSettings] {
        didSet { repository.setMenuBarProviderSettings(menuBarProviderSettings) }
    }

    public var menuBarProviderIds: [String] {
        [menuBarPercentageProviderId] + menuBarAdditionalProviderIds
    }

    public func menuBarConfiguration(for providerId: String) -> MenuBarProviderSettings {
        if providerId == menuBarPercentageProviderId {
            return MenuBarProviderSettings(
                primaryQuotaKey: menuBarPercentageQuotaKey, secondaryQuotaKey: menuBarSecondaryQuotaKey,
                stacked: menuBarStackedEnabled, stackedSize: menuBarStackedSize.rawValue
            )
        }
        return menuBarProviderSettings[providerId] ?? MenuBarProviderSettings()
    }

    public func setMenuBarConfiguration(_ config: MenuBarProviderSettings, for providerId: String) {
        menuBarProviderSettings[providerId] = config
        if providerId == menuBarPercentageProviderId {
            menuBarPercentageQuotaKey = config.primaryQuotaKey
            menuBarSecondaryQuotaKey = config.secondaryQuotaKey
            menuBarStackedEnabled = config.stacked
            menuBarStackedSize = MenuBarStackedSize(storedRawValue: config.stackedSize)
        }
    }

    public func setMenuBarProviderIds(_ providerIds: [String]) {
        var seen: Set<String> = [""]
        let ids = Array(providerIds.filter { seen.insert($0).inserted }.prefix(3))
        guard let first = ids.first else { return }
        if first != menuBarPercentageProviderId {
            // Keep the legacy fields in sync for Touch Bar and status export while
            // remembering each provider's choices when its position changes.
            menuBarProviderSettings[menuBarPercentageProviderId] = menuBarConfiguration(for: menuBarPercentageProviderId)
            let config = menuBarConfiguration(for: first)
            menuBarPercentageProviderId = first
            setMenuBarConfiguration(config, for: first)
        }
        menuBarAdditionalProviderIds = Array(ids.dropFirst())
    }

    /// Quota key used for the menu bar percentage label.
    public var menuBarPercentageQuotaKey: String {
        didSet {
            repository.setMenuBarPercentageQuotaKey(menuBarPercentageQuotaKey)
        }
    }

    /// Optional secondary quota key shown alongside the primary in the menu bar
    /// (e.g. weekly next to session). Empty string means no secondary window.
    public var menuBarSecondaryQuotaKey: String {
        didSet {
            repository.setMenuBarSecondaryQuotaKey(menuBarSecondaryQuotaKey)
        }
    }

    /// Whether to show daily usage report cards (API Cost, Token Usage, Working Time)
    public var showDailyUsageCards: Bool {
        didSet {
            repository.setShowDailyUsageCards(showDailyUsageCards)
        }
    }

    // MARK: - Notch Settings

    /// Whether Claude Code session and quota state is drawn into the notch
    /// (default: false).
    public var notchEnabled: Bool {
        didSet {
            repository.setNotchEnabled(notchEnabled)
        }
    }

    // MARK: - Touch Bar Settings

    /// Whether Touch Bar status integration is enabled (default: true).
    public var touchBarEnabled: Bool {
        didSet {
            repository.setTouchBarEnabled(touchBarEnabled)
        }
    }

    // MARK: - Notify Settings

    /// Whether quota state is published to a linked Notify! device
    /// (default: false). The feature sends data to a third party service, so it
    /// can never come up switched on.
    public var notifyEnabled: Bool {
        didSet {
            repository.setNotifyEnabled(notifyEnabled)
        }
    }

    /// Whether the Lock Screen Live Activity is one of the surfaces published.
    public var notifyLiveActivityEnabled: Bool {
        didSet {
            repository.setNotifyLiveActivityEnabled(notifyLiveActivityEnabled)
        }
    }

    /// Whether the Lock Screen widget gauge is one of the surfaces published.
    public var notifyWidgetEnabled: Bool {
        didSet {
            repository.setNotifyWidgetEnabled(notifyWidgetEnabled)
        }
    }

    /// Whether the Home Screen widget is one of the surfaces published. It
    /// carries the same content as the Live Activity, and unlike it, it stays.
    public var notifyScreenWidgetEnabled: Bool {
        didSet {
            repository.setNotifyScreenWidgetEnabled(notifyScreenWidgetEnabled)
        }
    }

    /// Provider whose quota the widget gauge shows. Empty means "whichever
    /// quota needs attention most", which is what a glance wants before the
    /// user has picked anything.
    public var notifyGaugeProviderId: String {
        didSet {
            repository.setNotifyGaugeProviderId(notifyGaugeProviderId)
        }
    }

    /// Quota window the widget gauge shows. Empty is automatic, as above.
    public var notifyGaugeQuotaKey: String {
        didSet {
            repository.setNotifyGaugeQuotaKey(notifyGaugeQuotaKey)
        }
    }

    // MARK: - Overview Mode Settings

    /// Whether to show all enabled providers at once instead of one at a time
    public var overviewModeEnabled: Bool {
        didSet {
            repository.setOverviewModeEnabled(overviewModeEnabled)
        }
    }

    /// Which window's percentage drives the overview dashboard (R11 selector).
    public var overviewWindowFilter: OverviewWindowFilter {
        didSet {
            repository.setOverviewWindowFilter(overviewWindowFilter)
        }
    }

    /// Overview dashboard row ordering.
    public var overviewSort: OverviewSort {
        didSet {
            repository.setOverviewSort(overviewSort)
        }
    }

    /// What the menu-bar glyph shows (text / running cat / both).
    public var menuBarGlyphMode: MenuBarGlyphMode {
        didSet {
            repository.setMenuBarGlyphMode(menuBarGlyphMode)
        }
    }

    // MARK: - Background Sync Settings

    /// Whether background sync is enabled (default: true; explicit Off persists)
    public var backgroundSyncEnabled: Bool {
        didSet {
            repository.setBackgroundSyncEnabled(backgroundSyncEnabled)
        }
    }

    /// Background sync interval in seconds (default: 120)
    public var backgroundSyncInterval: TimeInterval {
        didSet {
            repository.setBackgroundSyncInterval(backgroundSyncInterval)
        }
    }

    /// The background-refresh cadence (Off / 1 / 2 / 5 / 10 / 15 min) as a single
    /// picker-friendly value. Computed over the legacy `backgroundSyncEnabled`
    /// + `backgroundSyncInterval` pair so `settings.json` stays backward
    /// compatible — "Off" maps to `backgroundSyncEnabled == false`, the others
    /// to enabled + 60/120/300/600/900s. Setting it persists both underlying keys.
    public var refreshInterval: RefreshInterval {
        get {
            RefreshInterval.migrating(
                enabled: backgroundSyncEnabled,
                storedSeconds: backgroundSyncInterval
            )
        }
        set {
            // Set the interval before flipping enabled so anything observing the
            // change sees the final cadence in a single pass.
            if let seconds = newValue.seconds {
                backgroundSyncInterval = TimeInterval(seconds)
            }
            backgroundSyncEnabled = newValue.isEnabled
        }
    }

    // MARK: - Claude Status-Line Adapter

    /// Whether the passive Claude status-line adapter is enabled.
    /// Opt-in: when flipped on, `ClaudeStatusLineInstaller.install()`
    /// writes a shim under `~/.claudebar/bin/` and patches the user's
    /// `statusLine.command` in `~/.claude/settings.json`. Flipping off
    /// restores the original command byte-for-byte.
    public var claudeStatusLineAdapterEnabled: Bool {
        didSet {
            repository.setClaudeStatusLineAdapterEnabled(claudeStatusLineAdapterEnabled)
        }
    }

    // MARK: - Claude API Budget Settings

    /// Whether Claude API budget tracking is enabled
    public var claudeApiBudgetEnabled: Bool {
        didSet {
            repository.setClaudeApiBudgetEnabled(claudeApiBudgetEnabled)
        }
    }

    /// The budget threshold for Claude API usage (in dollars)
    public var claudeApiBudget: Decimal {
        didSet {
            repository.setClaudeApiBudget(NSDecimalNumber(decimal: claudeApiBudget).doubleValue)
        }
    }

    // MARK: - Burn Rate Warning Settings

    /// Whether burn rate-based warnings are enabled (default: false, uses absolute thresholds)
    public var burnRateWarningEnabled: Bool {
        didSet {
            repository.setBurnRateWarningEnabled(burnRateWarningEnabled)
        }
    }

    /// The burn rate multiplier threshold above which warnings fire (default: 1.5)
    public var burnRateThreshold: Double {
        didSet {
            repository.setBurnRateThreshold(burnRateThreshold)
        }
    }

    // MARK: - Update Settings

    /// Whether to receive beta updates (default: false)
    public var receiveBetaUpdates: Bool {
        didSet {
            repository.setReceiveBetaUpdates(receiveBetaUpdates)
            NotificationCenter.default.post(name: .betaUpdatesSettingChanged, object: nil)
        }
    }

    // MARK: - Launch at Login Settings

    /// Whether the app should launch at login (backed by SMAppService, not JSON)
    public var launchAtLogin: Bool {
        didSet {
            guard !isInitializing else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    // MARK: - Internal

    private var isInitializing = true

    // MARK: - Initialization

    init(repository: JSONSettingsRepository = .shared) {
        self.repository = repository

        // Load all values from repository
        self.themeMode = repository.themeMode()
        self.userHasChosenTheme = repository.userHasChosenTheme()
        self.claudeApiBudgetEnabled = repository.claudeApiBudgetEnabled()
        self.claudeStatusLineAdapterEnabled = repository.isClaudeStatusLineAdapterEnabled()
        self.claudeApiBudget = Decimal(repository.claudeApiBudget())
        self.receiveBetaUpdates = repository.receiveBetaUpdates()
        self.burnRateWarningEnabled = repository.burnRateWarningEnabled()
        self.burnRateThreshold = repository.burnRateThreshold()
        self.showDailyUsageCards = repository.showDailyUsageCards()
        self.notchEnabled = repository.notchEnabled()
        self.touchBarEnabled = repository.touchBarEnabled()
        self.notifyEnabled = repository.isNotifyEnabled()
        self.notifyLiveActivityEnabled = repository.isNotifyLiveActivityEnabled()
        self.notifyWidgetEnabled = repository.isNotifyWidgetEnabled()
        self.notifyScreenWidgetEnabled = repository.isNotifyScreenWidgetEnabled()
        self.notifyGaugeProviderId = repository.notifyGaugeProviderId()
        self.notifyGaugeQuotaKey = repository.notifyGaugeQuotaKey()
        self.overviewModeEnabled = repository.overviewModeEnabled()
        self.overviewWindowFilter = repository.overviewWindowFilter()
        self.overviewSort = repository.overviewSort()
        self.menuBarGlyphMode = repository.menuBarGlyphMode()
        self.backgroundSyncEnabled = repository.backgroundSyncEnabled()
        self.backgroundSyncInterval = repository.backgroundSyncInterval()
        self.menuBarPercentageEnabled = repository.menuBarPercentageEnabled()
        self.menuBarDurationEnabled = repository.menuBarDurationEnabled()
        self.menuBarStackedEnabled = repository.menuBarStackedEnabled()
        // The stored size decodes through the Domain fallback so an unknown
        // raw value (from a newer build's settings file) renders small
        // instead of crashing or dropping the label.
        self.menuBarStackedSize = MenuBarStackedSize(storedRawValue: repository.menuBarStackedSize())
        self.menuBarPercentageProviderId = repository.menuBarPercentageProviderId()
        self.menuBarAdditionalProviderIds = repository.menuBarAdditionalProviderIds()
        self.menuBarProviderSettings = repository.menuBarProviderSettings()
        self.menuBarPercentageQuotaKey = repository.menuBarPercentageQuotaKey()
        self.menuBarSecondaryQuotaKey = repository.menuBarSecondaryQuotaKey()

        if let mode = UsageDisplayMode(rawValue: repository.usageDisplayMode()) {
            self.usageDisplayMode = mode
        } else {
            self.usageDisplayMode = .remaining
        }

        // Launch at login - read from SMAppService (system service, not JSON)
        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        applySeasonalTheme()
        self.isInitializing = false
    }

    // MARK: - Seasonal Theme

    public static func isChristmasPeriod(date: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return false }
        return month == 12 && (24...26).contains(day)
    }

    private func applySeasonalTheme() {
        let isChristmas = Self.isChristmasPeriod()

        if isChristmas {
            if !userHasChosenTheme {
                themeMode = "christmas"
            }
        } else {
            if themeMode == "christmas" && !userHasChosenTheme {
                themeMode = "system"
            }
        }
    }

    // MARK: - Provider Settings Access

    /// Access provider-specific settings for reading/writing in Settings UI.
    /// These are non-observable (loaded into @State) - only app-level settings are @Observable.
    public var provider: ProviderSettingsRepository { repository }
    public var claude: ClaudeSettingsRepository { repository }

    /// Extra tmux socket names for the sessions card. Read live (not cached
    /// at init) so a settings change applies on the next popover open.
    public var tmuxSocketNames: [String] { repository.tmuxSocketNames() }
    public var codex: CodexSettingsRepository { repository }
    public var kimi: KimiSettingsRepository { repository }
    public var copilot: CopilotSettingsRepository { repository }
    public var zai: ZaiSettingsRepository { repository }
    public var bedrock: BedrockSettingsRepository { repository }
    public var minimax: MiniMaxSettingsRepository { repository }
    public var deepseek: DeepSeekSettingsRepository { repository }
    public var alibaba: AlibabaSettingsRepository { repository }
    public var vercel: VercelSettingsRepository { repository }
    public var hook: HookSettingsRepository { repository }
    public var notify: NotifySettingsRepository { repository }

    // MARK: - Module Presentation (visibilité + suivi)

    /// Révision des réglages de modules. Touchée à chaque écriture pour que les
    /// vues qui filtrent sur la présentation se redessinent : SwiftUI observe
    /// les propriétés stockées, pas les lectures directes du store.
    public private(set) var modulesRevision: Int = 0

    /// Visibilité effective d'un module (réglage stocké, sinon défaut déclaré).
    public func moduleVisibility(_ module: FeatureModule) -> ModuleVisibility {
        moduleVisibility(id: module.rawValue, fallback: module.defaultVisibility)
    }

    public func setModuleVisibility(_ visibility: ModuleVisibility, for module: FeatureModule) {
        setModuleVisibility(visibility, id: module.rawValue)
    }

    /// Variante par identifiant libre : un module (`sessions`) ou un outil
    /// (`claude`, `opencode-go`) partagent le même mécanisme de présentation.
    public func moduleVisibility(id: String, fallback: ModuleVisibility) -> ModuleVisibility {
        _ = modulesRevision   // enregistre la dépendance d'observation
        return repository.moduleVisibility(forModule: id, default: fallback)
    }

    public func setModuleVisibility(_ visibility: ModuleVisibility, id: String) {
        repository.setModuleVisibility(visibility, forModule: id)
        modulesRevision += 1
    }

    /// Suivi d'un outil/connexion : `providers.<id>.isEnabled`, avec le défaut
    /// déclaré par le descripteur (une connexion optionnelle reste éteinte).
    public func isFollowed(providerId: String) -> Bool {
        _ = modulesRevision
        let fallback = ProviderCatalog.descriptor(forId: providerId)?.defaultEnabled ?? false
        return repository.isEnabled(forProvider: providerId, defaultValue: fallback)
    }

    public func setFollowed(_ followed: Bool, providerId: String) {
        repository.setEnabled(followed, forProvider: providerId)
        modulesRevision += 1
    }

    /// Options du module sessions stockées comme une visibilité : sous-agents,
    /// état « en attente », etc. — un seul mécanisme, aucune clé ad hoc.
    public func sessionOption(_ id: String, fallback: ModuleVisibility = .visible) -> ModuleVisibility {
        moduleVisibility(id: "sessions.\(id)", fallback: fallback)
    }

    public func setSessionOption(_ visibility: ModuleVisibility, id: String) {
        setModuleVisibility(visibility, id: "sessions.\(id)")
    }

    /// Extension config repository for dynamic extension provider settings.
    public let extensionConfig: any ExtensionConfigRepository = JSONExtensionConfigRepository(
        settingsStore: .shared
    )
}

// MARK: - Notification Names

extension Notification.Name {
    static let betaUpdatesSettingChanged = Notification.Name("betaUpdatesSettingChanged")
}
