import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("Claude account discovery")
struct ClaudeAccountDiscoveryTests {
    @Test("keeps only authenticated candidates")
    func keepsOnlyAuthenticatedCandidates() async throws {
        let fixture = try Fixture(directories: [".claude-admin", ".claude-invalid"])
        defer { fixture.cleanup() }
        let validator = StubAccountValidator(accounts: [
            fixture.path(".claude-admin"): ClaudeAuthenticatedAccount(loggedIn: true, email: "admin@example.com"),
        ])

        let result = try await ClaudeAccountDiscovery(validator: validator).discover(
            homeDirectory: fixture.root.path,
            existing: []
        )

        #expect(result.map(\.accountId) == ["admin"])
        #expect(result.first?.email == "admin@example.com")
        #expect(result.first?.probeConfig["claudeConfigDir"] == fixture.path(".claude-admin"))
    }

    @Test("deduplicates normalized account IDs")
    func deduplicatesNormalizedAccountIds() async throws {
        let fixture = try Fixture(directories: [".claude-personal", ".claude-Personal"])
        defer { fixture.cleanup() }
        let validator = StubAccountValidator(accounts: [
            fixture.path(".claude-personal"): ClaudeAuthenticatedAccount(loggedIn: true, email: "first@example.com"),
            fixture.path(".claude-Personal"): ClaudeAuthenticatedAccount(loggedIn: true, email: "second@example.com"),
        ])

        let result = try await ClaudeAccountDiscovery(validator: validator).discover(
            homeDirectory: fixture.root.path,
            existing: []
        )

        #expect(result.count == 1)
        #expect(result[0].accountId == "personal")
        #expect(result[0].email == "first@example.com")
    }

    @Test("preserves existing settings without probing filesystem candidates")
    func preservesExistingSettingsWithoutProbing() async throws {
        let fixture = try Fixture(directories: [".claude-admin"])
        defer { fixture.cleanup() }
        let validator = StubAccountValidator(accounts: [
            fixture.path(".claude-admin"): ClaudeAuthenticatedAccount(loggedIn: true, email: "new@example.com"),
        ])
        let existing = [
            ProviderAccountConfig(accountId: "bedrock", label: "Bedrock", email: "kept@example.com"),
        ]

        let result = try await ClaudeAccountDiscovery(validator: validator).discover(
            homeDirectory: fixture.root.path,
            existing: existing
        )

        #expect(result == existing)
        #expect(validator.calls == [])
    }
}

private final class StubAccountValidator: ClaudeAccountStatusValidating, @unchecked Sendable {
    let accounts: [String: ClaudeAuthenticatedAccount]
    private(set) var calls: [String] = []

    init(accounts: [String: ClaudeAuthenticatedAccount]) {
        self.accounts = accounts
    }

    func authenticatedAccount(configDirectory: String) async -> ClaudeAuthenticatedAccount? {
        calls.append(configDirectory)
        return accounts[configDirectory]
    }
}

private struct Fixture {
    let root: URL

    init(directories: [String]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBarDiscoveryTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in directories {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url.appendingPathComponent(".claude.json"))
        }
    }

    func path(_ component: String) -> String {
        root.appendingPathComponent(component).path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
