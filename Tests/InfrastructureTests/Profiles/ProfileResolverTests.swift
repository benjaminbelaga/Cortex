import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

/// Pins the resolver's on-disk understanding: it finds the flat `~/.claude-<x>`,
/// the nested `~/.claude-accounts/<x>` (the format enrolment writes), the default
/// profile and explicit user paths; de-dupes by realpath; and rejects a slug
/// collision.
@Suite("ProfileResolver")
struct ProfileResolverTests {

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeMarker(_ dir: URL, _ name: String = ".claude.json") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("Finds flat, nested, default and user-path Claude profiles")
    func findsAllClaudeShapes() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try "{}".write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try writeMarker(home.appendingPathComponent(".claude-work"))
        try writeMarker(home.appendingPathComponent(".claude-accounts/studio"))
        let userPath = home.appendingPathComponent("custom/.claude-extra")
        try writeMarker(userPath)

        let resolver = ProfileResolver()
        let found = resolver.candidateProfiles(
            forProvider: "claude", homeDirectory: home.path, userPaths: [userPath.path]
        )
        let paths = Set(found.compactMap { $0.profile.localPath.map { ($0 as NSString).lastPathComponent } })
        // Default profile is the home dir itself.
        #expect(found.contains { $0.profile.localPath == home.resolvingSymlinksInPath().path
            || $0.profile.localPath == home.path })
        #expect(paths.contains(".claude-work"))
        #expect(paths.contains("studio"))
        #expect(paths.contains(".claude-extra"))
    }

    @Test("The `.claude-accounts` directory itself is not a candidate")
    func nestedRootNotACandidate() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeMarker(home.appendingPathComponent(".claude-accounts/one"))

        let found = ProfileResolver().candidateProfiles(
            forProvider: "claude", homeDirectory: home.path, userPaths: []
        )
        #expect(found.allSatisfy { ($0.profile.localPath ?? "").hasSuffix("/one") })
    }

    @Test("Symlinked duplicates collapse to one canonical candidate")
    func realpathDedup() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent(".claude-real")
        try writeMarker(real)
        let link = home.appendingPathComponent(".claude-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let found = ProfileResolver().candidateProfiles(
            forProvider: "claude", homeDirectory: home.path, userPaths: []
        )
        let canon = Set(found.map(\.canonicalPath))
        #expect(canon.count == found.count) // no duplicate canonical paths
        #expect(found.count == 1)
    }

    @Test("Codex profiles are found via auth.json or config.toml")
    func findsCodexShapes() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeMarker(home.appendingPathComponent(".codex"), "auth.json")
        try writeMarker(home.appendingPathComponent(".codex-accounts/a"), "config.toml")

        let found = ProfileResolver().candidateProfiles(
            forProvider: "codex", homeDirectory: home.path, userPaths: []
        )
        #expect(found.count == 2)
        #expect(found.allSatisfy {
            if case .codexHome = $0.profile { return true } else { return false }
        })
    }

    @Test("proposePath collides on an unowned dir, succeeds when owned")
    func proposePathCollision() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = ProfileResolver()
        let existing = home.appendingPathComponent(".claude-accounts/studio")
        try writeMarker(existing)

        let collision = resolver.proposePath(
            forProvider: "claude", label: "Studio", homeDirectory: home.path, ownedPaths: []
        )
        #expect(collision == .failure(.profileCollision(path: existing.path)))

        let owned = resolver.proposePath(
            forProvider: "claude", label: "Studio", homeDirectory: home.path, ownedPaths: [existing.path]
        )
        #expect(owned == .success(.claudeConfigDir(existing.path)))

        let fresh = resolver.proposePath(
            forProvider: "claude", label: "Brand New", homeDirectory: home.path, ownedPaths: []
        )
        #expect(fresh == .success(.claudeConfigDir(
            home.appendingPathComponent(".claude-accounts/brand-new").path
        )))
    }
}
