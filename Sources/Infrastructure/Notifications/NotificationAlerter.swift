import Foundation
import Domain
import Mockable

// MARK: - Internal Protocol (for testability)

/// Internal protocol for sending system alerts. Enables testing without UNUserNotificationCenter.
@Mockable
protocol AlertSender: Sendable {
    func requestPermission() async -> Bool
    func send(title: String, body: String, categoryIdentifier: String) async throws
}

// MARK: - NotificationAlerter

/// Alerts users when their AI quota status degrades.
/// Sends system notifications for warning, critical, and depleted states.
public final class NotificationAlerter: QuotaAlerter, @unchecked Sendable {

    private let alertSender: AlertSender

    /// Public initializer - uses system alerts
    public init() {
        self.alertSender = SystemAlertSender()
    }

    /// Internal initializer for testing
    init(alertSender: AlertSender) {
        self.alertSender = alertSender
    }

    // MARK: - Public API

    /// Requests permission to send quota alerts.
    public func requestPermission() async -> Bool {
        AppLog.notifications.debug("Requesting alert permission...")
        let granted = await alertSender.requestPermission()
        AppLog.notifications.info("Alert permission: \(granted ? "granted" : "denied")")
        return granted
    }

    // MARK: - QuotaAlerter

    public func alert(providerId: String, previousStatus: QuotaStatus, currentStatus: QuotaStatus) async {
        AppLog.notifications.debug("Status change: \(providerId) \(previousStatus) -> \(currentStatus)")

        // Only alert on degradation (getting worse)
        guard currentStatus > previousStatus else {
            AppLog.notifications.debug("Status improved or same, skipping alert")
            return
        }

        guard shouldAlert(for: currentStatus) else {
            AppLog.notifications.debug("Status \(currentStatus) does not require alert")
            return
        }

        let providerName = providerDisplayName(for: providerId)
        let title = "\(providerName) Quota Alert"
        let body = alertBody(for: currentStatus, providerName: providerName)

        AppLog.notifications.notice("Sending quota alert for \(providerId): \(currentStatus)")

        do {
            try await alertSender.send(title: title, body: body, categoryIdentifier: "QUOTA_ALERT")
            AppLog.notifications.info("Alert sent successfully")
        } catch {
            AppLog.notifications.error("Failed to send alert: \(error.localizedDescription)")
        }
    }

    // MARK: - Time-tariff transitions (bible §15 hour rule)

    /// Alerts only on a real transition INTO the cheaper `discount` window, or
    /// back out of it — the two moments Ben can act on. The first observation
    /// (`previous == nil`) is recorded, never announced.
    public func alertTimeState(providerId: String, previous: String?, current: RouterTimeState) async {
        guard let previous, previous != current.state else { return }
        guard current.state == "discount" || previous == "discount" else { return }

        let providerName = providerDisplayName(for: providerId)
        let title: String
        let body: String
        if current.state == "discount" {
            title = "Off-peak · \(providerName)"
            body = "Reduced rate \(String(format: "×%.2g", current.multiplier)) active — calls cost less now."
        } else {
            title = "Peak · \(providerName)"
            var text = "Off-peak has ended."
            if let slot = current.nextBetterSlot {
                text += " Next better slot at \(slot.formatted(date: .omitted, time: .shortened))."
            }
            body = text
        }

        AppLog.notifications.notice("Time state \(previous) -> \(current.state) for \(providerId)")
        do {
            try await alertSender.send(title: title, body: body, categoryIdentifier: "TIME_STATE_ALERT")
        } catch {
            AppLog.notifications.error("Failed to send time-state alert: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers (internal for testability)

    func shouldAlert(for status: QuotaStatus) -> Bool {
        switch status {
        case .warning, .critical, .depleted:
            return true
        case .healthy:
            return false
        }
    }

    func providerDisplayName(for providerId: String) -> String {
        switch providerId {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "copilot": return "GitHub Copilot"
        case "antigravity": return "Antigravity"
        case "zai": return "Z.ai"
        case "bedrock": return "AWS Bedrock"
        case "minimax": return "MiniMax"
        case "alibaba": return "Alibaba Token Plan"
        case "qwen": return "Alibaba Token Plan"
        case "opencode-go": return "OpenCode Go"
        case "omp": return "Oh My Pi"
        case "grok": return "Grok"
        case "commandcode": return "Command Code"
        case "ollama": return "Ollama Cloud"
        default: return providerId.capitalized
        }
    }

    func alertBody(for status: QuotaStatus, providerName: String) -> String {
        switch status {
        case .warning:
            return "Your \(providerName) quota is running low. Consider pacing your usage."
        case .critical:
            return "Your \(providerName) quota is critically low! Save important work."
        case .depleted:
            return "Your \(providerName) quota is depleted. Usage may be blocked."
        case .healthy:
            return "Your \(providerName) quota has recovered."
        }
    }
}
