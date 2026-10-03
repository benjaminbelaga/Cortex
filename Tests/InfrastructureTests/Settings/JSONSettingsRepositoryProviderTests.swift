import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

/// Tests for provider-level settings in JSONSettingsRepository.
@Suite("JSONSettingsRepository Provider Settings Tests")
struct JSONSettingsRepositoryProviderTests {

    private func makeRepository() -> (JSONSettingsRepository, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudebar-test-\(UUID().uuidString)")
        let fileURL = tempDir.appendingPathComponent("settings.json")
        let store = JSONSettingsStore(fileURL: fileURL)
        let repo = JSONSettingsRepository(store: store)
        return (repo, tempDir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Provider Enabled State

    @Test
    func `isEnabled defaults to true`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.isEnabled(forProvider: "claude") == true)
    }

    @Test
    func `isEnabled with custom default returns that default`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.isEnabled(forProvider: "copilot", defaultValue: false) == false)
    }

    @Test
    func `setEnabled persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setEnabled(false, forProvider: "claude")
        #expect(repo.isEnabled(forProvider: "claude") == false)
    }

    @Test
    func `providers have independent enabled state`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setEnabled(false, forProvider: "claude")
        repo.setEnabled(true, forProvider: "codex")

        #expect(repo.isEnabled(forProvider: "claude") == false)
        #expect(repo.isEnabled(forProvider: "codex") == true)
    }

    // MARK: - Custom Card URL

    @Test
    func `customCardURL defaults to nil`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.customCardURL(forProvider: "claude") == nil)
    }

    @Test
    func `setCustomCardURL persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setCustomCardURL("https://claude.owo.nz/", forProvider: "claude")
        #expect(repo.customCardURL(forProvider: "claude") == "https://claude.owo.nz/")
    }

    @Test
    func `setCustomCardURL nil removes value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setCustomCardURL("https://claude.owo.nz/", forProvider: "claude")
        repo.setCustomCardURL(nil, forProvider: "claude")
        #expect(repo.customCardURL(forProvider: "claude") == nil)
    }

    @Test
    func `setCustomCardURL empty string removes value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setCustomCardURL("https://claude.owo.nz/", forProvider: "claude")
        repo.setCustomCardURL("", forProvider: "claude")
        #expect(repo.customCardURL(forProvider: "claude") == nil)
    }

    @Test
    func `customCardURL is per provider`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setCustomCardURL("https://claude.owo.nz/", forProvider: "claude")
        repo.setCustomCardURL("https://codex.example.com/", forProvider: "codex")

        #expect(repo.customCardURL(forProvider: "claude") == "https://claude.owo.nz/")
        #expect(repo.customCardURL(forProvider: "codex") == "https://codex.example.com/")
        #expect(repo.customCardURL(forProvider: "gemini") == nil)
    }

    // MARK: - Claude Settings

    @Test
    func `claudeProbeMode defaults to cli`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.claudeProbeMode() == .cli)
    }

    @Test
    func `setClaudeProbeMode persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setClaudeProbeMode(.api)
        #expect(repo.claudeProbeMode() == .api)
    }

    @Test
    func `claudeCliFallbackEnabled defaults to true`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.claudeCliFallbackEnabled() == true)
    }

    @Test
    func `setClaudeCliFallbackEnabled persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setClaudeCliFallbackEnabled(false)
        #expect(repo.claudeCliFallbackEnabled() == false)
    }

    // MARK: - Codex Settings

    @Test
    func `codexProbeMode defaults to rpc`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.codexProbeMode() == .rpc)
    }

    @Test
    func `setCodexProbeMode persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setCodexProbeMode(.api)
        #expect(repo.codexProbeMode() == .api)
    }

    // MARK: - Kimi Settings

    @Test
    func `kimiProbeMode defaults to cli (upstream public default)`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.kimiProbeMode() == .cli)
    }

    @Test
    func `setKimiProbeMode persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setKimiProbeMode(.api)
        #expect(repo.kimiProbeMode() == .api)
    }

    // MARK: - Zai Settings

    @Test
    func `zaiConfigPath defaults to empty string`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.zaiConfigPath() == "")
    }

    @Test
    func `setZaiConfigPath persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setZaiConfigPath("/custom/path")
        #expect(repo.zaiConfigPath() == "/custom/path")
    }

    @Test
    func `glmAuthEnvVar defaults to empty string`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.glmAuthEnvVar() == "")
    }

    @Test
    func `setGlmAuthEnvVar persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setGlmAuthEnvVar("GLM_TOKEN")
        #expect(repo.glmAuthEnvVar() == "GLM_TOKEN")
    }

    // MARK: - Copilot Settings

    @Test
    func `copilotProbeMode defaults to billing`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.copilotProbeMode() == .billing)
    }

    @Test
    func `setCopilotProbeMode persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setCopilotProbeMode(.copilotAPI)
        #expect(repo.copilotProbeMode() == .copilotAPI)
    }

    @Test
    func `copilotAuthEnvVar defaults to empty string`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.copilotAuthEnvVar() == "")
    }

    @Test
    func `copilotMonthlyLimit defaults to nil`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.copilotMonthlyLimit() == nil)
    }

    @Test
    func `setCopilotMonthlyLimit persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setCopilotMonthlyLimit(100)
        #expect(repo.copilotMonthlyLimit() == 100)
    }

    // MARK: - Bedrock Settings

    @Test
    func `awsProfileName defaults to empty string`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.awsProfileName() == "")
    }

    @Test
    func `bedrockRegions defaults to us-east-1`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.bedrockRegions() == ["us-east-1"])
    }

    @Test
    func `setBedrockRegions persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setBedrockRegions(["us-west-2", "eu-west-1"])
        #expect(repo.bedrockRegions() == ["us-west-2", "eu-west-1"])
    }

    @Test
    func `bedrockDailyBudget defaults to nil`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.bedrockDailyBudget() == nil)
    }

    @Test
    func `setBedrockDailyBudget persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setBedrockDailyBudget(25.50)
        #expect(repo.bedrockDailyBudget() == 25.50)
    }

    // MARK: - Hook Settings

    @Test
    func `isHookEnabled defaults to false`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.isHookEnabled() == false)
    }

    @Test
    func `setHookEnabled persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setHookEnabled(true)
        #expect(repo.isHookEnabled() == true)
    }

    @Test
    func `hookPort defaults to 19847`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.hookPort() == HookConstants.defaultPort)
    }

    @Test
    func `setHookPort persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setHookPort(8080)
        #expect(repo.hookPort() == 8080)
    }

    // MARK: - MiniMax Settings

    @Test
    func `minimaxRegion defaults to china`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.minimaxRegion() == .china)
    }

    @Test
    func `setMinimaxRegion persists value`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.setMinimaxRegion(.international)
        #expect(repo.minimaxRegion() == .international)
    }

}

// MARK: - Credential Migration

/// The JSONSettingsRepository secrets now live in the injected credential store.
/// Legacy UserDefaults values are read-only: migrated on first read, removed only
/// after a verified secure write, and kept when the store refuses the write.
@Suite
struct JSONSettingsRepositoryCredentialMigrationTests {

    private struct Fixture {
        let repository: JSONSettingsRepository
        let dir: URL
        let suiteName: String
        let defaults: UserDefaults
        let credentials: InMemoryCredentialStore
    }

    private func makeFixture(refusesWrites: Bool = false) -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudebar-credential-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suiteName = "com.claudebar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let credentials = InMemoryCredentialStore(refusesWrites: refusesWrites)
        let repository = JSONSettingsRepository(
            store: JSONSettingsStore(fileURL: tempDir.appendingPathComponent("settings.json")),
            credentials: defaults,
            secureCredentials: credentials
        )
        return Fixture(repository: repository, dir: tempDir, suiteName: suiteName, defaults: defaults, credentials: credentials)
    }

    private func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.dir)
        UserDefaults(suiteName: fixture.suiteName)?.removePersistentDomain(forName: fixture.suiteName)
    }

    // MARK: - GitHub token

    /// (a) The token round-trips through the credential store and is not in UserDefaults.
    @Test
    func `GitHub token round-trips through the credential store, not UserDefaults`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.repository.saveGithubToken("ghp_secret")

        #expect(fixture.repository.getGithubToken() == "ghp_secret")
        #expect(fixture.repository.hasGithubToken() == true)
        #expect(fixture.credentials.get(forKey: CredentialKey.githubToken) == "ghp_secret")
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.github-copilot-token") == nil)
    }

    /// (b) A legacy UserDefaults token migrates on first read; the key is removed
    /// only after the verified secure write.
    @Test
    func `migrates a legacy GitHub token on first read and clears the legacy key`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }
        fixture.defaults.set("ghp_legacy", forKey: "com.claudebar.credentials.github-copilot-token")

        #expect(fixture.repository.getGithubToken() == "ghp_legacy")
        #expect(fixture.credentials.get(forKey: CredentialKey.githubToken) == "ghp_legacy")
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.github-copilot-token") == nil)
    }

    /// (c) When the store refuses the write, the legacy token is still returned and
    /// is never deleted.
    @Test
    func `keeps and returns a legacy GitHub token when the credential store refuses the write`() {
        let fixture = makeFixture(refusesWrites: true)
        defer { cleanup(fixture) }
        fixture.defaults.set("ghp_legacy", forKey: "com.claudebar.credentials.github-copilot-token")

        #expect(fixture.repository.getGithubToken() == "ghp_legacy")
        #expect(fixture.repository.getGithubToken() == "ghp_legacy")
        #expect(fixture.credentials.get(forKey: CredentialKey.githubToken) == nil)
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.github-copilot-token") == "ghp_legacy")
    }

    @Test
    func `deleting a GitHub token clears the credential store and the legacy key`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }
        fixture.repository.saveGithubToken("ghp_secret")
        fixture.defaults.set("ghp_legacy", forKey: "com.claudebar.credentials.github-copilot-token")

        fixture.repository.deleteGithubToken()

        #expect(fixture.repository.getGithubToken() == nil)
        #expect(fixture.credentials.get(forKey: CredentialKey.githubToken) == nil)
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.github-copilot-token") == nil)
    }

    // MARK: - MiniMax API key

    /// (a) The key round-trips through the credential store and is not in UserDefaults.
    @Test
    func `MiniMax key round-trips through the credential store, not UserDefaults`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.repository.saveMinimaxApiKey("mm_secret")

        #expect(fixture.repository.getMinimaxApiKey() == "mm_secret")
        #expect(fixture.repository.hasMinimaxApiKey() == true)
        #expect(fixture.credentials.get(forKey: CredentialKey.minimaxApiKey) == "mm_secret")
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.minimax-api-key") == nil)
    }

    /// (b) A legacy UserDefaults key migrates on first read; the key is removed only
    /// after the verified secure write.
    @Test
    func `migrates a legacy MiniMax key on first read and clears the legacy key`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }
        fixture.defaults.set("mm_legacy", forKey: "com.claudebar.credentials.minimax-api-key")

        #expect(fixture.repository.getMinimaxApiKey() == "mm_legacy")
        #expect(fixture.credentials.get(forKey: CredentialKey.minimaxApiKey) == "mm_legacy")
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.minimax-api-key") == nil)
    }

    /// (c) When the store refuses the write, the legacy key is still returned and is
    /// never deleted.
    @Test
    func `keeps and returns a legacy MiniMax key when the credential store refuses the write`() {
        let fixture = makeFixture(refusesWrites: true)
        defer { cleanup(fixture) }
        fixture.defaults.set("mm_legacy", forKey: "com.claudebar.credentials.minimax-api-key")

        #expect(fixture.repository.getMinimaxApiKey() == "mm_legacy")
        #expect(fixture.repository.getMinimaxApiKey() == "mm_legacy")
        #expect(fixture.credentials.get(forKey: CredentialKey.minimaxApiKey) == nil)
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.minimax-api-key") == "mm_legacy")
    }

    @Test
    func `deleting a MiniMax key clears the credential store and the legacy key`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }
        fixture.repository.saveMinimaxApiKey("mm_secret")
        fixture.defaults.set("mm_legacy", forKey: "com.claudebar.credentials.minimax-api-key")

        fixture.repository.deleteMinimaxApiKey()

        #expect(fixture.repository.getMinimaxApiKey() == nil)
        #expect(fixture.credentials.get(forKey: CredentialKey.minimaxApiKey) == nil)
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.minimax-api-key") == nil)
    }

    /// An empty value clears both stores instead of persisting a blank.
    @Test
    func `an empty MiniMax key clears both stores instead of storing a blank`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }
        fixture.repository.saveMinimaxApiKey("mm_secret")
        fixture.defaults.set("mm_legacy", forKey: "com.claudebar.credentials.minimax-api-key")

        fixture.repository.saveMinimaxApiKey("")

        #expect(fixture.repository.getMinimaxApiKey() == nil)
        #expect(fixture.repository.hasMinimaxApiKey() == false)
        #expect(fixture.credentials.get(forKey: CredentialKey.minimaxApiKey) == nil)
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.minimax-api-key") == nil)
    }

    // MARK: - Alibaba secrets

    /// (a) Both Alibaba secrets round-trip through the credential store.
    @Test
    func `Alibaba secrets round-trip through the credential store, not UserDefaults`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }

        fixture.repository.saveAlibabaApiKey("ali_key")
        fixture.repository.saveAlibabaManualCookie("login_aliyunid_ticket=abc")

        #expect(fixture.repository.getAlibabaApiKey() == "ali_key")
        #expect(fixture.repository.getAlibabaManualCookie() == "login_aliyunid_ticket=abc")
        #expect(fixture.credentials.get(forKey: CredentialKey.alibabaApiKey) == "ali_key")
        #expect(fixture.credentials.get(forKey: CredentialKey.alibabaManualCookie) == "login_aliyunid_ticket=abc")
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.alibaba-api-key") == nil)
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.alibaba-manual-cookie") == nil)
    }

    /// (b) Legacy Alibaba values migrate on first read and their keys are removed.
    @Test
    func `migrates legacy Alibaba secrets on first read and clears the legacy keys`() {
        let fixture = makeFixture()
        defer { cleanup(fixture) }
        fixture.defaults.set("ali_legacy_key", forKey: "com.claudebar.credentials.alibaba-api-key")
        fixture.defaults.set("ali_legacy_cookie", forKey: "com.claudebar.credentials.alibaba-manual-cookie")

        #expect(fixture.repository.getAlibabaApiKey() == "ali_legacy_key")
        #expect(fixture.repository.getAlibabaManualCookie() == "ali_legacy_cookie")
        #expect(fixture.credentials.get(forKey: CredentialKey.alibabaApiKey) == "ali_legacy_key")
        #expect(fixture.credentials.get(forKey: CredentialKey.alibabaManualCookie) == "ali_legacy_cookie")
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.alibaba-api-key") == nil)
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.alibaba-manual-cookie") == nil)
    }

    /// (c) A refusing store never loses the legacy Alibaba values.
    @Test
    func `keeps and returns legacy Alibaba secrets when the credential store refuses the write`() {
        let fixture = makeFixture(refusesWrites: true)
        defer { cleanup(fixture) }
        fixture.defaults.set("ali_legacy_key", forKey: "com.claudebar.credentials.alibaba-api-key")
        fixture.defaults.set("ali_legacy_cookie", forKey: "com.claudebar.credentials.alibaba-manual-cookie")

        #expect(fixture.repository.getAlibabaApiKey() == "ali_legacy_key")
        #expect(fixture.repository.getAlibabaManualCookie() == "ali_legacy_cookie")
        #expect(fixture.credentials.get(forKey: CredentialKey.alibabaApiKey) == nil)
        #expect(fixture.credentials.get(forKey: CredentialKey.alibabaManualCookie) == nil)
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.alibaba-api-key") == "ali_legacy_key")
        #expect(fixture.defaults.string(forKey: "com.claudebar.credentials.alibaba-manual-cookie") == "ali_legacy_cookie")
    }
}

/// In-memory `CredentialRepository` for the migration tests above. `refusesWrites`
/// models an ad-hoc-signed build whose Keychain write is rejected: `save` is a no-op
/// and `get` never returns it. (`EphemeralCredentials` is private to `CortexRuntime`.)
private final class InMemoryCredentialStore: CredentialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private let refusesWrites: Bool

    init(refusesWrites: Bool = false) {
        self.refusesWrites = refusesWrites
    }

    func save(_ value: String, forKey key: String) {
        guard !refusesWrites else { return }
        lock.withLock { values[key] = value }
    }

    func get(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    func delete(forKey key: String) -> Bool {
        lock.withLock { values[key] = nil }
        return true
    }

    func exists(forKey key: String) -> Bool {
        get(forKey: key) != nil
    }
}
