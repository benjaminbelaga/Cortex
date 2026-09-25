import Foundation
import Mockable

/// Domain protocol for alerting users about quota changes.
/// Implementations decide how to alert (notifications, sounds, etc.).
@Mockable
public protocol QuotaAlerter: Sendable {
    /// Requests permission to send alerts to the user.
    /// Returns true if permission was granted.
    func requestPermission() async -> Bool

    /// Called when a provider's quota status changes.
    /// Implementations should alert users if the status degraded.
    func alert(providerId: String, previousStatus: QuotaStatus, currentStatus: QuotaStatus) async

    /// Called when a router-backed provider's time-tariff state changes
    /// (`normal` / `peak` / `discount`, bible §15 hour rule). `previous` is nil
    /// on the first observation, which implementations must not alert on.
    func alertTimeState(providerId: String, previous: String?, current: RouterTimeState) async
}
