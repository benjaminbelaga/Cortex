import Foundation

/// Reads the active iTerm2 profile colors directly from macOS preferences.
///
/// Uses `UserDefaults(suiteName: "com.googlecode.iterm2")` to access iTerm2's stored profiles
/// without requiring a file export. The active profile is identified via `Default Bookmark Guid`.
///
/// This provides a one-click "sync from terminal" experience.
public struct ITermProfileReader {

    /// Error cases when reading iTerm2 preferences.
    public enum ReadError: Error, Equatable {
        /// iTerm2 preferences not found (app not installed or never launched).
        case notInstalled
        /// No profiles found in iTerm2 preferences.
        case noProfiles
        /// The default profile GUID does not match any stored profile.
        case profileNotFound
        /// Required colors are missing from the profile.
        case missingColors(String)
    }

    /// Whether iTerm2 is installed (preferences exist).
    public static var isAvailable: Bool {
        UserDefaults(suiteName: "com.googlecode.iterm2") != nil
    }

    /// Read the active iTerm2 profile and return a ``TerminalColorScheme``.
    ///
    /// Reads the default profile identified by `Default Bookmark Guid`, extracts all 16 ANSI colors
    /// plus background, foreground, and optional UI colors.
    /// - Returns: A ``TerminalColorScheme`` with the profile's colors.
    /// - Throws: ``ReadError`` if iTerm2 is not installed or the profile cannot be read.
    public static func readActiveProfile() throws -> TerminalColorScheme {
        guard let defaults = UserDefaults(suiteName: "com.googlecode.iterm2") else {
            throw ReadError.notInstalled
        }

        guard let bookmarks = defaults.array(forKey: "New Bookmarks") as? [[String: Any]],
              !bookmarks.isEmpty else {
            throw ReadError.noProfiles
        }

        // Find the active profile by GUID, or fall back to the first profile
        let defaultGuid = defaults.string(forKey: "Default Bookmark Guid")
        let profile: [String: Any]
        if let guid = defaultGuid,
           let match = bookmarks.first(where: { ($0["Guid"] as? String) == guid }) {
            profile = match
        } else {
            profile = bookmarks[0]
        }

        let profileName = (profile["Name"] as? String) ?? "iTerm2"
        return try extractScheme(from: profile, name: profileName)
    }

    // MARK: - Private

    private static func extractScheme(from profile: [String: Any], name: String) throws -> TerminalColorScheme {
        let background = try extractColor(from: profile, key: "Background Color")
        let foreground = try extractColor(from: profile, key: "Foreground Color")
        let boldText = try? extractColor(from: profile, key: "Bold Color")
        let cursor = try? extractColor(from: profile, key: "Cursor Color")
        let selection = try? extractColor(from: profile, key: "Selection Color")
        let selectionText = try? extractColor(from: profile, key: "Selected Text Color")

        var ansiColors: [TerminalColorScheme.RGBColor] = []
        for i in 0..<16 {
            let color = try extractColor(from: profile, key: "Ansi \(i) Color")
            ansiColors.append(color)
        }

        return TerminalColorScheme(
            name: name,
            background: background,
            foreground: foreground,
            boldText: boldText,
            cursor: cursor,
            selection: selection,
            selectionText: selectionText,
            ansiColors: ansiColors
        )
    }

    private static func extractColor(
        from profile: [String: Any],
        key: String
    ) throws -> TerminalColorScheme.RGBColor {
        guard let colorDict = profile[key] as? [String: Any] else {
            throw ReadError.missingColors(key)
        }
        let red = doubleValue(colorDict["Red Component"]) ?? 0.0
        let green = doubleValue(colorDict["Green Component"]) ?? 0.0
        let blue = doubleValue(colorDict["Blue Component"]) ?? 0.0
        let alpha = doubleValue(colorDict["Alpha Component"]) ?? 1.0
        return TerminalColorScheme.RGBColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Extract a Double from a value that may be stored as Double, NSNumber, or String.
    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
