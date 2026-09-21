import Foundation

/// The mode used by CopilotProvider to fetch usage data.
/// Users can switch between Billing API (default) and Copilot Internal API in Settings.
public enum CopilotProbeMode: String, Sendable, Equatable, CaseIterable {
    /// Use the GitHub Billing API to fetch premium request usage.
    /// Requires fine-grained PAT with "Plan: read" permission.
    /// Works for individual plans but may return empty data for Business/Enterprise.
    case billing

    /// Use the Copilot Internal API (`/copilot_internal/user`) to fetch usage data.
    /// Requires Classic PAT with "copilot" scope.
    /// Works for all plan types including Business/Enterprise.
    case copilotAPI

    /// Human-readable display name for the mode
    public var displayName: String {
        switch self {
        case .billing:
            return "Billing"
        case .copilotAPI:
            return "Copilot API"
        }
    }

    /// Description of what this mode does
    public var description: String {
        switch self {
        case .billing:
            return "Uses GitHub Billing API"
        case .copilotAPI:
            return "Uses Copilot Internal API"
        }
    }
}
