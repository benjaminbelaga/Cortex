import Foundation
import Domain

/// Installs and uninstalls the `cortex-statusline.sh` shim that wraps
/// `~/.claude/settings.json`'s `statusLine.command`. Same idempotence
/// discipline as `HookInstaller`:
///
/// - The sentinel `~/.claudebar/statusline-original.json` remembers the
///   user's pre-shim command so `uninstall()` is byte-for-byte restore.
/// - A second `install()` call is a no-op when the sentinel + shim agree
///   with what's in settings.json. If the user edited `statusLine.command`
///   externally, the sentinel is preserved (the user is past the install
///   point).
/// - Gated: when the adapter setting is off, `install()` refuses to touch
///   settings.json. The UI toggle is what actually drives install/uninstall.
///
/// **Test seam**: the `paths` parameter lets callers (mainly tests) target a
/// sandbox directory. Production code uses `ClaudeStatusLineInstaller.Paths.default`
/// which reads from `NSHomeDirectory()`.
public enum ClaudeStatusLineInstaller {
    /// Marker embedded in the shim filename so `isInstalled()` can recognize
    /// our wrapper from the `statusLine.command` path alone.
    static let shimMarker = "cortex-statusline"

    public struct Paths: Equatable, Sendable {
        public let settingsPath: String
        public let binDirectory: String
        public let shimPath: String
        public let sentinelPath: String

        public init(
            settingsPath: String,
            binDirectory: String,
            shimPath: String,
            sentinelPath: String
        ) {
            self.settingsPath = settingsPath
            self.binDirectory = binDirectory
            self.shimPath = shimPath
            self.sentinelPath = sentinelPath
        }

        public static let `default`: Paths = {
            let home = NSHomeDirectory()
            return Paths(
                settingsPath: "\(home)/.claude/settings.json",
                binDirectory: "\(home)/.claudebar/bin",
                shimPath: "\(home)/.claudebar/bin/cortex-statusline.sh",
                sentinelPath: "\(home)/.claudebar/statusline-original.json"
            )
        }()
    }

    public enum InstallerError: Error, CustomStringConvertible, Equatable {
        case settingsCorrupted(String)
        case sentinelCorrupted(String)
        case adapterDisabled

        public var description: String {
            switch self {
            case .settingsCorrupted(let path):
                return "Failed to parse \(path) — file may be corrupted. Fix it manually before retrying."
            case .sentinelCorrupted(let path):
                return "Failed to parse \(path) — file may be corrupted. Fix it manually before retrying."
            case .adapterDisabled:
                return "Refusing to install: claude status-line adapter is disabled. Enable the setting first."
            }
        }
    }

    /// Installs the shim, wrapping the user's existing statusLine.command.
    ///
    /// Returns `true` when a fresh install was performed, `false` when the
    /// settings were already wrapped and nothing changed. Throws when the
    /// adapter is disabled, or when settings.json is corrupted.
    @discardableResult
    public static func install(
        enabled: Bool = true,
        paths: Paths = .default
    ) throws -> Bool {
        guard enabled else { throw InstallerError.adapterDisabled }
        var settings = try readOrCreateSettings(paths: paths)

        let existingCommand = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let sentinel: StoredSentinel? = readSentinel(paths: paths)

        // Idempotence: if settings already point to our shim AND the sentinel
        // exists, nothing to do. A user-edited original is preserved.
        if let existing = existingCommand, existing.contains(shimMarker), sentinel != nil {
            return false
        }

        // Capture the pre-shim command before mutating. If statusLine was
        // absent, we record nil so uninstall() knows to delete the block.
        let sentinelToWrite = StoredSentinel(
            originalCommand: existingCommand,
            installedAt: Date()
        )

        try writeShim(paths: paths)

        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        statusLine["command"] = paths.shimPath
        settings["statusLine"] = statusLine

        try writeSettings(settings, paths: paths)
        try writeSentinel(sentinelToWrite, paths: paths)
        return true
    }

    /// Restores the user's pre-shim command and removes the shim file.
    /// Idempotent: a second call is a no-op when the sentinel is gone.
    public static func uninstall(paths: Paths = .default) throws {
        let sentinel = readSentinel(paths: paths)
        if let settings = try? readOrCreateSettings(paths: paths) {
            var updated = settings
            if let original = sentinel?.originalCommand {
                var statusLine = updated["statusLine"] as? [String: Any] ?? [:]
                statusLine["command"] = original
                updated["statusLine"] = statusLine
            } else {
                updated.removeValue(forKey: "statusLine")
            }
            try writeSettings(updated, paths: paths)
        }
        try? FileManager.default.removeItem(atPath: paths.shimPath)
        try? FileManager.default.removeItem(atPath: paths.sentinelPath)
    }

    /// True when settings.json points to our shim AND the sentinel exists.
    /// The dual check guards against a stale sentinel without a live shim
    /// (uninstall left half-done) or a live shim without a sentinel
    /// (settings manually edited).
    public static func isInstalled(paths: Paths = .default) -> Bool {
        guard let settings = try? readOrCreateSettings(paths: paths),
              let command = (settings["statusLine"] as? [String: Any])?["command"] as? String,
              command.contains(shimMarker) else {
            return false
        }
        return FileManager.default.fileExists(atPath: paths.sentinelPath)
    }

    // MARK: - Private

    struct StoredSentinel: Codable, Equatable {
        let originalCommand: String?
        let installedAt: Date
    }

    static func readOrCreateSettings(paths: Paths) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: paths.settingsPath) else { return [:] }
        guard let data = FileManager.default.contents(atPath: paths.settingsPath),
              !data.isEmpty else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.settingsCorrupted(paths.settingsPath)
        }
        return json
    }

    static func writeSettings(_ settings: [String: Any], paths: Paths) throws {
        let directory = (paths.settingsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: paths.settingsPath), options: .atomic)
    }

    static func readSentinel(paths: Paths) -> StoredSentinel? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.sentinelPath)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredSentinel.self, from: data)
    }

    static func writeSentinel(_ sentinel: StoredSentinel, paths: Paths) throws {
        let directory = (paths.sentinelPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sentinel)
        try data.write(to: URL(fileURLWithPath: paths.sentinelPath), options: .atomic)
    }

    /// Writes the shim script. The script:
    /// 1. Captures stdin (the Claude statusline JSON payload).
    /// 2. Pipes stdin to the **original** statusLine command if one was
    ///    captured at install time (so the user's own renderer keeps
    ///    working unchanged).
    /// 3. POSTs the same JSON to the Cortex StatusLineObserver on localhost
    ///    (background, 1-second timeout, best-effort — a Cortex outage never
    ///    breaks the user's shell renderer).
    /// 4. Emits the original command's stdout unchanged so Claude displays
    ///    exactly what it would have before the wrap.
    static func writeShim(paths: Paths) throws {
        try FileManager.default.createDirectory(
            atPath: paths.binDirectory,
            withIntermediateDirectories: true
        )
        let script = """
        #!/bin/bash
        # cortex-statusline.sh — installed by ClaudeBar. Marker: \(shimMarker)
        # Relays Claude's statusline JSON to the user's original command AND
        # POSTs the same payload to the Cortex StatusLineObserver (localhost-only).
        # Best-effort: a Cortex outage never breaks the shell renderer.

        set -e

        PAYLOAD=$(cat)

        # Discover the Cortex observer port. Missing port file = Cortex not running;
        # the user's renderer still gets the original command's output.
        PORT_FILE="$HOME/.claude/cortex-statusline-port"
        CORTEX_PORT=$(cat "$PORT_FILE" 2>/dev/null || echo "")
        # The session's own config dir when Claude runs an isolated profile
        # (CLAUDE_CONFIG_DIR), else the default home. This keys the observation
        # per account so multi-profile setups don't collapse onto one row.
        CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

        # Read the saved original command (set by ClaudeStatusLineInstaller).
        SENTINEL="$HOME/.claudebar/statusline-original.json"
        ORIGINAL=$(jq -r '.originalCommand // empty' "$SENTINEL" 2>/dev/null || echo "")

        # 1. POST to the Cortex observer (best-effort, never blocks the renderer).
        if [ -n "$CORTEX_PORT" ]; then
            ENCODED=$(printf '%s' "$CONFIG_DIR" | jq -sRr @uri 2>/dev/null || echo "")
            (
                printf '%s' "$PAYLOAD" | curl -s -m 1 -X POST \\
                    "http://localhost:${CORTEX_PORT}/statusline?configDir=${ENCODED}" \\
                    -H 'Content-Type: application/json' \\
                    -d @- > /dev/null 2>&1
            ) &
        fi

        # 2. Forward stdin to the original command — its stdout is what Claude displays.
        if [ -n "$ORIGINAL" ]; then
            printf '%s' "$PAYLOAD" | bash -c "$ORIGINAL"
        else
            # No original — Claude will display the raw JSON. Honest fallback.
            printf '%s' "$PAYLOAD"
        fi
        """
        try script.write(toFile: paths.shimPath, atomically: true, encoding: .utf8)
        // Owner-only rwx on the bin directory and the shim file. Claude only
        // ever calls the script as the same user, so 0o700 is sufficient and
        // keeps the original command private (the sentinel lives next to it).
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: paths.binDirectory
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: paths.shimPath
        )
    }
}
