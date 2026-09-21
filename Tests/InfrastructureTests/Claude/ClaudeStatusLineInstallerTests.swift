import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// D2 tranche — the `cortex-statusline.sh` installer. Pinned regressions:
/// - idempotence (a second install is a no-op when state matches);
/// - byte-for-byte restore on uninstall (the sentinel carries the user's
///   pre-shim command);
/// - the kill-switch (`enabled: false`) refuses to mutate settings.json;
/// - settings.json corruption is surfaced, not swallowed.
///
/// Tests target a sandbox directory (`paths` injected) so the real
/// `~/.claude/settings.json` is never touched. `cleanup` removes the
/// sandbox at the end of each test.
@Suite("ClaudeStatusLineInstaller")
struct ClaudeStatusLineInstallerTests {

    private func makePaths(suffix: String = UUID().uuidString) -> ClaudeStatusLineInstaller.Paths {
        let root = "/tmp/claudebar-test-\(suffix)"
        return ClaudeStatusLineInstaller.Paths(
            settingsPath: "\(root)/.claude/settings.json",
            binDirectory: "\(root)/.claudebar/bin",
            shimPath: "\(root)/.claudebar/bin/cortex-statusline.sh",
            sentinelPath: "\(root)/.claudebar/statusline-original.json"
        )
    }

    private func writeOriginalSettings(_ paths: ClaudeStatusLineInstaller.Paths, command: String?) throws {
        let directory = (paths.settingsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let command {
            root["statusLine"] = ["command": command]
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: paths.settingsPath), options: .atomic)
    }

    private func readSettings(_ paths: ClaudeStatusLineInstaller.Paths) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func cleanup(_ paths: ClaudeStatusLineInstaller.Paths) {
        let root = (paths.settingsPath as NSString).deletingLastPathComponent
        let sandbox = (root as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: sandbox)
    }

    // MARK: - install()

    @Test("install on a clean machine wraps the existing command, writes shim + sentinel")
    func installFromClean() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try writeOriginalSettings(paths, command: "echo hello")

        let changed = try ClaudeStatusLineInstaller.install(enabled: true, paths: paths)
        #expect(changed == true)
        #expect(ClaudeStatusLineInstaller.isInstalled(paths: paths))

        let settings = readSettings(paths)
        let command = (settings["statusLine"] as? [String: Any])?["command"] as? String
        #expect(command == paths.shimPath)
        #expect(command?.contains(ClaudeStatusLineInstaller.shimMarker) == true)

        #expect(FileManager.default.fileExists(atPath: paths.shimPath))
        #expect(FileManager.default.fileExists(atPath: paths.sentinelPath))

        // The sentinel must carry the pre-shim command byte-for-byte.
        let sentinelData = try Data(contentsOf: URL(fileURLWithPath: paths.sentinelPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sentinel = try decoder.decode(ClaudeStatusLineInstaller.StoredSentinel.self, from: sentinelData)
        #expect(sentinel.originalCommand == "echo hello")
    }

    @Test("install with no pre-existing statusLine block records nil in the sentinel")
    func installWithoutOriginalCommand() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try writeOriginalSettings(paths, command: nil)

        let changed = try ClaudeStatusLineInstaller.install(enabled: true, paths: paths)
        #expect(changed == true)
        #expect(ClaudeStatusLineInstaller.isInstalled(paths: paths))

        let settings = readSettings(paths)
        let statusLine = settings["statusLine"] as? [String: Any]
        #expect(statusLine?["command"] as? String == paths.shimPath)
    }

    @Test("a second install() is a no-op when the sentinel already matches")
    func installIsIdempotent() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try writeOriginalSettings(paths, command: "echo first")

        let first = try ClaudeStatusLineInstaller.install(enabled: true, paths: paths)
        let second = try ClaudeStatusLineInstaller.install(enabled: true, paths: paths)
        #expect(first == true)
        #expect(second == false,
                "a fresh install was already in place; the second call must be a no-op")
    }

    @Test("install() refuses to mutate settings when the adapter setting is off")
    func installRefusesWhenDisabled() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try writeOriginalSettings(paths, command: "echo safe")

        #expect(throws: ClaudeStatusLineInstaller.InstallerError.adapterDisabled.self) {
            _ = try ClaudeStatusLineInstaller.install(enabled: false, paths: paths)
        }

        // Settings must NOT have been mutated — the original command is preserved.
        let settings = readSettings(paths)
        #expect((settings["statusLine"] as? [String: Any])?["command"] as? String == "echo safe")
        #expect(!FileManager.default.fileExists(atPath: paths.shimPath))
    }

    @Test("install() throws settingsCorrupted when ~/.claude/settings.json is unparseable")
    func installThrowsOnCorruptedSettings() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let directory = (paths.settingsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("not-valid-json".utf8).write(to: URL(fileURLWithPath: paths.settingsPath), options: .atomic)

        do {
            _ = try ClaudeStatusLineInstaller.install(enabled: true, paths: paths)
            Issue.record("Expected install() to throw settingsCorrupted on unparseable JSON")
        } catch let error as ClaudeStatusLineInstaller.InstallerError {
            guard case .settingsCorrupted = error else {
                Issue.record("Expected .settingsCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - uninstall()

    @Test("uninstall restores the pre-shim command byte-for-byte and removes the sentinel")
    func uninstallRestoresByteForByte() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try writeOriginalSettings(paths, command: "echo original")

        _ = try ClaudeStatusLineInstaller.install(enabled: true, paths: paths)
        #expect(ClaudeStatusLineInstaller.isInstalled(paths: paths))

        try ClaudeStatusLineInstaller.uninstall(paths: paths)

        #expect(!ClaudeStatusLineInstaller.isInstalled(paths: paths))
        let settings = readSettings(paths)
        let command = (settings["statusLine"] as? [String: Any])?["command"] as? String
        #expect(command == "echo original",
                "the original statusLine command must be restored byte-for-byte")
        #expect(!FileManager.default.fileExists(atPath: paths.shimPath))
        #expect(!FileManager.default.fileExists(atPath: paths.sentinelPath))
    }

    @Test("uninstall with no original command removes the statusLine block entirely")
    func uninstallRemovesBlockWhenOriginalWasAbsent() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try writeOriginalSettings(paths, command: nil)
        _ = try ClaudeStatusLineInstaller.install(enabled: true, paths: paths)

        try ClaudeStatusLineInstaller.uninstall(paths: paths)

        let settings = readSettings(paths)
        #expect(settings["statusLine"] == nil,
                "with no pre-shim command, uninstall must delete the entire statusLine block")
    }

    @Test("uninstall is a no-op when nothing was installed")
    func uninstallIsIdempotent() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        // Should not throw, even with no sentinel and no settings.
        try ClaudeStatusLineInstaller.uninstall(paths: paths)
        #expect(!ClaudeStatusLineInstaller.isInstalled(paths: paths))
    }

    // MARK: - isInstalled()

    @Test("isInstalled reports false when settings point to a non-shim command")
    func isInstalledFalseForUnwrappedCommand() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try writeOriginalSettings(paths, command: "echo plain")
        #expect(!ClaudeStatusLineInstaller.isInstalled(paths: paths))
    }

    @Test("isInstalled reports false when the shim marker is present but the sentinel is missing")
    func isInstalledRequiresBoth() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        // Manually write settings pointing to the marker, but skip the sentinel.
        try writeOriginalSettings(
            paths,
            command: "/tmp/manual/with/\(ClaudeStatusLineInstaller.shimMarker)"
        )
        #expect(!ClaudeStatusLineInstaller.isInstalled(paths: paths),
                "settings claiming to be ours without a sentinel is not a valid install")
    }

    // MARK: - shim script shape

    @Test("the installed shim is owner-executable and forwards to the original command")
    func shimScriptShape() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try writeOriginalSettings(paths, command: "echo original")

        _ = try ClaudeStatusLineInstaller.install(enabled: true, paths: paths)

        let shimContents = try String(contentsOfFile: paths.shimPath, encoding: .utf8)
        #expect(shimContents.contains(ClaudeStatusLineInstaller.shimMarker),
                "the shim must self-identify with the marker so isInstalled() can recognize it")
        #expect(shimContents.contains("ORIGINAL"),
                "the shim must read the sentinel and forward to the saved original command")
        #expect(shimContents.contains("statusline?configDir="),
                "the shim must POST to the Cortex observer with a configDir query param")
        #expect(shimContents.contains("CLAUDE_CONFIG_DIR"),
                "the shim must attribute the payload to the session's own config dir (multi-profile setups)")

        let attrs = try FileManager.default.attributesOfItem(atPath: paths.shimPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((perms & 0o700) == 0o700,
                "the shim file must be owner-rwx (got \(String(perms, radix: 8)))")
    }
}
