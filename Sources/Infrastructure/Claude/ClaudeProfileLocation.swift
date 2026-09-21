import Foundation
import CryptoKit

/// Claude's default profile has no environment override; custom profiles use a scoped Keychain item.
public enum ClaudeProfileLocation {
    public static func customDirectory(_ path: String?, home: String = NSHomeDirectory()) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let defaultDirectory = URL(fileURLWithPath: home).appendingPathComponent(".claude").path
        // Older Cortex stored the HOME parent for the default profile.
        return expanded == home || expanded == defaultDirectory ? nil : expanded
    }

    public static func keychainService(directory: String?, home: String = NSHomeDirectory()) -> String {
        let base = "Claude Code-credentials"
        guard let directory = customDirectory(directory, home: home) else { return base }
        let digest = SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
        return base + "-" + digest.prefix(8)
    }
}
