import SwiftUI
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

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AccountCatalogModel.self) private var catalog

    @State private var isConnecting = false
    @State private var connectResult: String?

    /// Session (5h) window for this provider, if any.
    private var sessionWindow: WindowSnapshot? {
        snapshot.windows.first { $0.scope == .session }
    }

    /// Weekly (7d) window for this provider, if any.
    private var weeklyWindow: WindowSnapshot? {
        snapshot.windows.first { $0.scope == .weekly }
    }

    /// Fable weekly window — a SEPARATE pool from the main hebdo ("combien de
    /// fables il me reste", the old ClaudeBar feature Ben wants back 2026-08-24).
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

    private var localAccent: Color { .purple }

    /// A row whose credentials are broken gets a real "Connecter" button.
    /// Driven by the typed `AccountAuthState` threaded from the provider —
    /// never by searching the error message for a French sentence, and never
    /// with a fabricated default alias.
    private var reconnectable: Bool {
        snapshot.needsReconnect
    }

    var body: some View {
        HStack(spacing: 6) {
            ProviderIconView(providerId: snapshot.providerId, size: 16, showGlow: false)

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
                if let account = snapshot.accountLabel {
                    Text(account)
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: 112, alignment: .leading)

            // State: syncing / error / the two inline bars / no-data.
            if snapshot.isSyncing {
                Text("Syncing…")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            } else if isLocalProvider {
                localContent
            } else if isMeteredAPI || isCreditPool {
                apiContent
            } else if let error = snapshot.errorMessage, snapshot.windows.isEmpty {
                errorContent(error)
            } else if !snapshot.windows.isEmpty {
                WindowBarView(
                    window: sessionWindow,
                    scopeLabel: scopeLabel(for: sessionWindow, fallback: "Session"),
                    isPrimary: filter == .session || filter == .all
                )
                WindowBarView(
                    window: weeklyWindow,
                    scopeLabel: scopeLabel(for: weeklyWindow, fallback: "Semaine"),
                    isPrimary: filter == .weekly || filter == .all
                )
                if let error = snapshot.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow).help("Dernier relevé conservé · " + error)
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
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.glassBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.glassBorder, lineWidth: 1)
        )
        .help(tooltip)
        .contextMenu {
            if ["claude", "codex", "opencode-go", "commandcode"].contains(snapshot.providerId) {
                Button("Ajouter un compte") { catalog.present(providerId: snapshot.providerId) }
            }
        }
    }

    // MARK: - Local provider content (violet, speed-bound — never quota bars)

    private var localContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "infinity")
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(localAccent)
            Text("dispo · vitesse-borné")
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
        return window.scope == .session ? "Session" : (window.scope == .weekly ? "Semaine" : window.title)
    }

    // MARK: - API / credit resources (never fake 5h or 7d windows)

    private var apiContent: some View {
        let accent: Color = isCreditPool ? .orange : .cyan
        let title = isCreditPool ? "API · crédits AWS" : "API · facturé à l’usage"
        let detail: String = {
            if isCreditPool, snapshot.expiryState == "conflict" {
                return "solde/expiration à confirmer"
            }
            switch snapshot.credentialState {
            case "rotation_required": return "clé à renouveler"
            case "configured": return snapshot.resourceState == "available" ? "disponible" : "état à confirmer"
            default: return snapshot.resourceState == "blocked" ? "bloqué" : "état inconnu"
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
        .help("Fable hebdo — pool séparé de l'hebdo" + (window.compactReset.map { " · reset \($0)" } ?? ""))
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
            if forecast.severity == "waste_risk" { return "à utiliser" }
            guard let exhaustion = forecast.projectedExhaustionAt else { return "Prévision" }
            return "estimé ~" + exhaustion.formatted(date: .omitted, time: .shortened)
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
        var parts = ["Prévision · confiance \(forecast.confidence)", "\(forecast.sampleCount) intervalles"]
        if let burn = forecast.burnRatePercentPerHour {
            parts.append(String(format: "%.2f %%/h", burn))
        }
        if let remaining = forecast.projectedRemainingAtResetPercent {
            parts.append(String(format: "%.1f %% prévu au reset", remaining))
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
        if let forecast = snapshot.forecast {
            if let exhaustion = forecast.projectedExhaustionAt {
                parts.append("épuisement estimé " + exhaustion.formatted(date: .omitted, time: .shortened))
            } else if forecast.confidence == "calibrating" {
                parts.append("prévision en calibrage")
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
                        connectResult = "Reconnecté — identité vérifiée"
                    case .quotaPending, .quotaReceived:
                        connectResult = "Connecté · quotas en attente"
                    case .failed(_, let error):
                        connectResult = CatalogStrings.title(for: error)
                    case .cancelled:
                        connectResult = "Annulé — rien n'a été enregistré"
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
        .help("Reconnexion guidée : login isolé (profil dédié, les autres sessions ne sont jamais touchées), identité relue et vérifiée, puis enregistrement. Un échec s'affiche typé, jamais comme un succès.")
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
    /// an "obsolète" tag instead of a scary 0% (Ben 2026-08-24).
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

    /// The remaining %, or dollar figure for $-based providers, "obsolète" for
    /// a stale reading, or a dash.
    @ViewBuilder
    private var valueText: some View {
        if let window {
            if isStale {
                Text("obsolète")
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            } else if window.percentRemaining <= 1 {
                // U2 2026-08-24: a truly empty window must read as EXHAUSTED
                // with its refill date (shown by resetHint), never as a bare
                // "0%" — "93% session / 0% semaine" looked like a bug while
                // the two pools are simply independent.
                Text("épuisé")
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
