import Foundation
import Testing
import Domain
import Infrastructure
@testable import ClaudeBar

@Suite("API account enrolment") @MainActor
struct APIAccountEnrolmentTests {
    private final class Credentials: CredentialRepository, @unchecked Sendable {
        var values: [String: String] = [:]
        var rejectWrites = false
        func save(_ value: String, forKey key: String) { if !rejectWrites { values[key] = value } }
        func get(forKey key: String) -> String? { values[key] }
        func exists(forKey key: String) -> Bool { values[key] != nil }
        func delete(forKey key: String) -> Bool { values[key] = nil; return true }
    }
    private struct Validator: ProfileIdentityValidating {
        func authenticatedEmail(forProvider: String, profilePath: String) async -> String? { nil }
    }

    private func fixture(reject: Bool = false, invalid: Bool = false) -> (AccountCatalogModel, JSONSettingsRepository, Credentials, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
        let credentials = Credentials()
        credentials.rejectWrites = reject
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: url),
            credentials: UserDefaults(suiteName: "test.cortex.\(UUID())")!, secureCredentials: credentials)
        let resolver = ProfileResolver()
        let model = AccountCatalogModel(enrolmentService: AccountEnrolmentService(),
            discovery: AccountDiscoveryService(resolver: resolver, validator: Validator()),
            resolver: resolver, settingsRepository: settings, homeDirectory: url.deletingLastPathComponent().path,
            credentials: credentials,
            probeAPIKey: { provider, _ in
                if invalid { throw ProbeError.authenticationRequired }
                return UsageSnapshot(providerId: provider,
                    quotas: [.init(percentRemaining: 70, quotaType: .session, providerId: provider)], capturedAt: Date())
            }, activateIntegration: { settings.setEnabled(true, forProvider: $0) })
        return (model, settings, credentials, url)
    }

    @Test func twoAccountsSurviveReloadWithoutPlaintextKeys() async throws {
        let (model, settings, credentials, url) = fixture()
        await model.addAPIAccount(providerId: "commandcode", label: "Personal", apiKey: "fixture-personal")
        await model.addAPIAccount(providerId: "commandcode", label: "Work", apiKey: "fixture-work")
        let restored = JSONSettingsRepository(store: JSONSettingsStore(fileURL: url), secureCredentials: credentials)
        let accounts = restored.accounts(forProvider: "commandcode")
        #expect(accounts.map(\.label) == ["Personal", "Work"])
        #expect(Set(accounts.map(\.accountId)).count == 2)
        #expect(credentials.values.count == 2)
        #expect(settings.isEnabled(forProvider: "commandcode"))
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("fixture-personal"))
        #expect(!json.contains("fixture-work"))
        #expect(model.addedAccountLabel == "Work")
    }

    @Test func invalidKeyCannotCreateAccount() async {
        let (model, settings, credentials, _) = fixture(invalid: true)
        await model.addAPIAccount(providerId: "opencode-go", label: "Invalid", apiKey: "fixture-invalid")
        #expect(settings.accounts(forProvider: "opencode-go").isEmpty)
        #expect(credentials.values.isEmpty)
        #expect(model.proposalError != nil)
    }

    @Test func keychainFailureCannotCreateFalseSuccess() async {
        let (model, settings, _, _) = fixture(reject: true)
        await model.addAPIAccount(providerId: "commandcode", label: "Unsaved", apiKey: "fixture-unsaved")
        #expect(settings.accounts(forProvider: "commandcode").isEmpty)
        #expect(model.addedAccountLabel == nil)
        #expect(model.proposalError != nil)
    }

    @Test func failedAccountDoesNotHideHealthyAccountOrLastReading() async throws {
        let (_, settings, _, _) = fixture()
        for id in ["good", "bad"] { settings.addAccount(.init(accountId: id, label: id), forProvider: "commandcode") }
        settings.setEnabled(true, forProvider: "commandcode")
        let switcher = SwitchableProbe()
        let provider = AccountUsageProvider(id: "commandcode", name: "Command Code", cliCommand: "cmd",
            dashboardURL: nil, settings: settings, makeProbe: { config in
                if config.accountId == "bad" { return switcher }
                return FixedProbe()
            })
        await provider.refreshAllAccounts(.interactive)
        #expect(provider.accountSnapshots.count == 2)
        await switcher.fail()
        await provider.refreshAllAccounts(.interactive)
        #expect(provider.accountSnapshots.count == 2)
        #expect(provider.accountRefreshStates["good"] == .ready)
        if case .failed = provider.accountRefreshStates["bad"] {} else { Issue.record("Missing per-account failure") }
        provider.isEnabled = false
        #expect(OverviewBuilder.build(providers: [provider]).isEmpty)
    }

    private struct FixedProbe: UsageProbe {
        func isAvailable() async -> Bool { true }
        func probe() async throws -> UsageSnapshot {
            UsageSnapshot(providerId: "commandcode", quotas: [.init(percentRemaining: 75, quotaType: .session, providerId: "commandcode")], capturedAt: Date())
        }
    }
    private actor SwitchableProbe: UsageProbe {
        var failing = false
        func fail() { failing = true }
        func isAvailable() async -> Bool { true }
        func probe() async throws -> UsageSnapshot {
            if failing { throw ProbeError.authenticationRequired }
            return try await FixedProbe().probe()
        }
    }
}
