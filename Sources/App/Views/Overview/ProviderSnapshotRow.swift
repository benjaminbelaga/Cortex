import SwiftUI
import AppKit
import Domain

/// One dashboard row: a provider (or one account of a multi-account provider)
/// rendered as a SINGLE thin line — `[icon] [name] [5h bar] [7d bar]` — with
/// the Session 5h and Weekly 7d windows shown SIDE BY SIDE, not stacked
/// (Ben 2026-08-23, R8, supersedes R2's vertical layout). The multi-account
/// email moves to the row tooltip so the line stays ~⅓ of the old height.
/// Never mixes absolute dates — resets are relative only (kept in the tooltip).
struct ProviderSnapshotRow: View {
    let snapshot: ProviderSnapshot
    let filter: OverviewWindowFilter
    /// Collapsible group header: nil = plain row, else the expanded state.
    var disclosure: Bool? = nil
    /// Header summary replacing the account tag ("2/3 dispo · 1 à reconnecter").
    var groupSummary: String? = nil
    /// Actionable tail of the header summary ("· 1 to reconnect"), rendered in
    /// the accent colour so a collapsed group advertises its guided reconnect.
    var groupSummaryAccent: String? = nil
    /// Number of accounts in a multi-account group, set only on the group
    /// header. Combined with an expanded `disclosure` it turns the header into
    /// a pure group label ("N comptes") instead of an account's quota bars — so
    /// the expanded member list never renders the representative a second time
    /// (the phantom "abonnement en plus", Ben 2026-09-24).
    var groupCount: Int? = nil
    /// Preferred model families, shown as mini-logos left of the name.
    var preferredModels: [ModelFamily] = []
    /// Toggles one preferred family for this row (nil hides the menu).
    var onTogglePreferred: ((ModelFamily) -> Void)? = nil
    /// Families offered by the picker, resolved live from the router catalog
    /// (falls back to the static set). New families need no Cortex release.
    var offeredFamilies: [ModelFamily] = ModelFamily.allCases

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AccountCatalogModel.self) private var catalog

    @State private var isConnecting = false
    @State private var connectResult: String?
    @State private var didCopyKey = false
    @State private var showPreferredPopover = false

    /// Session (5h) window for this provider, if any.
    private var sessionWindow: WindowSnapshot? {
        snapshot.windows.first { $0.scope == .session }
    }

    /// Weekly (7d) window for this provider, if any. Editions without a week
    /// (Ollama / Qwen monthly, 2026-09) show their monthly window here instead
    /// of a blank bar — labelled by its own title, never as "7 j".
    private var weeklyWindow: WindowSnapshot? {
        snapshot.windows.first { $0.scope == .weekly }
            ?? snapshot.windows.first { $0.scope == .other && !$0.isDollarBased && !$0.title.lowercased().contains("fable") }
    }

    /// Fable weekly window — a SEPARATE pool from the main hebdo ("combien de
    /// fables il me reste", the old Cortex feature Ben wants back 2026-08-24).
    private var fableWindow: WindowSnapshot? {
        snapshot.windows.first { $0.title.lowercased().contains("fable") }
    }

    /// Local models are always available but speed-bound, never quota-bound —
    /// a 5h/7d bar would lie (Ben 2026-08-24: violet, different indicator).
    private var isLocalProvider: Bool {
        snapshot.resourceKind == "unmetered_speed_bound"
    }

    private var isMeteredAPI: Bool { snapshot.resourceKind == "metered_api" }
    private var isCreditPool: Bool { snapshot.resourceKind == "credit_pool" }

    /// True only for an EXPANDED multi-account header: it renders as a group
    /// label ("N comptes") rather than as one account's row.
    private var isExpandedGroupHeader: Bool { disclosure == true && groupCount != nil }

    /// Inline account discriminator (Ben 2026-09-22): the opaque catalogue label
    /// ("compte 2") gains a masked identity so he knows WHICH account a row
    /// stands for before switching. Full email stays in the tooltip; the mask
    /// keeps the line compact and screenshot-safe.
    private var accountTag: String? {
        if let groupSummary { return groupSummary }
        let identity = IdentityMasking.mask(snapshot.accountEmail)
        switch (snapshot.accountLabel, identity) {
        case let (label?, identity?): return "\(label) · \(identity)"
        case let (label?, nil): return label
        case let (nil, identity?): return identity
        case (nil, nil): return nil
        }
    }

    private var localAccent: Color { .purple }

    /// A row whose credentials are broken gets a real "Connecter" button.
    /// Driven by the typed `AccountAuthState` threaded from the provider —
    /// never by searching the error message for a French sentence, and never
    /// with a fabricated default alias.
    private var reconnectable: Bool {
        snapshot.needsReconnect
    }

    /// The provider icon + preferred-model logos. When a toggle handler exists,
    /// clicking it opens the preferred-families picker (a `Button` consumes the
    /// tap so it never reaches the row's resets-detail `onTapGesture`).
    @ViewBuilder
    private var iconZone: some View {
        let logos = HStack(spacing: 6) {
            ProviderIconView(providerId: snapshot.providerId, size: 16, showGlow: true)
            if !preferredModels.isEmpty {
                ModelFamilyBadges(families: preferredModels)
            }
        }
        if onTogglePreferred != nil {
            Button { showPreferredPopover.toggle() } label: { logos }
                .buttonStyle(.plain)
                .help("Choose preferred models")
                .popover(isPresented: $showPreferredPopover, arrowEdge: .bottom) {
                    preferredModelsPicker
                }
        } else {
            logos
        }
    }

    /// Multi-select grid of model families (logo + name + check), each toggle
    /// routed to the same `onTogglePreferred` as the context menu.
    private var preferredModelsPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Preferred models")
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.bottom, 4)
            ForEach(offeredFamilies) { family in
                let selected = preferredModels.contains(family)
                Button {
                    onTogglePreferred?(family)
                } label: {
                    HStack(spacing: 8) {
                        ModelFamilyLogo(family: family, size: 16)
                        Text(family.displayName)
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 16)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(theme.font(size: 12))
                            .foregroundStyle(selected ? theme.accentPrimary : theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 200)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let disclosure {
                Image(systemName: disclosure ? "chevron.down" : "chevron.right")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 10)
            }
            iconZone

            // Name (+ compact account tag so two Claude rows stay unambiguous,
            // R3) in a fixed column so every row's bars line up vertically.
            // Narrowed 96→76pt to reclaim the blank gap between short names
            // and the first bar (Ben 2026-08-24 "espace vide entre le logo et
            // le créneau").
            HStack(spacing: 4) {
                Text(snapshot.providerName)
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if didCopyKey {
                    Text("key copied")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.statusHealthy)
                        .lineLimit(1)
                } else if !isExpandedGroupHeader, let tag = accountTag {
                    Text(tag)
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let accent = groupSummaryAccent {
                        Text(accent)
                            .font(theme.font(size: 9, weight: .semibold))
                            .foregroundStyle(theme.accentPrimary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 132, alignment: .leading)

            // State: syncing / error / the two inline bars / no-data.
            // Honest states (Ben 2026-09-22): a FAILED row (error, no surviving
            // windows) must never be masked by a refresh in flight — "Syncing…"
            // was hiding reconnect/errors on every popover open.
            if isExpandedGroupHeader {
                groupCountChip
                Spacer(minLength: 0)
            } else if let error = snapshot.errorMessage, snapshot.windows.isEmpty {
                errorContent(RouterErrorClass.label(snapshot.errorClass) ?? error)
            } else if snapshot.isSyncing {
                Text("Syncing…")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            } else if isLocalProvider {
                localContent
            } else if isMeteredAPI || isCreditPool {
                apiContent
            } else if !snapshot.windows.isEmpty {
                WindowBarView(
                    window: sessionWindow,
                    scopeLabel: scopeLabel(for: sessionWindow, fallback: "Session"),
                    isPrimary: filter == .session || filter == .all
                )
                WindowBarView(
                    window: weeklyWindow,
                    scopeLabel: scopeLabel(for: weeklyWindow, fallback: "Week"),
                    isPrimary: filter == .weekly || filter == .all
                )
                if let error = snapshot.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow).help("Last reading kept · " + error)
                }
                if let fable = fableWindow {
                    fableChip(fable)
                }
                if let forecast = snapshot.forecast,
                   forecast.projectedExhaustionAt != nil || forecast.severity == "waste_risk" {
                    forecastChip(forecast)
                }
            } else {
                Text("No data yet")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 30)
        .background(
            // Catchy card language (Ben 2026-09-23): the popover rows adopt the
            // shared SettingsCard gradient instead of the flat glass fill. An
            // expanded group header is deliberately NOT a card — it is a label,
            // so it can't be mistaken for an extra account (Ben 2026-09-24).
            RoundedRectangle(cornerRadius: 8)
                .fill(isExpandedGroupHeader ? AnyShapeStyle(Color.clear) : AnyShapeStyle(theme.cardGradient))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isExpandedGroupHeader
                        ? AnyShapeStyle(theme.glassBorder.opacity(0.35))
                        : AnyShapeStyle(theme.glassBorder),
                    lineWidth: 1
                )
        )
        .help(tooltip)
        .contextMenu {
            if ProviderCatalog.addableAccountIDs.contains(snapshot.providerId) {
                Button("Add account") { catalog.present(providerId: snapshot.providerId) }
            }
            if canCopyAccountKey {
                Button("Copy API key") { copyAccountKey() }
            }
            if let onTogglePreferred {
                Menu("Preferred models") {
                    ForEach(offeredFamilies) { family in
                        Toggle(family.displayName, isOn: Binding(
                            get: { preferredModels.contains(family) },
                            set: { _ in onTogglePreferred(family) }
                        ))
                    }
                }
            }
        }
    }

    /// Neutral label for an expanded multi-account header — never an account's
    /// quota, so the group reads as a container, not as a phantom seat.
    private var groupCountChip: some View {
        Text("\(groupCount ?? 0) comptes")
            .font(theme.font(size: 10, weight: .medium))
            .foregroundStyle(theme.textTertiary)
    }

    /// The account behind this row (`providerId|accountId`).
    private var accountId: String {
        snapshot.id.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
    }

    /// Metadata check only — the key is read on click, never while rendering.
    private var canCopyAccountKey: Bool {
        catalog.canCopyAPIKey(providerId: snapshot.providerId, accountId: accountId)
    }

    private func copyAccountKey() {
        guard let key = catalog.apiKey(providerId: snapshot.providerId, accountId: accountId) else { return }
        SecretClipboard.copy(key)
        didCopyKey = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopyKey = false
        }
    }

    // MARK: - Local provider content (violet, speed-bound — never quota bars)

    private var localContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "infinity")
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(localAccent)
            Text("available · speed-capped")
                .font(theme.font(size: 10, weight: .medium))
                .foregroundStyle(localAccent)
            Spacer(minLength: 0)
            Text("local")
                .font(theme.font(size: 8, weight: .semibold))
                .foregroundStyle(localAccent.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(localAccent.opacity(0.14)))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(localAccent.opacity(0.35), lineWidth: 1)
        )
    }

    private func scopeLabel(for window: WindowSnapshot?, fallback: String) -> String {
        guard let window else { return fallback }
        let title = window.title.lowercased()
        if title.contains("5h") || title.contains("300") { return "5 h" }
        if title.contains("7d") || title.contains("hebdo") || title.contains("10080") { return "7 j" }
        return window.scope == .session ? "Session" : (window.scope == .weekly ? "Week" : window.title)
    }

    // MARK: - API / credit resources (never fake 5h or 7d windows)

    private var apiContent: some View {
        let accent: Color = isCreditPool ? .orange : .cyan
        let title = isCreditPool ? "API · AWS credits" : "API · pay-as-you-go"
        let detail: String = {
            if isCreditPool, snapshot.expiryState == "conflict" {
                return "balance/expiry to confirm"
            }
            switch snapshot.credentialState {
            case "rotation_required": return "key to renew"
            case "configured": return snapshot.resourceState == "available" ? "available" : "state to confirm"
            default: return snapshot.resourceState == "blocked" ? "blocked" : "unknown state"
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: isCreditPool ? "creditcard.fill" : "network")
                .font(theme.font(size: 9, weight: .semibold))
            Text(title)
                .font(theme.font(size: 9, weight: .semibold))
            Spacer(minLength: 2)
            Text(detail)
                .font(theme.font(size: 8, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(accent)
        .help(apiTooltip)
    }

    private var apiTooltip: String {
        var parts = [snapshot.billingMode, "credential=\(snapshot.credentialState)", "resource=\(snapshot.resourceState)"]
        if snapshot.expiryState != "unknown" { parts.append("expiry=\(snapshot.expiryState)") }
        parts.append(contentsOf: snapshot.expiryCandidates)
        return parts.joined(separator: " · ")
    }

    // MARK: - Fable chip (separate weekly pool surfaced on Claude rows)

    private func fableChip(_ window: WindowSnapshot) -> some View {
        HStack(spacing: 2) {
            Text("F")
                .font(theme.font(size: 8, weight: .bold))
            Text("\(Int(window.percentRemaining.rounded()))%")
                .font(theme.font(size: 9, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(theme.statusColor(for: QuotaStatus.from(percentRemaining: window.percentRemaining)))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.glassBackground))
        .help("Fable weekly — separate pool from weekly" + (window.compactReset.map { " · reset \($0)" } ?? ""))
    }

    // MARK: - Forecast (history-backed, never shown while calibrating)

    private func forecastChip(_ forecast: RouterQuotaForecast) -> some View {
        let color: Color = switch forecast.severity {
        case "red": theme.statusCritical
        case "orange", "yellow": theme.statusWarning
        case "waste_risk": .purple
        default: theme.textTertiary
        }
        let label: String = {
            if forecast.severity == "waste_risk" { return "to use" }
            guard let exhaustion = forecast.projectedExhaustionAt else { return "Forecast" }
            return "estimated ~" + exhaustion.formatted(date: .omitted, time: .shortened)
        }()
        return HStack(spacing: 2) {
            Image(systemName: "clock.arrow.circlepath")
                .font(theme.font(size: 7, weight: .semibold))
            Text(label)
                .font(theme.font(size: 8, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .help(forecastTooltip(forecast))
    }

    private func forecastTooltip(_ forecast: RouterQuotaForecast) -> String {
        var parts = ["Forecast · confidence \(forecast.confidence)", "\(forecast.sampleCount) intervals"]
        if let burn = forecast.burnRatePercentPerHour {
            parts.append(String(format: "%.2f %%/h", burn))
        }
        if let remaining = forecast.projectedRemainingAtResetPercent {
            parts.append(String(format: "%.1f%% projected at reset", remaining))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tooltip (carries the email + reset detail the thin line can't)

    /// Hover text: `email — Provider · account · 5h resets in …`. Preserves R3
    /// (multi-account disambiguation) and the reset info removed from the line.
    private var tooltip: String {
        var parts: [String] = []
        if let email = snapshot.accountEmail { parts.append(email) }
        var head = snapshot.providerName
        if let account = snapshot.accountLabel { head += " · \(account)" }
        parts.append(head)
        if let reset = sessionWindow?.compactReset { parts.append("5h resets \(reset)") }
        if let reset = weeklyWindow?.compactReset { parts.append("7d resets \(reset)") }
        // When a typed error_class replaced the line label, keep the raw router
        // message reachable here — the detail view never loses the original text.
        if snapshot.errorClass != nil, let raw = snapshot.errorMessage { parts.append(raw) }
        if let forecast = snapshot.forecast {
            if let exhaustion = forecast.projectedExhaustionAt {
                parts.append("estimated exhaustion " + exhaustion.formatted(date: .omitted, time: .shortened))
            } else if forecast.confidence == "calibrating" {
                parts.append("forecast calibrating")
            }
        }
        return parts.joined(separator: " — ")
    }

    // MARK: - Inline error / connect (compact, single line)

    /// The error branch: warning + message, plus a real "Connecter" button for
    /// a disconnected Claude account. `connectResult` overrides the message
    /// after a button press so the outcome shows in place.
    @ViewBuilder
    private func errorContent(_ message: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(size: 9))
                .foregroundStyle(theme.statusWarning)
            Text(connectResult ?? message)
                .font(theme.font(size: 10, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if reconnectable {
                connectButton
            }
        }
    }

    /// Guided reconnect through the typed enrolment state machine — the row
    /// surfaces the typed outcome (identity re-verified, registry rejection,
    /// timeout…) instead of assuming success from a launched terminal.
    private var connectButton: some View {
        Button {
            guard !isConnecting else { return }
            isConnecting = true
            connectResult = nil
            Task { @MainActor in
                // The alias identifies the router seat; when the row has no
                // account label (single-account provider) the provider id is
                // the honest discriminator — never a hardcoded default.
                let alias = snapshot.accountLabel ?? snapshot.providerId.uppercased()
                let stream = catalog.reconnect(
                    providerId: snapshot.providerId,
                    alias: snapshot.id.split(separator: "|", maxSplits: 1).last.map(String.init) ?? alias
                )
                for await state in stream {
                    switch state {
                    case .identityConfirmed:
                        connectResult = "Reconnected — identity verified"
                    case .quotaPending, .quotaReceived:
                        connectResult = "Connected · quotas pending"
                    case .failed(_, let error):
                        connectResult = CatalogStrings.detail(for: error) ?? CatalogStrings.title(for: error)
                    case .cancelled:
                        connectResult = "Cancelled — nothing was saved"
                    default:
                        continue
                    }
                }
                isConnecting = false
            }
        } label: {
            HStack(spacing: 3) {
                if isConnecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "link")
                        .font(theme.font(size: 9, weight: .semibold))
                }
                Text(isConnecting ? "…" : "Connecter")
                    .font(theme.font(size: 10, weight: .semibold))
            }
            .foregroundStyle(theme.accentPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(theme.accentPrimary.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .help("Guided reconnect: isolated login (dedicated profile, other sessions are never touched), identity re-read and verified, then registration. A failure is shown typed, never as a success.")
    }
}

/// One compact horizontal quota bar: `[scope] [bar] [value]`, all on one line.
/// Two of these sit side by side in a provider row (5h + 7d). When `window` is
/// nil, renders a muted stub so bar widths stay consistent across providers.
/// `isPrimary` drives the 0.5 opacity that anchors the active window filter
/// without hiding the comparison window (R2 treatment, preserved under R8).
struct WindowBarView: View {
    let window: WindowSnapshot?
    let scopeLabel: String
    let isPrimary: Bool

    @Environment(\.appTheme) private var theme

    /// A stale reading (old manual sync, errored provider) is shown muted with
    /// an "stale" tag instead of a scary 0% (Ben 2026-08-24).
    private var isStale: Bool { window?.isStale ?? false }

    /// Show the reset countdown inline once a window runs low (or is stale) —
    /// this is Ben's "savoir quand ça se remplit" for a depleted Qwen. Healthy
    /// windows stay clean.
    private var resetHint: String? {
        guard let window, let reset = window.compactReset else { return nil }
        guard isStale || window.percentRemaining < 25 else { return nil }
        return reset
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(scopeLabel)
                .font(theme.font(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .fixedSize()

            // Track fills the flexible width; the fill overlays it. Using the
            // track as the sizing element (not a bare GeometryReader) avoids
            // GeometryReader collapsing to zero width inside an HStack.
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.progressTrack)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        if let window, !window.isDollarBased {
                            let clamped = min(max(window.percentRemaining, 0), 100)
                            if clamped > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isStale
                                        ? AnyShapeStyle(theme.textTertiary.opacity(0.3))
                                        : AnyShapeStyle(theme.progressGradient(for: window.percentRemaining)))
                                    .frame(width: max(3, geo.size.width * clamped / 100))
                            }
                        } else if window == nil {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.textTertiary.opacity(0.3))
                                .frame(width: max(3, geo.size.width * 0.02))
                        }
                    }
                }

            valueText
                .frame(minWidth: 30, alignment: .trailing)

            if let resetHint {
                Text(resetHint)
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .opacity(isPrimary ? 1.0 : 0.5)
    }

    /// The remaining %, or dollar figure for $-based providers, "stale" for
    /// a stale reading, or a dash.
    @ViewBuilder
    private var valueText: some View {
        if let window {
            if isStale {
                Text("stale")
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            } else if window.percentRemaining <= 1 {
                // U2 2026-08-24: a truly empty window must read as EXHAUSTED
                // with its refill date (shown by resetHint), never as a bare
                // "0%" — "93% session / 0% semaine" looked like a bug while
                // the two pools are simply independent.
                Text("exhausted")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.statusColor(for: .depleted))
            } else if window.isDollarBased, let dollars = window.formattedDollarRemaining {
                Text(dollars)
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.statusColor(for: QuotaStatus.from(percentRemaining: window.percentRemaining)))
                    .monospacedDigit()
            } else {
                Text("\(Int(window.percentRemaining.rounded()))%")
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.statusColor(for: QuotaStatus.from(percentRemaining: window.percentRemaining)))
                    .monospacedDigit()
            }
        } else {
            Text("—")
                .font(theme.font(size: 10, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
    }
}


/// Up to three overlapping 12pt model logos (+N), left of the row name.
struct ModelFamilyBadges: View {
    let families: [ModelFamily]
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: -3) {
            ForEach(families.prefix(3)) { family in
                ModelFamilyLogo(family: family, size: 12)
            }
            if families.count > 3 {
                Text("+\(families.count - 3)")
                    .font(theme.font(size: 8, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 4)
            }
        }
        .help("Preferred models: " + families.map(\.displayName).joined(separator: ", "))
    }
}

/// A family logo: bundled brand image when one exists, else a lettered disc.
struct ModelFamilyLogo: View {
    let family: ModelFamily
    var size: CGFloat = 12

    private var assetName: String? {
        switch family {
        case .deepseek: "DeepSeekIcon"
        case .qwen: "QwenIcon"
        case .glm: "ZaiIcon"
        case .kimi: "KimiIcon"
        case .minimax: "MiniMaxIcon"
        case .claude: "ClaudeIcon"
        case .gpt: "CodexIcon"
        case .mimo: nil
        }
    }

    var body: some View {
        Group {
            if let assetName, let image = NSImage(named: assetName) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Text(String(family.displayName.prefix(2)))
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.orange))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}
