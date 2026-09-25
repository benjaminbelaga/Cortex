import Foundation

/// Maps llm-router's typed `error_class` values to human English strings for the
/// overview row. The raw error text stays available for the detail/tooltip —
/// this only replaces the terse line label. An unknown or absent class falls
/// back to the raw string (graceful), never a fabricated message.
public enum RouterErrorClass {
    /// The English label for a known error class, or nil when the class is
    /// unknown/absent (caller falls back to the raw error message).
    public static func label(_ errorClass: String?) -> String? {
        guard let errorClass, !errorClass.isEmpty else { return nil }
        switch errorClass {
        case "subscription_inactive": return "MiniMax subscription inactive"
        case "manual_quota_missing": return "Manual quota not synced"
        case "auth_expired": return "Alibaba console session expired"
        default: return nil
        }
    }
}
