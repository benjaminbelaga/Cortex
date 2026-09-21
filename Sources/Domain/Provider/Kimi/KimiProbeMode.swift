import Foundation

/// The mode used by KimiProvider to fetch usage data.
/// Users can switch between CLI (default) and API modes in Settings.
public enum KimiProbeMode: String, Sendable, Equatable, CaseIterable {
    /// Use the Kimi CLI (`kimi` with `/usage` command) to fetch usage data.
    /// This is the default mode and works via interactive CLI prompt.
    case cli

    /// Use the Kimi HTTP API to fetch usage data directly.
    /// Requires valid browser cookie authentication (kimi-auth).
    case api

    /// Human-readable display name for the mode
    public var displayName: String {
        switch self {
        case .cli:
            return "CLI"
        case .api:
            return "API"
        }
    }

    /// Description of what this mode does
    public var description: String {
        switch self {
        case .cli:
            return "Uses kimi /usage command"
        case .api:
            return "Calls Kimi API directly"
        }
    }
}
