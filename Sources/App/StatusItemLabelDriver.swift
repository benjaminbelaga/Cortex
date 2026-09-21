import AppKit
import CoreText
import SwiftUI
import Domain
import Infrastructure

/// Drives the menu-bar status item imperatively (AppKit), bypassing SwiftUI's
/// `MenuBarExtra` label hosting entirely.
///
/// After system sleep, the MenuBarExtra label hosting view can permanently
/// stop receiving SwiftUI invalidations: the dropdown window keeps updating
/// while the label — and any `.task` attached to it — goes dead until relaunch
/// (issue #192). This driver owns both things that used to live on that label:
///
/// 1. **The pixels** — an `ObservationRenderSync` reads the same observable
///    state the SwiftUI label did (monitor, settings, session) and draws the
///    composed label into `statusItem.button.image`.
/// 2. **The background-refresh lifecycle** — a second sync watches the refresh
///    cadence/target settings and restarts `QuotaMonitor.startMonitoring`,
///    replacing the label's `.task(id:)`.
///
/// Lives for the app's lifetime; the closure retain cycles this creates are
/// intentional and harmless.
@MainActor
final class StatusItemLabelDriver {
    private let monitor: QuotaMonitor
    private let settings: AppSettings
    private let sessionMonitor: SessionMonitor

    private var statusItem: NSStatusItem?
    private var labelSync: ObservationRenderSync<LabelContent>?
    private var loopSync: ObservationRenderSync<RefreshLoopKey>?
    private var blinkSync: ObservationRenderSync<Bool>?
    private var streamConsumer: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// Polls for a status item we can actually draw into. See
    /// `startAttachLifecycle` for why MenuBarExtraAccess alone isn't enough.
    private var attachWatchdog: Task<Void, Never>?

    /// One-shot latch so a missing button is logged once, not twice a second.
    private var hasLoggedMissingButton = false
    private var appearanceObserver: NSObjectProtocol?

    /// Drives the countdown: every tick re-reads the label (picking up the
    /// current wall clock) and flips `blinkPhase`. See `startBlinkTimer`.
    private var blinkTimer: Timer?
    private var blinkPhase = true

    /// The image currently owned by this driver, and the content it encodes.
    /// Used both to skip redundant redraws (repainting an intact image can
    /// itself flicker) and to recognize external wipes via KVO.
    private var lastImage: NSImage?
    private var lastContent: LabelContent?
    private var lastLabelSelection: [String]?
    private var imageWipeObservation: NSKeyValueObservation?

    init(monitor: QuotaMonitor, settings: AppSettings, sessionMonitor: SessionMonitor) {
        self.monitor = monitor
        self.settings = settings
        self.sessionMonitor = sessionMonitor
    }

    // No deinit: this object lives for the app's lifetime, so the wake
    // observer is intentionally never removed (and a nonisolated deinit
    // could not touch the @MainActor-isolated observer under Swift 6).

    // MARK: - Label Rendering

    /// Everything the menu-bar pixels depend on. Reading these properties
    /// inside the sync's `read` registers observation for each of them.
    struct LabelContent: Equatable {
        var label: MenuBarLabel?
        var additionalLabels: [MenuBarProviderLabel] = []
        var primaryProviderId: String? = nil
        var primaryProviderName: String? = nil
        var fallbackStatus: QuotaStatus
        var sessionPhase: ClaudeSession.Phase?
        var themeModeId: String
        /// Whether a dual-window label should render as two stacked smaller
        /// lines instead of one long "A | B" line (opt-in setting).
        var stacked: Bool = false
        /// The user-selected text size for the stacked lines. Carried in the
        /// content (not read at draw time) so changing the size in Settings
        /// invalidates the observation sync and repaints the label.
        var stackedSize: MenuBarStackedSize = .default
        /// Blink phase for an H:MM countdown's separator colon. Only alternates
        /// while the label actually holds a countdown colon, so a "2d" or "45m"
        /// label keeps comparing equal across ticks and never repaints for the
        /// blink alone (see `render`'s early-out).
        var colonVisible: Bool = true
        /// Glyph mode (text / running cat / both). Carried so flipping the
        /// setting in Settings repaints the menu bar.
        var glyphMode: MenuBarGlyphMode = .text
        /// Current stride frame of the running cat. Advances on the cat timer,
        /// so each tick produces unequal content and repaints — same trick as
        /// `colonVisible`.
        var catFrame: Int = 0
        /// Worst remaining percentage across all enabled providers — drives the
        /// cat's continuous green→amber→red tint. nil = no data (gray cat).
        var catHealthPercent: Double?
        /// Effective macOS appearance. The final status item is a mixed raster
        /// (adaptive brain + health-colored text), so the whole image cannot be
        /// marked template; carrying the scheme makes the brain repaint black
        /// in light mode and white in dark mode.
        var isDarkAppearance = false
        /// Active multi-account email (when the selected provider is a
        /// MultiAccountProvider with ≥2 accounts). Surfaced in the tooltip so
        /// Ben can identify which Claude profile is logged in at a glance —
        /// the menu-bar glyph itself doesn't carry it (cat + percentage only).
        var accountEmail: String?
        /// Compact suffix of the multi-account email rendered inline in the
        /// dual-bar path (e.g. "ben@") — derived from `accountEmail`. nil when
        /// no disambiguation is needed (single-account provider, or cat mode
        /// active which doesn't render the badge at all).
        var inlineEmailSuffix: String?
    }

    /// Attaches to an `NSStatusItem` and starts rendering. Repeated callbacks
    /// re-assert the image (cheap, idempotent).
    ///
    /// Rejects an item with no `button`, because every render into it would
    /// silently no-op and the menu bar would show nothing but the 1x1
    /// placeholder label — an invisible, unfindable status item with no route
    /// to Settings (issue #258).
    ///
    /// That is reachable through MenuBarExtraAccess, which hands over
    /// `statusItems[0]`. With "Displays have Separate Spaces" there is one
    /// `NSStatusBarWindow` per screen — the real item plus one replicant per
    /// additional display — and only the real one carries a button. Before
    /// macOS 26 the replicant was a distinct class the library filtered out;
    /// on macOS 26 both report `NSSceneStatusItem`, so its filter keeps both
    /// and which one lands at index 0 is left to `NSApp.windows` ordering.
    func attach(_ statusItem: NSStatusItem) {
        guard statusItem.button != nil else {
            AppLog.ui.warning("Status item has no button (per-display replicant); looking for the real one")
            startAttachWatchdog()
            return
        }
        guard self.statusItem !== statusItem else {
            labelSync?.renderNow()
            return
        }
        attachWatchdog?.cancel()
        attachWatchdog = nil
        hasLoggedMissingButton = false
        self.statusItem = statusItem
        labelSync?.stop()

        let sync = ObservationRenderSync(
            read: { [self] in currentLabelContent() },
            render: { [self] content in render(content) }
        )
        labelSync = sync
        sync.start()
        startBlinkLifecycle()
        startCatLifecycle()

        // SwiftUI wipes `button.image` whenever the scene re-evaluates (every
        // dropdown open/close flips the `isPresented` binding). Restore it
        // synchronously in the same runloop pass so a blank frame never
        // reaches the screen — repainting from `onAppear`/`onDisappear` alone
        // leaves a visible flash.
        imageWipeObservation?.invalidate()
        imageWipeObservation = statusItem.button?.observe(\.image, options: [.new]) { [weak self] button, change in
            MainActor.assumeIsolated {
                guard let self, let owned = self.lastImage else { return }
                if button.image !== owned {
                    button.image = owned
                }
            }
        }

        if wakeObserver == nil {
            // Belt-and-braces: repaint after wake even if nothing changed,
            // in case the menu bar was rebuilt with stale content.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.labelSync?.renderNow() }
            }
        }
        if appearanceObserver == nil {
            appearanceObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.labelSync?.refreshNow() }
            }
        }
    }

    /// Defense-in-depth repaint around dropdown open/close (the KVO observer
    /// in `attach` is the primary guard against SwiftUI's image wipes). A
    /// no-op when the image is intact, so it never causes extra redraws.
    func reassertPresentation() {
        labelSync?.renderNow()
    }

    private func currentLabelContent() -> LabelContent {
        // Empty primary key = "whatever the provider's first quota is" (the
        // upstream default before an explicit selection exists).
        let primaryQuotaKey = settings.menuBarPercentageQuotaKey.isEmpty
            ? (monitor.provider(for: settings.menuBarPercentageProviderId)?.snapshot?.quotas.first?.quotaType.quotaKey ?? "session")
            : settings.menuBarPercentageQuotaKey
        let menuBarSelection = monitor.menuBarSnapshotSelection(
            providerId: settings.menuBarPercentageProviderId,
            quotaKeys: [
                settings.menuBarPercentageQuotaKey,
                settings.menuBarSecondaryQuotaKey,
            ]
        )
        let freshLabel = monitor.menuBarLabel(
            providerId: settings.menuBarPercentageProviderId,
            primaryQuotaKey: primaryQuotaKey,
            secondaryQuotaKey: settings.menuBarSecondaryQuotaKey,
            showPercentage: settings.menuBarPercentageEnabled,
            showDuration: settings.menuBarDurationEnabled,
            mode: settings.usageDisplayMode,
            burnRateWarningEnabled: settings.burnRateWarningEnabled,
            burnRateThreshold: settings.burnRateThreshold
        )

        let selection = [settings.menuBarPercentageProviderId,
                         settings.menuBarPercentageQuotaKey, settings.menuBarSecondaryQuotaKey,
                         String(settings.menuBarPercentageEnabled), String(settings.menuBarDurationEnabled),
                         settings.usageDisplayMode.rawValue]
        let label = freshLabel ?? (lastLabelSelection == selection
            ? lastKnownLabel(whenFreshIsMissing: freshLabel) : nil)
        lastLabelSelection = selection
        let additionalLabels = monitor.additionalMenuBarLabels(
            providerIds: settings.menuBarAdditionalProviderIds,
            configurations: settings.menuBarProviderSettings,
            showPercentage: settings.menuBarPercentageEnabled,
            showDuration: settings.menuBarDurationEnabled,
            mode: settings.usageDisplayMode,
            burnRateWarningEnabled: settings.burnRateWarningEnabled,
            burnRateThreshold: settings.burnRateThreshold
        )
        let hasCountdownColon = ([label].compactMap { $0 } + additionalLabels.map(\.label))
            .contains { !CountdownColon.ranges(in: $0.text).isEmpty }
        let primaryProviderName = additionalLabels.isEmpty ? nil : monitor.enabledProviders
            .first { $0.id == settings.menuBarPercentageProviderId }?.name

        // Email from the exact same account snapshot as the menu-bar quotas.
        // Never use monitor.selectedProvider here: the configured menu-bar
        // provider can differ from the open dropdown provider.
        let accountEmail: String? = {
            guard let account = menuBarSelection?.account else { return nil }
            return menuBarSelection?.snapshot.accountEmail ?? account.email
        }()

        return LabelContent(
            label: label,
            additionalLabels: additionalLabels,
            primaryProviderId: primaryProviderName == nil ? nil : settings.menuBarPercentageProviderId,
            primaryProviderName: primaryProviderName,
            fallbackStatus: effectiveSelectedProviderStatus,
            sessionPhase: sessionMonitor.activeSession?.phase,
            themeModeId: settings.themeMode,
            stacked: settings.menuBarStackedEnabled,
            stackedSize: settings.menuBarStackedSize,
            colonVisible: hasCountdownColon ? blinkPhase : true,
            glyphMode: settings.menuBarGlyphMode,
            catFrame: catFrameIndex,
            catHealthPercent: fleetHealthPercent,
            isDarkAppearance: NSApp.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
            accountEmail: accountEmail,
            inlineEmailSuffix: accountEmail.flatMap { Self.compactEmailSuffix(from: $0) }
        )
    }

    /// Builds the compact inline email suffix used by the dual-bar renderer.
    /// Strategy: keep the local-part (everything before "@") + the first
    /// letter of the domain. Examples:
    ///   - "work@example.com"          → "work@e"
    ///   - "personal@example.com"       → "personal@e"
    ///   - "benjamin.belaga@gmail.com"  → "benjamin.belaga@g"
    /// This keeps the badge readable in 9pt without overflowing the menu-bar
    /// width — full emails live in the tooltip + dashboard row.
    private static func compactEmailSuffix(from email: String) -> String? {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let local = String(parts[0])
        let domainFirst = parts[1].first.map { String($0) } ?? ""
        guard !domainFirst.isEmpty else { return nil }
        return "\(local)@\(domainFirst)"
    }

    /// Fleet-availability health for the brain glyph (Ben 2026-08-24: "le
    /// cerveau est rouge alors que j'ai des modèles dispo"). The glyph must
    /// answer "do I have a usable model right now?", not "is any single window
    /// low?" — one exhausted provider must not turn it red while five others
    /// are full (and a local model is always available as a fallback).
    ///
    /// So it is the health of the BEST available provider: the maximum, across
    /// enabled providers, of each provider's own bottleneck (its worst
    /// trustworthy window). It only slides to amber/red when the WHOLE fleet is
    /// getting low. Stale readings (old manual Qwen sync, errored provider) are
    /// excluded; the per-provider "under 10%" detail lives in the overview
    /// banner + the rows, never squeezed into this one colour.
    private var fleetHealthPercent: Double? {
        var best: Double?
        for provider in monitor.enabledProviders {
            guard let snapshot = provider.snapshot else { continue }
            var providerBottleneck: Double?
            for quota in snapshot.quotas where !quota.isDollarBased && !quota.isStale {
                providerBottleneck = min(providerBottleneck ?? quota.percentRemaining, quota.percentRemaining)
            }
            if let providerBottleneck {
                best = max(best ?? providerBottleneck, providerBottleneck)
            }
        }
        return best
    }

    /// Bridges a momentarily-missing menu-bar label. The configured quota window
    /// can briefly vanish from a snapshot (cold start before the first success, a
    /// parse gap), which would otherwise collapse the menu bar to a lone icon. As
    /// long as the menu-bar provider is enabled and still holds a snapshot, keep
    /// the last value we showed instead of blanking the number. Returns nil when
    /// we have nothing to fall back to, so the normal "no data yet" icon shows.
    private func lastKnownLabel(whenFreshIsMissing freshLabel: MenuBarLabel?) -> MenuBarLabel? {
        guard freshLabel == nil, let previous = lastContent?.label else { return nil }
        let providerHasSnapshot = monitor.enabledProviders.contains {
            $0.id == settings.menuBarPercentageProviderId && $0.snapshot != nil
        }
        return providerHasSnapshot ? previous : nil
    }

    /// Status of the selected provider, considering the burn-rate setting.
    /// Mirrors the dropdown's status logic for the icon-only fallback.
    private var effectiveSelectedProviderStatus: QuotaStatus {
        guard let snapshot = monitor.selectedProvider?.snapshot else { return .healthy }
        if settings.burnRateWarningEnabled {
            return snapshot.paceAwareOverallStatus(burnRateThreshold: settings.burnRateThreshold)
        }
        return snapshot.overallStatus
    }

    private func render(_ content: LabelContent) {
        guard let button = statusItem?.button else {
            // Loud but once: the symptom is a menu bar item that is invisible
            // and unclickable, which otherwise leaves no trace in the log.
            if !hasLoggedMissingButton {
                hasLoggedMissingButton = true
                AppLog.ui.error("Status item has no button — nothing can be drawn into the menu bar")
            }
            return
        }
        // Skip when nothing changed and our image is still in place —
        // re-setting an identical image redraws the button and can flicker.
        if content == lastContent, let lastImage, button.image === lastImage {
            return
        }
        let image = Self.compose(content, theme: resolvedTheme(for: content.themeModeId))
        lastContent = content
        lastImage = image
        button.image = image
        button.imagePosition = .imageOnly
        // Tooltip: prepend the multi-account email so hovering reveals which
        // Claude profile is logged in. Falls back to label text when the
        // provider is single-account (no disambiguation needed).
        if let email = content.accountEmail {
            button.toolTip = "\(email) — \(content.label?.text ?? "")"
        } else {
            button.toolTip = content.label?.text
        }
    }

    private func resolvedTheme(for themeModeId: String) -> any AppThemeProvider {
        let scheme: ColorScheme = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        return ThemeRegistry.shared.resolveTheme(for: themeModeId, systemColorScheme: scheme)
    }

    // MARK: - Image Composition

    /// Composes the full status-item image: optional session glyph, then the
    /// usage text — or the themed status icon when no label is configured or
    /// no quota data exists yet. Mirrors the old SwiftUI label exactly.
    static func compose(_ content: LabelContent, theme: any AppThemeProvider) -> NSImage {
        var parts: [NSImage] = []

        // Only surface the session glyph while Claude is actively working. A
        // finished/idle (.stopped) or .ended session must not leave a lone
        // orange glyph sitting in the menu bar — that reads as a frozen crash
        // (the user's report) since `Stop` fires at the end of every turn.
        if let phase = content.sessionPhase, phase == .active || phase == .subagentsWorking {
            parts.append(symbolImage("terminal.fill", color: NSColor(phase.color)))
        }

        // The final status image also contains health-colored text, therefore
        // macOS cannot template the whole composite. Tint only the vector brain
        // explicitly: black in Aqua, white in Dark Aqua. Health remains on the
        // colored percentage next to it.
        if content.glyphMode.showsBrain {
            parts.append(Self.symbolImage(
                "brain.fill",
                color: Self.brainColor(isDarkAppearance: content.isDarkAppearance)
            ))
        }

        if content.glyphMode.showsText, let label = content.label {
            // Dual-bar path takes priority whenever both percentage values are
            // available. The email suffix is useful context, not a prerequisite.
            if Self.shouldRenderDualBars(stacked: content.stacked, segments: label.segments),
               let topPct = label.segments[0].percentRemaining,
               let bottomPct = label.segments[1].percentRemaining {
                parts.append(StatusBarDualBarImageRenderer.image(
                    top: (topPct, theme.statusColor(for: label.segments[0].status)),
                    bottom: (bottomPct, theme.statusColor(for: label.segments[1].status)),
                    track: theme.progressTrack,
                    emailSuffix: content.inlineEmailSuffix,
                    emailSuffixColor: theme.textTertiary
                ))
            } else if content.stacked, label.segments.count == 2 {
                parts.append(StatusBarStackedImageRenderer.image(
                    top: (label.segments[0].text, theme.statusColor(for: label.segments[0].status)),
                    bottom: (label.segments[1].text, theme.statusColor(for: label.segments[1].status)),
                    size: content.stackedSize,
                    colonVisible: content.colonVisible
                ))
            } else {
                parts.append(StatusBarPercentageImageRenderer.image(
                    text: label.text,
                    color: theme.statusColor(for: label.status),
                    colonVisible: content.colonVisible
                ))
            }
        } else if !content.glyphMode.showsBrain {
            let symbolName = theme.statusBarIconName ?? theme.statusIcon(for: content.fallbackStatus)
            parts.append(symbolImage(
                symbolName,
                color: NSColor(theme.statusColor(for: content.fallbackStatus))
            ))
        }

        for label in content.additionalLabels {
            parts.append(StatusBarPercentageImageRenderer.image(
                text: " | ", color: theme.statusColor(for: label.status)
            ))
            parts.append(providerIcon(for: label.providerId))
            parts.append(quotaImage(label.label, stacked: label.stacked, size: label.stackedSize,
                                    colonVisible: content.colonVisible, theme: theme))
        }
        return hStack(parts, spacing: 3)
    }

    /// Pure routing rule used by the renderer and AppTests. Account email is
    /// deliberately absent: dual bars remain useful for single-account and
    /// email-less providers.
    static func shouldRenderDualBars(
        stacked: Bool,
        segments: [MenuBarLabel.Segment]
    ) -> Bool {
        stacked
            && segments.count == 2
            && segments.allSatisfy { $0.percentRemaining != nil }
    }

    /// Continuous green→amber→red tint for the cat's health, interpolated —
    /// no hard status bands, so the color "glides" as quotas drain (Ben:
    /// « un chat qui change de couleur subtilement »). nil (no data) = gray.
    static func catTint(for percent: Double?) -> NSColor {
        guard let percent else {
            return NSColor.systemGray
        }
        let green = NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)   // #30D158
        let amber = NSColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1)     // #FF9500
        let red = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)      // #FF453A
        let clamped = min(max(percent, 0), 100)
        switch clamped {
        case 40...100:
            return interpolate(green, amber, (100 - clamped) / 60)
        case 5..<40:
            return interpolate(amber, red, (40 - clamped) / 35)
        default:
            return red
        }
    }

    private static func interpolate(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        let t = CGFloat(min(max(t, 0), 1))
        return NSColor(
            red: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1
        )
    }

    // MARK: - (removed fallbackIconName — superseded by theme.statusIcon(for:) in AppThemeProvider)


    static func brainColor(isDarkAppearance: Bool) -> NSColor {
        isDarkAppearance ? .white : .black
    }

    /// Renders an SF Symbol tinted with a fixed color, since the status item
    /// image is non-template (theme colors must survive menu bar appearance).
    private static func symbolImage(_ name: String, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(configuration) else {
            return NSImage(size: .zero)
        }
        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    /// Composites images horizontally, vertically centered.
    private static func hStack(_ images: [NSImage], spacing: CGFloat) -> NSImage {
        let images = images.filter { $0.size.width > 0 }
        guard !images.isEmpty else { return NSImage(size: .zero) }

        let width = images.map(\.size.width).reduce(0, +) + spacing * CGFloat(images.count - 1)
        let height = images.map(\.size.height).max() ?? 0
        let composed = NSImage(size: NSSize(width: ceil(width), height: ceil(height)), flipped: false) { _ in
            var x: CGFloat = 0
            for image in images {
                image.draw(at: NSPoint(x: x, y: (height - image.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
                x += image.size.width + spacing
            }
            return true
        }
        composed.isTemplate = false
        return composed
    }

    // MARK: - Attachment Lifecycle

    /// Retry cadence for finding the status item: fast at first (it normally
    /// exists within a second of launch), then backing off to cover a slow
    /// first launch. Gives up after roughly two minutes.
    private static let attachRetryDelays: [Double] =
        Array(repeating: 0.25, count: 20)   // first 5s
        + Array(repeating: 1.0, count: 25)  // to 30s
        + Array(repeating: 5.0, count: 18)  // to ~2min

    /// Starts owning the status-item attachment instead of depending solely on
    /// MenuBarExtraAccess. Call once at app startup, alongside
    /// `startMonitoringLifecycle`.
    ///
    /// The library's introspection has two failure modes that both leave the
    /// menu bar permanently blank (issue #258): it hands over `statusItems[0]`,
    /// which on macOS 26 can be the button-less per-display replicant (see
    /// `attach`), and it polls for only two seconds before giving up for the
    /// rest of the app's lifetime. Since v0.4.69 every visible pixel is drawn
    /// into `button.image` — the SwiftUI label is a 1x1 transparent
    /// placeholder — so either failure means no icon, no width, and no way to
    /// open Settings.
    func startAttachLifecycle() {
        startAttachWatchdog()

        guard screenObserver == nil else { return }
        // Attaching or detaching a display rebuilds the status bar windows, so
        // the item we hold can turn into a replicant. Re-check on every change.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.revalidateAttachment() }
        }
    }

    /// Polls for a drawable status item until one turns up. A no-op while we
    /// already hold one, and while a poll is already running.
    private func startAttachWatchdog() {
        guard attachWatchdog == nil, statusItem?.button == nil else { return }
        attachWatchdog = Task { @MainActor [weak self] in
            // Release the slot however this ends, so a later display change can
            // start a fresh search instead of being locked out by a spent task.
            defer { self?.attachWatchdog = nil }
            for delay in Self.attachRetryDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                guard self.statusItem?.button == nil else { return }
                guard let item = Self.drawableStatusItem() else { continue }
                AppLog.ui.notice("Attached to the status item via the watchdog")
                self.attach(item)
                return
            }
            AppLog.ui.error("No drawable status item found — the menu bar will stay blank")
        }
    }

    /// Drops an item we can no longer draw into and goes looking for the real
    /// one; otherwise just repaints, in case the menu bar was rebuilt stale.
    private func revalidateAttachment() {
        guard statusItem?.button == nil else {
            labelSync?.renderNow()
            return
        }
        statusItem = nil
        startAttachWatchdog()
    }

    /// The app's own status items, read the way AppKit exposes them: every
    /// `NSStatusBarWindow` carries its item under a private `statusItem` key.
    /// Only the real item has a button — the per-display replicants do not —
    /// so that, not position, is what identifies the one we can render into.
    private static func drawableStatusItem() -> NSStatusItem? {
        NSApplication.shared.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap { window -> NSStatusItem? in
                guard window.responds(to: Selector(("statusItem"))) else { return nil }
                return window.value(forKey: "statusItem") as? NSStatusItem
            }
            .first { $0.button != nil }
    }

    // MARK: - Countdown Tick

    /// Half a second on, half a second off — the cadence a digital clock blinks
    /// its separator at. Also the rate the label re-reads the wall clock, so a
    /// countdown advances within half a second of the true minute boundary.
    private static let blinkInterval: TimeInterval = 0.5

    /// Starts watching whether a duration is shown at all, running the
    /// countdown tick only while one is. Sibling of `startMonitoringLifecycle`.
    ///
    /// Before this existed the label had no clock: the countdown text is
    /// computed fresh on every draw, but nothing *caused* a draw on a time
    /// basis. It advanced only as a side effect of something else changing — a
    /// probe result, a Claude Code hook event, opening the dropdown — so on an
    /// idle machine with background refresh off it could sit visibly stale.
    private func startBlinkLifecycle() {
        guard blinkSync == nil else { return }
        let sync = ObservationRenderSync<Bool>(
            read: { [self] in settings.menuBarDurationEnabled },
            render: { [self] showsDuration in
                showsDuration ? startBlinkTimer() : stopBlinkTimer()
            }
        )
        blinkSync = sync
        sync.start()
    }

    private func startBlinkTimer() {
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blinkPhase.toggle()
                // refreshNow, not renderNow: the tick must not arm a new
                // observation registration twice a second, and must keep the
                // equality check so a colon-less label ("2d") never repaints.
                self.labelSync?.refreshNow()
            }
        }
        // .common, not the default mode: a runloop in tracking mode (any menu
        // open) would otherwise stall the tick and freeze the colon mid-pulse.
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopBlinkTimer() {
        guard blinkTimer != nil else { return }
        blinkTimer?.invalidate()
        blinkTimer = nil
        // Never leave the colon parked in its dimmed phase.
        blinkPhase = true
        labelSync?.refreshNow()
    }

    // MARK: - Cat Animation

    /// Frame interval bounds for the running cat. Like RunCat, the cat's stride
    /// SPEED reflects machine load: idle → ~5 fps (calm walk), saturated → ~25
    /// fps (frantic sprint). Ben 2026-08-23: "le petit chat qui court permet de
    /// juger le pourcentage de charge d'un coup d'œil."
    private static let catIntervalIdle: TimeInterval = 0.2   // ~5 fps
    private static let catIntervalBusy: TimeInterval = 0.04  // ~25 fps

    private var catTimer: Timer?
    private var catFrameIndex = 0
    private var catSync: ObservationRenderSync<Bool>?

    /// Current stride interval derived from the 1-minute load average per core
    /// (`getloadavg`, the same signal RunCat uses). load/core 0 → idle cadence,
    /// ≥1.0 → busy cadence, linearly interpolated between. No Guardian/probe
    /// dependency — a single cheap syscall on each frame.
    private func currentCatInterval() -> TimeInterval {
        var loads = [Double](repeating: 0, count: 1)
        guard getloadavg(&loads, 1) == 1 else { return Self.catIntervalIdle }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let perCore = max(0, min(1, loads[0] / cores))
        return Self.catIntervalIdle
            - perCore * (Self.catIntervalIdle - Self.catIntervalBusy)
    }

    /// The Cortex brain glyph is STATIC (Ben 2026-08-24) — the running-cat
    /// stride animation is retired here (it stays RunCat's job). This lifecycle
    /// now only ever stops the timer, so the menu-bar glyph costs zero ongoing
    /// CPU; the brain still re-tints on health changes via the normal label
    /// refresh. Kept as a method (not deleted) so re-enabling motion is a
    /// one-line change if ever wanted.
    private func startCatLifecycle() {
        guard catSync == nil else { return }
        let sync = ObservationRenderSync<Bool>(
            read: { [self] in settings.menuBarGlyphMode.showsBrain },
            render: { [self] _ in stopCatTimer() }
        )
        catSync = sync
        sync.start()
    }

    private func startCatTimer() {
        guard catTimer == nil else { return }
        scheduleNextCatFrame()
    }

    /// Schedules one stride frame, then reschedules itself with a freshly
    /// sampled interval so the run speed tracks live machine load. A repeating
    /// timer cannot change its interval, so each frame is a one-shot that
    /// re-arms the next — the load re-read is one cheap syscall per frame.
    private func scheduleNextCatFrame() {
        let timer = Timer(timeInterval: currentCatInterval(), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.catTimer != nil else { return }
                self.catFrameIndex = (self.catFrameIndex + 1) % RunningCatRenderer.frameCount
                // refreshNow keeps the observation registration intact and the
                // equality early-out in render() — each tick's frame index
                // differs, so exactly one repaint happens.
                self.labelSync?.refreshNow()
                self.scheduleNextCatFrame()
            }
        }
        // .common: keep running while any menu is open (tracking mode).
        RunLoop.main.add(timer, forMode: .common)
        catTimer = timer
    }

    private func stopCatTimer() {
        guard catTimer != nil else { return }
        catTimer?.invalidate()
        catTimer = nil
        catFrameIndex = 0
        labelSync?.refreshNow()
    }


    private static func quotaImage(_ label: MenuBarLabel, stacked: Bool, size: MenuBarStackedSize,
                                   colonVisible: Bool, theme: any AppThemeProvider) -> NSImage {
        if stacked, label.segments.count == 2 {
            return StatusBarStackedImageRenderer.image(
                top: (label.segments[0].text, theme.statusColor(for: label.segments[0].status)),
                bottom: (label.segments[1].text, theme.statusColor(for: label.segments[1].status)),
                size: size, colonVisible: colonVisible
            )
        }
        return StatusBarPercentageImageRenderer.image(
            text: label.text, color: theme.statusColor(for: label.status), colonVisible: colonVisible
        )
    }

    private static func providerIcon(for providerId: String) -> NSImage {
        let assetName = ProviderVisualIdentityLookup.iconAssetName(for: providerId)
        guard let source = NSImage(named: assetName), source.size.width > 0, source.size.height > 0 else {
            return symbolImage(ProviderVisualIdentityLookup.symbolIcon(for: providerId), color: .labelColor)
        }
        let size = NSSize(width: 16, height: 16)
        let scale = min(size.width / source.size.width, size.height / source.size.height)
        let fitted = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let icon = NSImage(size: size, flipped: false) { bounds in
            let rect = NSRect(x: (bounds.width - fitted.width) / 2,
                              y: (bounds.height - fitted.height) / 2,
                              width: fitted.width, height: fitted.height)
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        icon.isTemplate = false
        return icon
    }

    private static func fallbackIconName(for status: QuotaStatus) -> String {
        switch status {
        case .depleted: "chart.bar.xaxis"
        case .critical: "exclamationmark.triangle.fill"
        case .warning, .healthy: "chart.bar.fill"
        }
    }

    // MARK: - Background Refresh Lifecycle

    /// Identity for the background-refresh loop — replaces the `.task(id:)`
    /// that lived on the (freeze-prone) SwiftUI label.
    struct RefreshLoopKey: Equatable {
        var isEnabled: Bool
        var seconds: Int
        var providerIds: [String]?
        var allAccountsForProviderId: String?
    }

    /// Starts watching the refresh cadence/target settings and (re)starts the
    /// monitoring loop whenever they change. Call once at app startup.
    func startMonitoringLifecycle() {
        guard loopSync == nil else { return }
        let sync = ObservationRenderSync(
            read: { [self] in currentRefreshLoopKey() },
            render: { [self] key in restartMonitoring(key) }
        )
        loopSync = sync
        sync.start()
    }

    private func currentRefreshLoopKey() -> RefreshLoopKey {
        let interval = settings.refreshInterval
        return RefreshLoopKey(
            isEnabled: interval.isEnabled,
            seconds: interval.seconds ?? 0,
            providerIds: backgroundRefreshProviderIds,
            allAccountsForProviderId: backgroundMultiAccountProviderId
        )
    }

    /// The configured menu-bar provider needs every account refreshed because
    /// its label deliberately represents the worst matching account.
    private var backgroundMultiAccountProviderId: String? {
        let providerId = settings.menuBarPercentageProviderId
        guard settings.menuBarPercentageEnabled || settings.menuBarDurationEnabled,
              let multi = monitor.provider(for: providerId) as? any MultiAccountProvider,
              multi.accounts.count > 1 else { return nil }
        return providerId
    }

    /// While the dropdown is closed, keep the selected/menu-bar providers plus
    /// one router-backed provider fresh. The latter updates the shared global
    /// usage snapshot even when a native provider is selected.
    private var backgroundRefreshProviderIds: [String]? {
        let enabledProviderIds = Set(monitor.enabledProviders.map(\.id))
        var candidates = [monitor.selectedProviderId]
        if settings.menuBarPercentageEnabled || settings.menuBarDurationEnabled {
            candidates.append(settings.menuBarPercentageProviderId)
        }
        if let routerProvider = monitor.enabledProviders.first(where: { $0 is RouterBackedProvider }) {
            candidates.append(routerProvider.id)
        }
        var seen = Set<String>()
        return candidates.filter { enabledProviderIds.contains($0) && seen.insert($0).inserted }
    }

    private func restartMonitoring(_ key: RefreshLoopKey) {
        streamConsumer?.cancel()
        streamConsumer = nil
        guard key.isEnabled else {
            monitor.stopMonitoring()
            return
        }
        AppLog.monitor.info("Background refresh starting (interval: \(key.seconds)s, providers: \(key.providerIds?.joined(separator: ",") ?? "selected"))")
        let stream = monitor.startMonitoring(
            interval: .seconds(key.seconds),
            providerIds: key.providerIds,
            allAccountsForProviderId: key.allAccountsForProviderId
        )
        streamConsumer = Task {
            // Each refresh tick imperatively forces a repaint. We can't rely on
            // the @Observable chain alone: after long idle it can stop delivering
            // invalidations (issue #192), freezing the menu-bar image even while
            // probes keep succeeding. renderNow() dedupes inside render(), so this
            // is cheap and only repaints when the composed image actually changed.
            for await _ in stream {
                self.labelSync?.renderNow()
            }
        }
    }
}

/// Pulses the separator colon of an H:MM countdown by fading it, shared by both
/// status-bar renderers.
///
/// Fading rather than hiding is deliberate. The label is drawn in
/// `monospacedDigitSystemFont`, where only the *digits* are fixed-width —
/// punctuation stays proportional. Substituting a space for the colon would
/// therefore change the label's width twice a second and shove every menu bar
/// item to its left. The glyph always draws at full size; only its alpha
/// changes, so the metrics are identical in both phases.
enum CountdownColonStyle {
    /// Alpha of the colon in its dimmed phase. Low enough to read as a pulse,
    /// high enough that the time never looks like it lost a character.
    private static let dimmedAlpha: CGFloat = 0.25

    /// Dims the countdown colons in `attributed` when the blink phase is off.
    /// A no-op in the visible phase, and for any text with no countdown colon.
    @MainActor
    static func apply(colonVisible: Bool, to attributed: NSMutableAttributedString, baseColor: Color) {
        guard !colonVisible else { return }
        let text = attributed.string
        let ranges = CountdownColon.ranges(in: text)
        guard !ranges.isEmpty else { return }

        let dimmed = NSColor(baseColor).withAlphaComponent(dimmedAlpha)
        for range in ranges {
            attributed.addAttribute(.foregroundColor, value: dimmed, range: NSRange(range, in: text))
        }
    }
}

/// Renders status text as an original-color image because macOS can ignore
/// `Text.foregroundStyle` inside a menu bar item.
enum StatusBarPercentageImageRenderer {
    @MainActor
    static func image(text: String, color: Color, colonVisible: Bool = true) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(color),
        ]
        let attributedText = NSMutableAttributedString(string: text, attributes: attributes)
        CountdownColonStyle.apply(colonVisible: colonVisible, to: attributedText, baseColor: color)
        let textSize = attributedText.size()
        let imageSize = NSSize(width: ceil(textSize.width), height: ceil(textSize.height))
        let image = NSImage(size: imageSize, flipped: false) { _ in
            attributedText.draw(at: .zero)
            return true
        }
        image.isTemplate = false

        return image
    }
}

/// Renders a dual-window label as two vertically stacked lines in one image,
/// so the label takes roughly half the menu bar width of the joined "A | B"
/// form. Sibling of `StatusBarPercentageImageRenderer`: same original-color
/// rationale (macOS can ignore `Text.foregroundStyle` in a menu bar item, and
/// each line must keep its own window's status color), but a smaller font so
/// both lines fit inside the menu bar's usable height.
///
/// The line size is user-selectable (`MenuBarStackedSize`): Small keeps the
/// original 9pt look, Medium and Large render 10pt and 11pt. At those larger
/// sizes the two natural line boxes no longer fit inside the 22pt clamp, so
/// the renderer verifies the two lines' measured glyph ink cannot collide and
/// switches anchoring strategies when it would (see `image(top:bottom:size:)`).
enum StatusBarStackedImageRenderer {
    /// The menu bar's usable content height. Status-item images taller than
    /// this get clipped or scaled by the system, so the stack never exceeds it.
    private static let maxHeight: CGFloat = 22

    /// Vertical breathing room between the two lines. When the two natural
    /// line heights plus this gap overflow `maxHeight`, the lines keep their
    /// top/bottom anchors and the overflow is absorbed by the gap and the
    /// fonts' descender space instead of clipping a line.
    private static let lineSpacing: CGFloat = 1

    /// Safety inset above the image's bottom edge when ink anchoring engages.
    /// AppKit's string drawing rounds baselines to pixel boundaries, which can
    /// land actual glyph pixels up to ~0.4pt below the analytic glyph-path
    /// bounds (measured), so pinning ink to exactly y = 0 could shave the
    /// bottom row off descenders.
    private static let bottomInkInset: CGFloat = 0.5

    @MainActor
    static func image(
        top: (text: String, color: Color),
        bottom: (text: String, color: Color),
        size: MenuBarStackedSize = .default,
        colonVisible: Bool = true
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size.stackedLinePointSize, weight: .semibold)
        // Each line carries its own countdown (or none), so each is styled
        // independently — but both share the phase, so the two colons pulse
        // together instead of drifting against each other.
        func attributedLine(_ line: (text: String, color: Color)) -> NSAttributedString {
            let attributed = NSMutableAttributedString(string: line.text, attributes: [
                .font: font,
                .foregroundColor: NSColor(line.color),
            ])
            CountdownColonStyle.apply(colonVisible: colonVisible, to: attributed, baseColor: line.color)
            return attributed
        }
        let topLine = attributedLine(top)
        let bottomLine = attributedLine(bottom)

        // Lines stay left-aligned: the image is as wide as the wider line and
        // both draw from x = 0, matching how the two windows read as a list.
        let width = ceil(max(topLine.size().width, bottomLine.size().width))
        let naturalHeight = topLine.size().height + lineSpacing + bottomLine.size().height
        let height = min(maxHeight, ceil(naturalHeight))

        // Default layout: line boxes anchored to the image edges, bottom line
        // at y = 0 and the top line's box against the top edge, with any clamp
        // deficit absorbed by the gap and the fonts' descender space. This is
        // the original Small rendering, byte-identical when no collision.
        var topOriginY = height - topLine.size().height
        var bottomOriginY: CGFloat = 0

        // Collision check: at 10pt a descender-bearing top line, and at 11pt
        // every realistic pairing, would let the glyphs themselves overlap
        // under box anchoring (measured -0.3 to -2.2pt of ink clearance).
        // When the measured glyph ink of the two lines would touch, switch to
        // INK anchoring: pin the bottom line's lowest ink just above y = 0 and
        // the top line's highest ink to the top edge. Line boxes may then
        // overflow the image, but a line box is mostly empty ascender and
        // descender allowance; reclaiming that padding restores over +3pt of
        // clearance at 11pt for realistic labels while nothing clips. Small
        // (9pt) always measures positive clearance here, so its rendering is
        // untouched. A line drawn at origin y has its baseline at
        // y + boxHeight - font.ascender, and ink bounds are baseline-relative.
        let topInk = inkBounds(of: topLine)
        let bottomInk = inkBounds(of: bottomLine)
        if !topInk.isNull, !bottomInk.isNull {
            let topInkBottom = topOriginY + topLine.size().height - font.ascender + topInk.minY
            let bottomInkTop = bottomOriginY + bottomLine.size().height - font.ascender + bottomInk.maxY
            if topInkBottom - bottomInkTop < 0 {
                bottomOriginY = bottomInkInset - (bottomLine.size().height - font.ascender) - bottomInk.minY
                topOriginY = height - (topLine.size().height - font.ascender) - topInk.maxY
            }
        }

        // flipped: false, so y grows upward: the bottom line sits at the
        // bottom and the top line is anchored to the image's top edge.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            bottomLine.draw(at: NSPoint(x: 0, y: bottomOriginY))
            topLine.draw(at: NSPoint(x: 0, y: topOriginY))
            return true
        }
        image.isTemplate = false

        return image
    }

    /// Tight glyph-path bounds of the line's ink, relative to its baseline
    /// origin (CoreText convention: y = 0 is the baseline, descenders are
    /// negative). Null for a line with no ink, e.g. all whitespace.
    private static func inkBounds(of line: NSAttributedString) -> CGRect {
        CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(line), [.useGlyphPathBounds])
    }
}

/// Renders the dual-window label as **two stacked horizontal progress bars** instead
/// of two stacked text lines. The bars give Ben a visual "scan in 2 seconds" cue for
/// "what I have for the session" vs "what I have for the week" without opening the
/// dropdown (Phase 7 — the `Ben en deux secondes` ask).
///
/// Constraints:
/// - Menu-bar item is 22pt tall (`StatusBarStackedImageRenderer.maxHeight`).
/// - Two 4pt bars + 1pt spacing = 9pt total, well under the cap.
/// - Bars are 60pt wide each, both left-aligned (matching the stacked text layout).
/// - Percent fill is rounded to integer pixels (no sub-pixel artifacts at 1x).
/// - Track + fill colors are theme-aware: track = `theme.progressTrack`, fill = the
///   per-window `statusColor` (the same color the stacked text would have used).
enum StatusBarDualBarImageRenderer {
    /// Width of each individual bar.
    private static let barWidth: CGFloat = 60
    /// Height of each individual bar.
    private static let barHeight: CGFloat = 4
    /// Vertical breathing room between the two bars.
    private static let barSpacing: CGFloat = 1

    @MainActor
    static func image(
        top: (percent: Double, color: Color),
        bottom: (percent: Double, color: Color),
        track: Color,
        emailSuffix: String? = nil,
        emailSuffixColor: Color = .secondary
    ) -> NSImage {
        let totalHeight = barHeight * 2 + barSpacing
        let baseWidth = barWidth

        // Pre-measure the email-suffix text to compute final image width.
        // Use a small font so the badge never overwhelms the bars visually.
        let suffixFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let suffixAttributes: [NSAttributedString.Key: Any] = [
            .font: suffixFont,
            .foregroundColor: NSColor(emailSuffixColor),
        ]
        let suffixAttributed = emailSuffix.map { NSAttributedString(string: $0, attributes: suffixAttributes) }
        let suffixSize = suffixAttributed?.size() ?? .zero
        let suffixSpacing: CGFloat = emailSuffix != nil ? 4 : 0
        let totalWidth = baseWidth + (suffixSize.width > 0 ? suffixSize.width + suffixSpacing : 0)
        let imageSize = NSSize(width: totalWidth, height: totalHeight)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            // Top bar — flipped: false so y grows upward; top bar sits at the top edge.
            drawBar(
                at: NSPoint(x: 0, y: barHeight + barSpacing),
                percent: top.percent,
                color: NSColor(top.color),
                track: NSColor(track)
            )
            // Bottom bar — at y = 0.
            drawBar(
                at: NSPoint(x: 0, y: 0),
                percent: bottom.percent,
                color: NSColor(bottom.color),
                track: NSColor(track)
            )
            // Email suffix badge — drawn after the bars, vertically centered
            // on the bar stack so it sits visually next to the bottom bar.
            if let suffixAttributed {
                let xOffset = baseWidth + suffixSpacing
                let yOffset = (totalHeight - suffixSize.height) / 2
                suffixAttributed.draw(at: NSPoint(x: xOffset, y: yOffset))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws a single rounded-rect track + a rounded-rect fill clipped to the
    /// remaining percent. The corner radius matches half the bar height so the
    /// ends render as proper pills rather than squared-off boxes.
    private static func drawBar(at origin: NSPoint, percent: Double, color: NSColor, track: NSColor) {
        let trackRect = NSRect(
            x: origin.x,
            y: origin.y,
            width: barWidth,
            height: barHeight
        )
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        track.setFill()
        trackPath.fill()

        let fillWidth = fillWidth(for: percent)
        guard fillWidth > 0 else { return }
        let fillRect = NSRect(
            x: origin.x,
            y: origin.y,
            width: fillWidth,
            height: barHeight
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        color.setFill()
        fillPath.fill()
    }

    /// Pixel-stable fill policy. Exactly 0% draws no fill; positive values get
    /// one rounded-cap minimum so tiny non-zero quota remains visible.
    static func fillWidth(for percent: Double) -> CGFloat {
        let clamped = min(max(percent, 0), 100) / 100
        guard clamped > 0 else { return 0 }
        return max(barHeight, ceil(CGFloat(clamped) * barWidth))
    }
}

extension MenuBarStackedSize {
    /// The point size each stacked line renders at. This mapping lives in the
    /// App layer (not Domain) because it is a rendering concern: Domain models
    /// the user's choice, the renderer decides what it means in points. The
    /// values are capped at 11pt because two lines of measured glyph ink must
    /// still fit inside the menu bar's 22pt content height (see
    /// `StatusBarStackedImageRenderer`).
    var stackedLinePointSize: CGFloat {
        switch self {
        case .small: 9
        case .medium: 10
        case .large: 11
        }
    }

    /// SF Symbol for the settings choice chip. Every chip in the menu bar
    /// section carries a leading icon, so the size options do too.
    var choiceIconName: String {
        switch self {
        case .small: "textformat.size.smaller"
        case .medium: "textformat.size"
        case .large: "textformat.size.larger"
        }
    }
}
