import Foundation
import Domain

/// Filesystem implementation of `ProfileResolving`. Knows the on-disk shapes for
/// Claude (`CLAUDE_CONFIG_DIR`) and Codex (`CODEX_HOME`): the default location,
/// the flat `~/.<tool>-<x>` dirs, and the nested `~/.<tool>-accounts/<x>` dirs
/// the `+` enrolment writes. It only reads directory listings and markers; it
/// never runs the CLI or touches a credential.
public struct ProfileResolver: ProfileResolving {
    public init() {}

    private var fileManager: FileManager { .default }

    private struct Shape {
        let flatPrefix: String        // ".claude-"
        let nestedDir: String         // ".claude-accounts"
        let defaultDir: String?       // ".claude" default home, or nil
        let markers: [String]         // files that prove the dir is a profile
        let makeProfile: (String) -> ProfileReference
    }

    private func shape(for providerId: String) -> Shape? {
        switch providerId {
        case "claude":
            return Shape(
                flatPrefix: ".claude-",
                nestedDir: ".claude-accounts",
                defaultDir: nil, // the default Claude profile is $HOME + .claude.json, handled below
                markers: [".claude.json"],
                makeProfile: { .claudeConfigDir($0) }
            )
        case "codex":
            return Shape(
                flatPrefix: ".codex-",
                nestedDir: ".codex-accounts",
                defaultDir: ".codex",
                markers: ["auth.json", "config.toml"],
                makeProfile: { .codexHome($0) }
            )
        default:
            return nil
        }
    }

    public func candidateProfiles(
        forProvider providerId: String,
        homeDirectory: String,
        userPaths: [String]
    ) -> [DiscoveredProfile] {
        guard let shape = shape(for: providerId) else { return [] }
        let home = homeDirectory as NSString
        var found: [DiscoveredProfile] = []
        var seen = Set<String>()

        func consider(_ path: String) {
            let canonical = canonicalPath(path)
            guard seen.insert(canonical).inserted else { return }
            found.append(DiscoveredProfile(
                providerId: providerId,
                profile: shape.makeProfile(path),
                canonicalPath: canonical
            ))
        }

        // Default location.
        if providerId == "claude" {
            if fileManager.fileExists(atPath: home.appendingPathComponent(".claude.json")) {
                consider(homeDirectory)
            }
        } else if let def = shape.defaultDir,
                  hasMarker(dir: home.appendingPathComponent(def), markers: shape.markers) {
            consider(home.appendingPathComponent(def))
        }

        // Flat `~/.<tool>-<x>` and nested `~/.<tool>-accounts/<x>`.
        let entries = (try? fileManager.contentsOfDirectory(atPath: homeDirectory))?.sorted() ?? []
        for item in entries where item.hasPrefix(shape.flatPrefix) && item != shape.nestedDir {
            let dir = home.appendingPathComponent(item)
            if hasMarker(dir: dir, markers: shape.markers) { consider(dir) }
        }
        let nestedRoot = home.appendingPathComponent(shape.nestedDir)
        let nested = (try? fileManager.contentsOfDirectory(atPath: nestedRoot))?.sorted() ?? []
        for item in nested {
            let dir = (nestedRoot as NSString).appendingPathComponent(item)
            if hasMarker(dir: dir, markers: shape.markers) { consider(dir) }
        }

        // Explicit user paths.
        for path in userPaths where hasMarker(dir: path, markers: shape.markers) {
            consider(path)
        }

        return found
    }

    public func proposePath(
        forProvider providerId: String,
        label: String,
        homeDirectory: String,
        ownedPaths: [String]
    ) -> Result<ProfileReference, ProfileResolutionError> {
        guard let shape = shape(for: providerId) else {
            return .failure(.unsupportedProvider(providerId))
        }
        let slug = Self.slug(label)
        let root = (homeDirectory as NSString).appendingPathComponent(shape.nestedDir)
        let path = (root as NSString).appendingPathComponent(slug)
        let owned = Set(ownedPaths.map(canonicalPath))
        if fileManager.fileExists(atPath: path), !owned.contains(canonicalPath(path)) {
            return .failure(.profileCollision(path: path))
        }
        return .success(shape.makeProfile(path))
    }

    // MARK: - Helpers

    private func hasMarker(dir: String, markers: [String]) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return markers.contains { marker in
            fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(marker))
        }
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Lowercased, `-`-separated slug; non-alphanumerics collapse to a single
    /// separator. Matches `AccountConnectRunner`'s slugging so an enrolled
    /// directory is later re-found.
    static func slug(_ label: String) -> String {
        let mapped = label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return joined.isEmpty ? "account" : joined
    }
}
