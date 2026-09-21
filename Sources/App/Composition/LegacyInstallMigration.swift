import Foundation
import Domain
import Infrastructure

/// Non-destructive migration of optional router and terminal settings discovered locally.
/// Account aliases belong to persisted user settings and are never inferred from labels.
public struct LegacyInstallMigration: Sendable {

    // MARK: - Site-specific row bindings (E1)

    /// One-shot: remember the `local` row's router id when the on-disk
    /// snapshot actually serves it. Capability detection (a local-shaped id is
    /// present in the cache), never identity: the site-specific suffix is
    /// never hardcoded here, and the key stays absent (row skipped) everywhere
    /// else. Writes only on positive detection, so a router installed later is
    /// picked up on a later launch; an explicit value is never overwritten.
    public static func seedLocalRouterIdIfNeeded(
        settingsRepository: JSONSettingsRepository,
        snapshotCacheURL: URL? = nil,
        readFile: (String) -> Data? = { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) {
        guard settingsRepository.localRouterProviderId() == nil else { return }
        guard let id = detectLocalRouterId(
            snapshotCacheURL: snapshotCacheURL, readFile: readFile
        ) else { return }
        settingsRepository.setLocalRouterProviderId(id)
        AppLog.providers.info("Remembered local router id \"\(id)\" from snapshot cache")
    }

    /// Scans the router snapshot cache (`providers` dict) for the id serving
    /// the `local` row. Returns nil when the cache is absent/unparseable or no
    /// local-shaped id is served — the caller then leaves the setting absent.
    static func detectLocalRouterId(
        snapshotCacheURL: URL?,
        readFile: (String) -> Data?
    ) -> String? {
        let url = snapshotCacheURL ?? defaultSnapshotCacheURL()
        guard let data = readFile(url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["providers"] as? [String: Any]
        else { return nil }
        return providers.keys.sorted().first(where: isLocalRowId)
    }

    /// A local row's router id: exactly `local`, or a `local`-prefixed variant
    /// (`local_hetzner`, `local-…`). Shape only — the suffix belongs to the
    /// machine, never to the code (E1).
    private static func isLocalRowId(_ id: String) -> Bool {
        id == "local" || id.hasPrefix("local_") || id.hasPrefix("local-")
    }

    private static func defaultSnapshotCacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudebar/router-snapshot-v2.json")
    }

    /// One-shot: remember extra tmux sockets that actually respond, so fresh
    /// installs probe only the default socket while legacy machines keep
    /// theirs. Probes while no sockets are stored; writes only on positive
    /// detection. Note: a manually-emptied list is re-probed while a socket
    /// responds (absence and explicit-empty are intentionally not
    /// distinguished — the count is advisory, never authoritative).
    public static func seedTmuxSocketsIfNeeded(
        settingsRepository: JSONSettingsRepository,
        candidates: [String] = [],
        socketResponds: (String) -> Bool = { name in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "tmux -L \(name) ls 2>/dev/null"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    ) {
        guard settingsRepository.tmuxSocketNames().isEmpty else { return }
        let live = candidates.filter(socketResponds)
        guard !live.isEmpty else { return }
        settingsRepository.setTmuxSocketNames(live)
        AppLog.providers.info("Remembered tmux sockets: \(live.joined(separator: ", "))")
    }
}
