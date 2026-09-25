import AppKit
import ServiceManagement
import Domain
import Infrastructure

/// Explicit local smoke entry point. Credentials stay in memory/Keychain; stdout is a redacted report.
@MainActor
enum AccountDiagnostics {
    static var requested: Bool {
        CommandLine.arguments.contains("--diagnose-accounts") || CommandLine.arguments.contains("--add-clipboard-account")
            || CommandLine.arguments.contains("--add-clipboard-accounts")
            || CommandLine.arguments.contains("--unify-opencode-accounts")
            || CommandLine.arguments.contains("--unify-ollama-accounts")
            || CommandLine.arguments.contains("--unify-commandcode-accounts")
            || CommandLine.arguments.contains("--repair-login-item")
    }

    static func run() async -> Int32 {
        if CommandLine.arguments.contains("--repair-login-item") { return repairLoginItem() }
        let settings = JSONSettingsRepository.shared
        APIAccountCredentials.importLocalAccounts(settings: settings)
        let unifyOllama = CommandLine.arguments.contains("--unify-ollama-accounts")
        let unifyCommandCode = CommandLine.arguments.contains("--unify-commandcode-accounts")
        if CommandLine.arguments.contains("--unify-opencode-accounts") || unifyOllama || unifyCommandCode {
            // Dry run unless --apply. Runs as Cortex, so its own Keychain items never prompt.
            let apply = CommandLine.arguments.contains("--apply")
            do {
                let pool: any FailoverKeyPool = unifyCommandCode ? CommandCodeFailoverPool()
                    : OpenCodeFailoverPool(loader: unifyOllama ? .ollamaCloud() : OpenCodeCredentialLoader())
                let outcomes = try OpenCodeAccountUnifier.unify(settings: settings,
                    credentials: KeychainCredentialRepository.shared, pool: pool,
                    providerId: unifyCommandCode ? "commandcode" : (unifyOllama ? "ollama" : "opencode-go"), apply: apply)
                for o in outcomes {
                    print("\(apply ? "" : "[dry-run] ")\(o.label): \(o.action)"
                          + (o.orphanedCredentialKey.map { " · Keychain item kept: \($0)" } ?? ""))
                }
                if outcomes.isEmpty { print("No Keychain-backed \(unifyCommandCode ? "Command Code" : (unifyOllama ? "Ollama" : "OpenCode Go")) account — nothing to unify.") }
                return 0
            } catch {
                print("Unify failed: \(error.localizedDescription); nothing printed contains a key.")
                return 1
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--add-clipboard-account") {
            guard CommandLine.arguments.indices.contains(index + 2) else { return 2 }
            let provider = CommandLine.arguments[index + 1]
            let label = CommandLine.arguments[index + 2]
            guard ProviderCatalog.apiKeyAccountIDs.contains(provider),
                  let key = NSPasteboard.general.string(forType: .string) else { return 2 }
            let resolver = ProfileResolver()
            let model = AccountCatalogModel(enrolmentService: AccountEnrolmentService(),
                discovery: AccountDiscoveryService(resolver: resolver, validator: CLIProfileIdentityValidator()),
                resolver: resolver, settingsRepository: settings, homeDirectory: NSHomeDirectory(),
                activateIntegration: { settings.setEnabled(true, forProvider: $0) })
            await model.addAPIAccount(providerId: provider, label: label, apiKey: key)
            guard model.addedAccountLabel != nil else {
                // proposalError never contains the key (labels and HTTP classes only).
                print("Account not added: \(model.proposalError ?? "validation or storage failed"); no secret was printed.")
                return 1
            }
        }
        // Global auto-routing paste: each key goes to the provider its shape
        // belongs to. Nothing to add when every key is already enrolled.
        if CommandLine.arguments.contains("--add-clipboard-accounts") {
            let resolver = ProfileResolver()
            let model = AccountCatalogModel(enrolmentService: AccountEnrolmentService(),
                discovery: AccountDiscoveryService(resolver: resolver, validator: CLIProfileIdentityValidator()),
                resolver: resolver, settingsRepository: settings, homeDirectory: NSHomeDirectory(),
                activateIntegration: { settings.setEnabled(true, forProvider: $0) })
            await model.addAPIAccountsFromPasteboard(providerId: "opencode-go",
                fallbackLabel: "Account", autoRoute: true)
            // Labels and error classes only — never a key.
            print("added: \(model.addedAccountLabel ?? "none")")
            if let error = model.proposalError { print("note: \(error)") }
        }
        var report: [[String: Any]] = []
        var failures = 0
        for provider in ProviderCatalog.apiKeyAccountIDs {
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

    /// `Cortex --repair-login-item`: the installed app (re)registers itself at
    /// login; any other bundle (Debug, DerivedData, backup) unregisters itself so
    /// it stops launching a second Cortex at every reboot.
    private static func repairLoginItem() -> Int32 {
        let path = Bundle.main.bundlePath
        let service = SMAppService.mainApp
        do {
            if LoginItemPolicy.canRegister(bundlePath: path, isDebugBuild: AppSettings.isDebugBuild) {
                if service.status != .enabled { try service.register() }
                print("login item registered: \(path) (status \(service.status.rawValue))")
            } else {
                try? service.unregister()
                print("login item removed for non-installed bundle: \(path) (status \(service.status.rawValue))")
            }
            return 0
        } catch {
            print("login item repair failed: \(error.localizedDescription)")
            return 1
        }
    }
}
