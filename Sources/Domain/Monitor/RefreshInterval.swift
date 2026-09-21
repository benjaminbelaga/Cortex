import Foundation

/// The user-facing cadence for refreshing the menu-bar number in the background.
///
/// "Off" means no background refresh — the bar updates only when the dropdown
/// opens (today's behaviour). The other cases map onto a 60 / 120 / 300 / 600 /
/// 900-second poll. There is intentionally no sub-minute option: 1 minute is a
/// hard floor to keep energy use low (issue #67). Cortex defaults to 2 minutes:
/// usage remains glanceably current while the existing sleep/battery controls
/// and shared router cache keep the poll cheap.
public enum RefreshInterval: String, Sendable, Equatable, CaseIterable {
    case off
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes

    /// The poll interval in seconds, or `nil` when refresh is off.
    public var seconds: Int? {
        switch self {
        case .off: nil
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .tenMinutes: 600
        case .fifteenMinutes: 900
        }
    }

    /// Whether background refresh runs for this option.
    public var isEnabled: Bool { self != .off }

    /// Short label for the settings picker.
    public var label: String {
        switch self {
        case .off: "Off"
        case .oneMinute: "1 min"
        case .twoMinutes: "2 min"
        case .fiveMinutes: "5 min"
        case .tenMinutes: "10 min"
        case .fifteenMinutes: "15 min"
        }
    }

    /// Derives the option from the legacy settings pair (`backgroundSyncEnabled`
    /// + `backgroundSyncInterval`), keeping `settings.json` backward compatible.
    ///
    /// Disabled → `.off`. Otherwise the stored seconds snap to the nearest
    /// supported option and never below the 1-minute floor, so retired values
    /// migrate cleanly: 30 → 1 min, 120 → 2 min, 300 → 5 min.
    public static func migrating(enabled: Bool, storedSeconds: TimeInterval) -> RefreshInterval {
        guard enabled else { return .off }
        let options: [RefreshInterval] = [.oneMinute, .twoMinutes, .fiveMinutes, .tenMinutes, .fifteenMinutes]
        return options.min { lhs, rhs in
            abs(Double(lhs.seconds ?? 0) - storedSeconds) < abs(Double(rhs.seconds ?? 0) - storedSeconds)
        } ?? .oneMinute
    }
}
