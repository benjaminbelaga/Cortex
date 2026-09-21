import Foundation

/// Constants for hook configuration
public enum HookConstants {
    /// Default port for the hook HTTP server
    public static let defaultPort: UInt16 = 19847
    /// Default port for the Claude status-line observer (D2).
    /// Distinct from `defaultPort` so a kill-switch on status-line
    /// collection never disturbs the hook session-tracking server.
    public static let defaultStatusLinePort: UInt16 = 19848
}

/// Settings repository for hook configuration.
/// Standalone protocol (not extending ProviderSettingsRepository) since hooks aren't a provider.
public protocol HookSettingsRepository: Sendable {
    /// Whether hooks are enabled
    func isHookEnabled() -> Bool

    /// Sets whether hooks are enabled
    func setHookEnabled(_ enabled: Bool)

    /// The port number for the hook HTTP server (0 = auto-assign)
    func hookPort() -> Int

    /// Sets the port number for the hook HTTP server
    func setHookPort(_ port: Int)
}
