import AppKit
import Domain
import Infrastructure

/// Explicit local smoke entry point. Credentials stay in memory/Keychain; stdout is a redacted report.
@MainActor
enum AccountDiagnostics {
    static var requested: Bool {
        CommandLine.arguments.contains("--diagnose-accounts") || CommandLine.arguments.contains("--add-clipboard-account")
    }

    static func run() async -> Int32 {
        let settings = JSONSettingsRepository.shared
        APIAccountCredentials.importLocalAccounts(settings: settings)
        if let index = CommandLine.arguments.firstIndex(of: "--add-clipboard-account") {
            guard CommandLine.arguments.indices.contains(index + 2) else { return 2 }
            let provider = CommandLine.arguments[index + 1]
            let label = CommandLine.arguments[index + 2]
            guard ["commandcode", "opencode-go"].contains(provider),
                  let key = NSPasteboard.general.string(forType: .string) else { return 2 }
            let resolver = ProfileResolver()
            let model = AccountCatalogModel(enrolmentService: AccountEnrolmentService(),
                discovery: AccountDiscoveryService(resolver: resolver, validator: CLIProfileIdentityValidator()),
                resolver: resolver, settingsRepository: settings, homeDirectory: NSHomeDirectory(),
                activateIntegration: { settings.setEnabled(true, forProvider: $0) })
            await model.addAPIAccount(providerId: provider, label: label, apiKey: key)
            guard model.addedAccountLabel != nil else {
                print("Account validation or storage failed; no secret was printed.")
                return 1
            }
        }
        var report: [[String: Any]] = []
        var failures = 0
        for provider in ["opencode-go", "commandcode"] {
            for config in settings.accounts(forProvider: provider) {
                do {
                    let snapshot = try await APIAccountCredentials.probe(providerId: provider, config: config).probe()
                    report.append(["provider": provider, "account": config.accountId, "label": config.label,
                        "status": "ok", "windows": snapshot.quotas.map {
                            ["window": $0.quotaType.displayName, "remaining": $0.percentRemaining,
                             "reset": $0.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"] as [String: Any]
                        }])
                } catch {
                    failures += 1
                    report.append(["provider": provider, "account": config.accountId, "status": "failed",
                                   "error": String(describing: type(of: error))])
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        return failures == 0 ? 0 : 1
    }
}
