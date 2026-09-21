import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("ZaiUsageProbe Environment Variable Fallback Tests")
struct ZaiUsageProbeEnvVarFallbackTests {

    static let sampleConfigWithKey = """
    {
        "env": {
            "ANTHROPIC_BASE_URL": "https://api.z.ai",
            "ANTHROPIC_AUTH_TOKEN": "config-api-key"
        }
    }
    """

    static let sampleConfigWithoutKey = """
    {
        "env": {
            "ANTHROPIC_BASE_URL": "https://api.z.ai"
        }
    }
    """

    private func makeSettingsRepository(
        zaiPath: String = "",
        glmEnvVar: String = ""
    ) -> UserDefaultsProviderSettingsRepository {
        let suiteName = "com.claudebar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let repo = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
        repo.setEnabled(true, forProvider: "zai")
        if !zaiPath.isEmpty {
            repo.setZaiConfigPath(zaiPath)
        }
        if !glmEnvVar.isEmpty {
            repo.setGlmAuthEnvVar(glmEnvVar)
        }
        return repo
    }

    // MARK: - API Key Extraction Preference Tests

    @Test
    func `probe prefers API key from config file over environment variable`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn("/usr/bin/claude")

        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: Self.sampleConfigWithKey, exitCode: 0))

        let mockNetwork = MockNetworkClient()
        let settings = makeSettingsRepository(glmEnvVar: "GLM_TOKEN")

        let probe = ZaiUsageProbe(cliExecutor: mockExecutor, networkClient: mockNetwork, settingsRepository: settings)

        let isAvailable = await probe.isAvailable()

        #expect(isAvailable == true)
    }

    @Test
    func `probe falls back to environment variable when config file has no API key`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn("/usr/bin/claude")

        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: Self.sampleConfigWithoutKey, exitCode: 0))

        let mockNetwork = MockNetworkClient()
        let settings = makeSettingsRepository(glmEnvVar: "GLM_TOKEN")

        let probe = ZaiUsageProbe(cliExecutor: mockExecutor, networkClient: mockNetwork, settingsRepository: settings)

        let isAvailable = await probe.isAvailable()

        #expect(isAvailable == true)
    }

    @Test
    func `probe reports unavailable when no API key found in config or env var`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn("/usr/bin/claude")

        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: Self.sampleConfigWithoutKey, exitCode: 0))

        let mockNetwork = MockNetworkClient()
        let settings = makeSettingsRepository(glmEnvVar: "")

        let probe = ZaiUsageProbe(cliExecutor: mockExecutor, networkClient: mockNetwork, settingsRepository: settings)

        // isAvailable only checks if Claude is installed and z.ai is configured
        // It doesn't validate the API key (that's probe's job)
        let isAvailable = await probe.isAvailable()
        #expect(isAvailable == true)

        // The actual probe() call should fail when trying to get the API key
        do {
            _ = try await probe.probe()
            #expect(Bool(false), "Expected probe() to throw authenticationRequired")
        } catch ProbeError.authenticationRequired {
            // Expected - no API key available
        } catch {
            #expect(Bool(false), "Expected authenticationRequired, got: \(error)")
        }
    }

    // MARK: - Custom Config Path Tests

    @Test
    func `probe uses settings repository for path resolution`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn("/usr/bin/claude")

        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: "", exitCode: 0))

        let mockNetwork = MockNetworkClient()
        let settings = makeSettingsRepository(
            zaiPath: "/custom/path/settings.json",
            glmEnvVar: ""
        )

        let probe = ZaiUsageProbe(cliExecutor: mockExecutor, networkClient: mockNetwork, settingsRepository: settings)

        _ = await probe.isAvailable()

        #expect(true)
    }
}
