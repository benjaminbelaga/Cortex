import SwiftUI
import Domain

/// Per-provider 7-day reset timeline (T8, Ben 2026-08-19).
///
/// Tap a row in the dashboard → sheet slides up showing every quota
/// window for that provider positioned on a 7-day strip. Tick marks
/// drop on the day the window resets; rows colour by remaining %.
/// Today is anchored at the left edge; the strip ends at start-of-day
/// +7 days. Windows with `resetsAt` outside the strip are clipped to
/// the boundary with an arrow + the actual date in the footer.
struct ResetsCalendarSheet: View {
    let snapshot: ProviderSnapshot
    /// When presented inline inside the menu-bar popover (the only reliable
    /// path — a SwiftUI `.sheet` never becomes visible from an NSPopover-backed
    /// MenuBarExtra and just greys the popover), the host passes a close
    /// closure. When nil we fall back to the environment `dismiss` (real window).
    var onClose: (() -> Void)? = nil
    /// Set for API-key providers (Ollama, OpenCode Go, Command Code): enrols
    /// the key on the pasteboard as another account — the two-click path
    /// (open provider → add) Ben asked for on 2026-09-25.
    var onAddAccountFromPasteboard: (() -> Void)? = nil
    /// Destructive removal of the shown provider (or account) from Cortex.
    /// Never touches the underlying tool/CLI profile — only Cortex's tracking.
    var onRemove: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showRemoveConfirm = false

    private let windowStart: Date = Calendar.current.startOfDay(for: Date())
    private let windowEnd: Date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(7 * 24 * 3600)

    /// Both ends of the failover chain show the same live panel: the Go pool
    /// (tier 1) and Ollama Cloud (tier 2) are one chain, seen from either row.
    static func showsFailoverChain(providerId: String) -> Bool {
        providerId == "opencode-go" || providerId == "ollama"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            dayLabels
            ForEach(snapshot.windows) { window in
                ResetsCalendarRow(
                    window: window,
                    windowStart: windowStart,
                    windowEnd: windowEnd,
                    theme: theme
                )
            }
            if Self.showsFailoverChain(providerId: snapshot.providerId) {
                FailoverChainCard()
            }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.glassBackground)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.providerName)
                .font(theme.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: 6) {
                if let label = snapshot.accountLabel {
                    Text(label)
                        .font(theme.font(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                if let email = snapshot.accountEmail {
                    Text(email)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textTertiary.opacity(0.85))
                        .truncationMode(.middle)
                }
            }
            Text("Resets over 7 days · \(snapshot.windows.count) window\(snapshot.windows.count > 1 ? "s" : "")")
                .font(theme.font(size: 10))
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: - Day labels

    private var dayLabels: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // The 7 day boundary markers.
                ForEach(0..<8, id: \.self) { i in
                    let x = geo.size.width * CGFloat(i) / 7
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    .stroke(theme.glassBorder, lineWidth: 0.5)
                    if i < 7 {
                        Text(dayLabel(for: i))
                            .font(theme.font(size: 9, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: geo.size.width / 7, alignment: .center)
                            .offset(x: geo.size.width * CGFloat(i) / 7, y: 0)
                    }
                }
                // "Aujourd'hui" left-edge marker.
                Rectangle()
                    .fill(theme.statusColor(for: .healthy))
                    .frame(width: 2)
            }
        }
        .frame(height: 16)
    }

    private func dayLabel(for offset: Int) -> String {
        let date = windowStart.addingTimeInterval(TimeInterval(offset) * 24 * 3600)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.string(from: date)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let onAddAccountFromPasteboard {
                Button {
                    onAddAccountFromPasteboard()
                } label: {
                    Label("Add account (key from clipboard)", systemImage: "plus.circle")
                }
            }
            Spacer()
            if let onRemove {
                Button(role: .destructive) {
                    showRemoveConfirm = true
                } label: {
                    Label("Remove from Cortex", systemImage: "trash")
                }
            }
            Button("Close") {
                if let onClose { onClose() } else { dismiss() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .confirmationDialog(
            "Remove this provider from Cortex?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { onRemove?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only Cortex's tracking is removed. Your tool profile and credentials stay intact.")
        }
    }
}

/// One window row: title + percent + a tick on the 7-day strip.
private struct ResetsCalendarRow: View {
    let window: WindowSnapshot
    let windowStart: Date
    let windowEnd: Date
    let theme: any AppThemeProvider

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(window.title)
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 32, alignment: .leading)
                Text("\(Int(window.percentRemaining.rounded()))%")
                    .font(theme.font(size: 11, weight: .bold))
                    .foregroundStyle(theme.statusColor(for: QuotaStatus.from(percentRemaining: window.percentRemaining)))
                Spacer()
                Text(resetLabel)
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(theme.progressTrack)
                        .frame(height: 6)
                    if let resetsAt = window.resetsAt {
                        let clamped = min(max(resetsAt, windowStart), windowEnd)
                        let progress = clamped.timeIntervalSince(windowStart) / (windowEnd.timeIntervalSince(windowStart))
                        let x = geo.size.width * CGFloat(progress)
                        Circle()
                            .fill(theme.statusColor(for: QuotaStatus.from(percentRemaining: window.percentRemaining)))
                            .frame(width: 10, height: 10)
                            .offset(x: x - 5, y: -2)
                    }
                }
            }
            .frame(height: 10)
        }
        .padding(.vertical, 2)
    }

    /// Human label for the reset moment (e.g. "Sam 16h", "in 3d 4h").
    private var resetLabel: String {
        guard let resetsAt = window.resetsAt else { return "·" }
        let formatter = DateFormatter()
        if resetsAt < windowEnd {
            // Inside the strip — show short relative label.
            let interval = resetsAt.timeIntervalSinceNow
            if interval < 0 {
                let formatter2 = DateFormatter()
                formatter2.dateFormat = "EEE HH:mm"
                formatter2.locale = Locale(identifier: "fr_FR")
                return formatter2.string(from: resetsAt)
            }
            let days = Int(interval / 86400)
            let hours = Int((interval.truncatingRemainder(dividingBy: 86400)) / 3600)
            if days > 0 {
                return "in \(days)j \(hours)h"
            } else if hours > 0 {
                let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
                return "in \(hours)h \(minutes)m"
            } else {
                let minutes = max(1, Int(interval / 60))
                return "in \(minutes)m"
            }
        } else {
            formatter.dateFormat = "EEE d HH:mm"
            formatter.locale = Locale(identifier: "fr_FR")
            return formatter.string(from: resetsAt)
        }
    }
}
