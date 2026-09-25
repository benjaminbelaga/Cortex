import Foundation
import Mockable

/// Repository protocol for all app-level settings (display, sync, budget, etc.).
/// Provider-specific settings live in `ProviderSettingsRepository` sub-protocols.
///
/// Both protocols share one backing store (`~/.claudebar/settings.json`).
/// `AppSettings` wraps this as an `@Observable` for SwiftUI.
@Mockable
public protocol AppSettingsRepository: Sendable {
    // MARK: - Theme

    func themeMode() -> String
    func setThemeMode(_ mode: String)

    func userHasChosenTheme() -> Bool
    func setUserHasChosenTheme(_ chosen: Bool)

    // MARK: - Display

    func usageDisplayMode() -> String
    func setUsageDisplayMode(_ mode: String)

    func menuBarPercentageEnabled() -> Bool
    func setMenuBarPercentageEnabled(_ enabled: Bool)

    func menuBarDurationEnabled() -> Bool
    func setMenuBarDurationEnabled(_ enabled: Bool)

    func menuBarStackedEnabled() -> Bool
    func setMenuBarStackedEnabled(_ enabled: Bool)

    func menuBarStackedSize() -> String
    func setMenuBarStackedSize(_ size: String)

    func menuBarPercentageProviderId() -> String
    func setMenuBarPercentageProviderId(_ providerId: String)

    /// Additional providers displayed after the primary, limited to two.
    func menuBarAdditionalProviderIds() -> [String]
    func setMenuBarAdditionalProviderIds(_ providerIds: [String])

    func menuBarProviderSettings() -> [String: MenuBarProviderSettings]
    func setMenuBarProviderSettings(_ settings: [String: MenuBarProviderSettings])

    func menuBarPercentageQuotaKey() -> String
    func setMenuBarPercentageQuotaKey(_ quotaKey: String)

    func menuBarSecondaryQuotaKey() -> String
    func setMenuBarSecondaryQuotaKey(_ quotaKey: String)

    func showDailyUsageCards() -> Bool
    func setShowDailyUsageCards(_ show: Bool)

    // MARK: - Notch

    /// Whether the notch live activity is shown (default: false).
    func notchEnabled() -> Bool
    func setNotchEnabled(_ enabled: Bool)

    // MARK: - Touch Bar

    /// Whether Touch Bar status integration is enabled (default: true).
    func touchBarEnabled() -> Bool
    func setTouchBarEnabled(_ enabled: Bool)

    // MARK: - Overview

    func overviewModeEnabled() -> Bool
    func setOverviewModeEnabled(_ enabled: Bool)

    /// Which window's percentage drives the overview dashboard (R11 selector).
    func overviewWindowFilter() -> OverviewWindowFilter
    func setOverviewWindowFilter(_ filter: OverviewWindowFilter)

    /// Overview dashboard row ordering.
    func overviewSort() -> OverviewSort
    func setOverviewSort(_ sort: OverviewSort)

    /// Multi-account provider groups the user collapsed/expanded in the overview.
    /// Absent id = collapsed (the default keeps the list synthetic).
    func overviewExpandedGroups() -> Set<String>
    func setOverviewExpandedGroups(_ ids: Set<String>)

    /// Preferred model families per overview row id (`provider` or `provider|account`).
    /// A display preference, never a routing guarantee (bible §6).
    func preferredModels() -> [String: [String]]
    func setPreferredModels(_ map: [String: [String]])

    /// Provider-level preferred LLM (Settings → provider): one family id per
    /// provider id, shown ONCE on the provider's group header. A display
    /// preference, never a routing guarantee (bible §6).
    func providerPreferredModel() -> [String: String]
    func setProviderPreferredModel(_ map: [String: String])

    /// Selected "Priority" recommendation profile (plan / execute / flexible).
    /// Stored as the raw string; defaults to `.plan`.
    func routeProfile() -> RouterRouteNow.Profile
    func setRouteProfile(_ profile: RouterRouteNow.Profile)

    /// Whether the "Priority" card is expanded (default: collapsed).
    func priorityCardExpanded() -> Bool
    func setPriorityCardExpanded(_ expanded: Bool)

    /// What the menu-bar glyph shows (text / running cat / both).
    func menuBarGlyphMode() -> MenuBarGlyphMode
    func setMenuBarGlyphMode(_ mode: MenuBarGlyphMode)

    // MARK: - Background Sync

    func backgroundSyncEnabled() -> Bool
    func setBackgroundSyncEnabled(_ enabled: Bool)

    func backgroundSyncInterval() -> TimeInterval
    func setBackgroundSyncInterval(_ interval: TimeInterval)

    // MARK: - Claude API Budget

    func claudeApiBudgetEnabled() -> Bool
    func setClaudeApiBudgetEnabled(_ enabled: Bool)

    func claudeApiBudget() -> Double
    func setClaudeApiBudget(_ amount: Double)

    // MARK: - Burn Rate Warning

    func burnRateWarningEnabled() -> Bool
    func setBurnRateWarningEnabled(_ enabled: Bool)

    func burnRateThreshold() -> Double
    func setBurnRateThreshold(_ threshold: Double)

    // MARK: - Updates

    func receiveBetaUpdates() -> Bool
    func setReceiveBetaUpdates(_ receive: Bool)
}
