import SwiftUI
import Domain
import Infrastructure

/// Providers pane: master list of every registered provider with enable
/// toggles; selecting a row drills into that provider's configuration.
struct ProvidersPane: View {
    let monitor: QuotaMonitor

    @Environment(\.appTheme) private var theme
    @State private var selectedProviderId: String?

    var body: some View {
        if let providerId = selectedProviderId,
           let provider = monitor.provider(for: providerId) {
            ProviderDetailView(monitor: monitor, provider: provider) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedProviderId = nil
                }
            }
        } else {
            providerList
        }
    }

    private var providerList: some View {
        SettingsPane(
            title: "Providers",
            subtitle: "Enable the assistants you use. Click a provider to configure it."
        ) {
            VStack(spacing: 8) {
                ForEach(monitor.allProviders, id: \.id) { provider in
                    ProviderListRow(monitor: monitor, provider: provider) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedProviderId = provider.id
                        }
                    }
                }
            }
        }
    }
}

// MARK: - List Row

private struct ProviderListRow: View {
    let monitor: QuotaMonitor
    let provider: any AIProvider
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var lowestQuota: UsageQuota? {
        provider.snapshot?.lowestQuota
    }

    private var statusText: String {
        guard provider.isEnabled else { return "Disabled" }
        guard let snapshot = provider.snapshot else { return "No data yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: snapshot.capturedAt, relativeTo: Date())
        return "Updated \(relative)"
    }

    /// Multi-account providers surface their roster size + how many have a live
    /// reading ("3 comptes · 1 dispo") so the card is glanceable without drilling.
    private var accountSummary: String? {
        guard provider.isEnabled,
              let multi = provider as? any MultiAccountProvider,
              multi.accounts.count > 1 else { return nil }
        let total = multi.accounts.count
        let available = multi.accounts.filter { multi.accountSnapshots[$0.accountId] != nil }.count
        return "\(total) compte\(total > 1 ? "s" : "") · \(available) dispo"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ProviderIconView(providerId: provider.id, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)

                    Text(statusText)
                        .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)

                    if let accountSummary {
                        Text(accountSummary)
                            .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                            .foregroundStyle(theme.textSecondary)
                    }
                }

                Spacer()

                if provider.isEnabled, let quota = lowestQuota {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(Int(quota.percentRemaining))%")
                            .font(.system(size: 12, weight: .bold, design: theme.fontDesign))
                            .foregroundStyle(theme.statusColor(for: quota.status))
                            .monospacedDigit()

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(theme.progressTrack)

                                Capsule()
                                    .fill(theme.statusColor(for: quota.status))
                                    .frame(width: geo.size.width * quota.percentRemaining / 100)
                            }
                        }
                        .frame(width: 80, height: 4)
                    }
                }

                SettingsSwitch(isOn: Binding(
                    get: { provider.isEnabled },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            monitor.setProviderEnabled(provider.id, enabled: newValue)
                        }
                    }
                ))

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                    .fill(theme.cardGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                            .stroke(isHovering ? theme.glassHighlight : theme.glassBorder, lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                            .fill(isHovering ? theme.hoverOverlay : Color.clear)
                    )
            )
            .opacity(provider.isEnabled ? 1 : 0.55)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Detail

/// Per-provider configuration: reuses the existing provider config cards
/// from the popover settings, plus the custom web card URL field.
private struct ProviderDetailView: View {
    let monitor: QuotaMonitor
    let provider: any AIProvider
    let onBack: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(AccountCatalogModel.self) private var catalog
    @State private var bailianProfile = "default"
    @State private var consoleSite = "international"
    @State private var consoleRegion = "ap-southeast-1"

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                backButton

                HStack(spacing: 14) {
                    ProviderIconView(providerId: provider.id, size: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.name)
                            .font(.system(size: 21, weight: .bold, design: theme.fontDesign))
                            .foregroundStyle(theme.textPrimary)

                        Text(provider.isEnabled ? "Enabled" : "Disabled")
                            .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                            .foregroundStyle(provider.isEnabled ? theme.statusHealthy : theme.textTertiary)
                    }

                    Spacer()

                    SettingsSwitch(isOn: Binding(
                        get: { provider.isEnabled },
                        set: { newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                monitor.setProviderEnabled(provider.id, enabled: newValue)
                            }
                        }
                    ))
                }
                .padding(.bottom, 6)

                if provider.isEnabled {
                    if ["claude", "codex", "qwen"].contains(provider.id) {
                        SettingsCard {
                            Text("Quota source").font(.headline)
                            Picker("Source", selection: Binding(
                                get: { provider is RouterBackedProvider ? QuotaSourceMode.router : .autonomous },
                                set: { mode in Task { await catalog.setSource(providerId: provider.id, mode: mode) } }
                            )) {
                                Text("Directe (cet ordinateur)").tag(QuotaSourceMode.autonomous)
                                Text("llm-router").tag(QuotaSourceMode.router)
                            }
                        }
                    }
                    if let multi = provider as? any MultiAccountProvider,
                       ProviderCatalog.addableAccountIDs.contains(provider.id) {
                        AccountManagementCard(provider: multi, monitor: monitor)
                    }
                    if provider.id == "qwen" { qwenConfiguration }
                    configCard
                    preferredModelCard

                    SettingsCard {
                        SettingsFieldLabel(text: "CUSTOM WEB CARD")
                            .padding(.bottom, 8)

                        CustomCardURLField(providerId: provider.id)
                    }
                } else {
                    Text("Enable \(provider.name) to configure it.")
                        .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
    }

    private var qwenConfiguration: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Console Alibaba · Token Plan").font(.headline)
                TextField("Profil Bailian", text: $bailianProfile)
                Picker("Console", selection: $consoleSite) {
                    Text("International").tag("international")
                    Text("Chine").tag("domestic")
                }.onChange(of: consoleSite) { _, site in
                    consoleRegion = site == "domestic" ? "cn-beijing" : "ap-southeast-1"
                }
                TextField("Region", text: $consoleRegion)
                Text("Connexion : bl auth login --console --console-site \(consoleSite) --config \(bailianProfile)")
                    .font(.caption).textSelection(.enabled)
                Button("Save and read quotas") {
                    Task { await catalog.configureQwen(profile: bailianProfile, site: consoleSite, region: consoleRegion) }
                }
                if let error = catalog.proposalError { Text(error).font(.caption).foregroundStyle(theme.statusWarning) }
            }
        }.onAppear {
            let config = JSONSettingsRepository.shared.accounts(forProvider: "qwen").first?.probeConfig ?? [:]
            bailianProfile = config["bailianProfile"] ?? "default"
            consoleSite = config["consoleSite"] ?? "international"
            consoleRegion = config["consoleRegion"] ?? "ap-southeast-1"
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                Text("All Providers")
                    .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.glassBackground)
                    .overlay(Capsule().stroke(theme.glassBorder, lineWidth: 1))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Provider-level preferred LLM (Ben 2026-09-23): chosen once here, shown
    /// ONCE on the provider's overview header — never repeated per account row.
    /// A display preference only; routing stays llm-router's decision (bible §6).
    private var preferredModelCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                SettingsFieldLabel(text: "PREFERRED MODEL")
                Text("The LLM logo shown once next to this provider in the overview. A display preference — routing is still decided by llm-router.")
                    .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.bottom, 4)
                ForEach(ModelFamily.allCases) { family in
                    let selected = AppSettings.shared.providerPreferredModel[provider.id] == family.rawValue
                    Button {
                        if selected {
                            AppSettings.shared.providerPreferredModel.removeValue(forKey: provider.id)
                        } else {
                            AppSettings.shared.providerPreferredModel[provider.id] = family.rawValue
                        }
                    } label: {
                        HStack(spacing: 8) {
                            ModelFamilyLogo(family: family, size: 16)
                            Text(family.displayName)
                                .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                                .foregroundStyle(theme.textPrimary)
                            Spacer(minLength: 16)
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(selected ? theme.accentPrimary : theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The provider-specific config card, when one exists.
    @ViewBuilder
    private var configCard: some View {
        if let routerProvider = provider as? RouterBackedProvider {
            RouterProviderConfigCard(provider: routerProvider)
        } else {
            switch provider.id {
            case "claude":
                ClaudeConfigCard(monitor: monitor)
            case "codex":
                CodexConfigCard(monitor: monitor)
            case "kimi":
                KimiConfigCard(monitor: monitor)
            case "minimax":
                MiniMaxConfigCard(monitor: monitor)
            case "deepseek":
                DeepSeekConfigCard(monitor: monitor)
            case "alibaba":
                AlibabaConfigCard(monitor: monitor)
            case "vercel-gateway":
                VercelConfigCard(monitor: monitor)
            case "copilot":
                CopilotConfigCard(monitor: monitor)
            case "zai":
                ZaiConfigCard(monitor: monitor)
            case "bedrock":
                BedrockConfigCard(monitor: monitor)
            default:
                if let extProvider = provider as? ExtensionProvider, extProvider.manifest.hasConfig {
                    ExtensionConfigCard(
                        provider: extProvider,
                        configRepository: AppSettings.shared.extensionConfig
                    )
                }
            }
        }
    }
}

/// Read-only status for quota identities owned by llm-router. Credential and
/// roster mutations happen in their canonical CLIs; Cortex is a consumer.
private struct RouterProviderConfigCard: View {
    let provider: RouterBackedProvider

    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                SettingsFieldLabel(text: "LLM-ROUTER QUOTA SOURCE")

                HStack {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(theme.accentPrimary)
                    Text(provider.routerProviderId)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("Read only")
                        .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                }

                if provider.accounts.isEmpty {
                    Text("Accounts appear after the first validated v2 snapshot.")
                        .font(.system(size: 11, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(provider.accounts) { account in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(provider.accountSnapshots[account.accountId] == nil
                                    ? theme.statusDepleted
                                    : theme.statusHealthy)
                                .frame(width: 7, height: 7)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                                    .foregroundStyle(theme.textPrimary)
                                if let email = account.email {
                                    Text(email)
                                        .font(.system(size: 10, design: theme.fontDesign))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                if let error = provider.lastGroupErrors[account.accountId] {
                                    Text(error)
                                        .font(.system(size: 10, design: theme.fontDesign))
                                        .foregroundStyle(theme.statusDepleted)
                                }
                            }
                            Spacer()
                        }
                    }
                }

                Text("Manage credentials with the provider CLI; llm-router publishes aliases, freshness, and quota windows to Cortex.")
                    .font(.system(size: 10, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }
}
