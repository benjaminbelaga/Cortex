import SwiftUI
import Domain
import Infrastructure

/// Réglages « Fonctionnalités » : ce que Cortex SUIT (la collecte) et ce qu'il
/// AFFICHE (la présentation), module par module et outil par outil. Les deux
/// sont indépendants — masquer n'arrête pas la collecte, arrêter le suivi
/// n'efface pas les données déjà lues.
///
/// Trois états, jamais d'ambiguïté :
/// - **Automatique** : visible dès que le module a réellement quelque chose à
///   montrer (un compte configuré, un outil détecté) ;
/// - **Afficher** / **Masquer** : un choix explicite, qui survit aux
///   redémarrages et aux nouvelles détections.
struct FeaturesPane: View {
    let monitor: QuotaMonitor

    @Environment(\.appTheme) private var theme
    @State private var settings = AppSettings.shared
    @State private var activationError: String?

    var body: some View {
        SettingsPane(
            title: "Features",
            subtitle: "Choose what Cortex tracks and what it shows. Hiding does not stop collection; stopping tracking does not erase data already read."
        ) {
            if let activationError {
                errorBanner(activationError)
            }
            modulesCard
            toolsCard(
                title: "TRACKED TOOLS AND ACCOUNTS",
                descriptors: ProviderCatalog.all.filter { !$0.isOptional }
            )
            toolsCard(
                title: "CONNECTIONS TO ENABLE",
                descriptors: ProviderCatalog.all.filter { $0.isOptional }
            )
            sessionsCard
            advancedCard
        }
    }

    // MARK: - Modules

    private var modulesCard: some View {
        SettingsCard {
            SettingsFieldLabel(text: "MODULES")
                .padding(.bottom, 8)

            ForEach(Array(FeatureModule.allCases.enumerated()), id: \.element.id) { index, module in
                if index > 0 { SettingsRowDivider() }

                SettingsRow(title: module.title, subtitle: module.subtitle) {
                    SettingsSegmentedControl(
                        options: ModuleVisibility.allCases,
                        label: { $0.displayLabel },
                        selection: binding(moduleId: module.rawValue, fallback: module.defaultVisibility)
                    )
                }
            }
        }
    }

    // MARK: - Outils

    private func toolsCard(title: String, descriptors: [ProviderDescriptor]) -> some View {
        SettingsCard {
            SettingsFieldLabel(text: title)
                .padding(.bottom, 8)

            ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { SettingsRowDivider() }

                SettingsRow(
                    title: descriptor.name,
                    subtitle: capabilitySummary(descriptor)
                ) {
                    HStack(spacing: 10) {
                        SettingsSegmentedControl(
                            options: ModuleVisibility.allCases,
                            label: { $0.displayLabel },
                            selection: binding(moduleId: descriptor.id, fallback: .automatic)
                        )

                        SettingsSwitch(isOn: Binding(
                            get: { settings.isFollowed(providerId: descriptor.id) },
                            set: { setFollowed($0, descriptor: descriptor) }
                        ))
                        .help(
                            descriptor.isOptional
                                ? "Follow this connection: Cortex instantiates it and starts a collection immediately."
                                : "Follow this connection. Disabling it stops collection and alerts without erasing the last reading."
                        )
                    }
                }
            }
        }
    }

    /// Résumé lisible des capacités déclarées : c'est la source unique, jamais
    /// une liste écrite à la main dans la vue.
    private func capabilitySummary(_ descriptor: ProviderDescriptor) -> String {
        let labels: [(ProviderCapability, String)] = [
            (.quota, "quotas"),
            (.accounts, "comptes"),
            (.discovery, "detection"),
            (.sessions, "sessions"),
            (.history, "historique"),
            (.costEstimate, "costs"),
            (.reconnect, "reconnect"),
        ]
        let names = labels.filter { descriptor.capabilities.contains($0.0) }.map(\.1)
        let source: String
        switch descriptor.runtime {
        case .router: source = "router source"
        case .native: source = "native source"
        case .routerOrNative: source = "router or native source"
        }
        return "\(names.joined(separator: " · ")) — \(source)"
    }

    // MARK: - Sessions

    private var sessionsCard: some View {
        SettingsCard {
            SettingsFieldLabel(text: "SESSIONS")
                .padding(.bottom, 4)

            Text("Choose which tools' sessions are shown. A hidden tool is still tracked for its quotas.")
                .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, 8)

            ForEach(Array(sessionTools.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(title: descriptor.name, subtitle: "sessions detected locally") {
                    SettingsSegmentedControl(
                        options: ModuleVisibility.allCases,
                        label: { $0.displayLabel },
                        selection: binding(moduleId: descriptor.id, fallback: .automatic)
                    )
                }
            }

            SettingsRowDivider()

            SettingsRow(
                title: "Sous-agents",
                subtitle: "Count sub-agents under their main session, with a separate counter."
            ) {
                SettingsSegmentedControl(
                    options: [ModuleVisibility.visible, .hidden],
                    label: { $0.displayLabel },
                    selection: Binding(
                        get: { settings.sessionOption("subagents") },
                        set: { settings.setSessionOption($0, id: "subagents") }
                    )
                )
            }
        }
    }

    private var sessionTools: [ProviderDescriptor] {
        ProviderCatalog.all.filter { $0.capabilities.contains(.sessions) }
    }

    // MARK: - Intégrations avancées

    private var advancedCard: some View {
        SettingsCard {
            SettingsFieldLabel(text: "ADVANCED INTEGRATIONS")
                .padding(.bottom, 8)

            SettingsRow(
                title: "llm-router",
                subtitle: routerPresent
                    ? "Detected — router rows read the shared snapshot."
                    : "Absent — Cortex natively probes installed tools."
            ) {
                Text(routerPresent ? "Detected" : "Absent")
                    .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(routerPresent ? theme.statusHealthy : theme.textTertiary)
            }

            SettingsRowDivider()

            SettingsRow(
                title: "Automatic detection",
                subtitle: "Cortex detects on launch, on wake and on demand. A tool installed alone stays a suggestion; a configured or observed usage makes it visible."
            ) {
                Text("Active")
                    .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            if let failoverSummary {
                SettingsRowDivider()

                SettingsRow(
                    title: "OpenCode Go failover",
                    subtitle: failoverSummary
                ) {
                    Text("SSOT")
                        .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private var routerPresent: Bool {
        RouterSourceModeMigration.routerRegistryPresent()
    }

    /// Lecture seule de la chaîne de secours réelle (Go → Ollama) via le même
    /// lecteur que la carte de la fiche reset : Cortex montre l'état vivant
    /// (sert maintenant, quarantaines, tier2) sans dupliquer le fichier.
    private var failoverSummary: String? {
        let state = FailoverChainReader().read()
        guard !state.slots.isEmpty else { return nil }
        var parts: [String] = []
        parts.append("\(state.goSlots.count) Go account\(state.goSlots.count > 1 ? "s" : "")")
        if let serving = state.servingGo { parts.append("serving: \(serving.label)") }
        let benched = state.slots.filter(\.isQuarantined).count
        if benched > 0 { parts.append("\(benched) quarantined") }
        parts.append(state.ollamaArmed ? "Ollama armed" : "Ollama off")
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func setFollowed(_ followed: Bool, descriptor: ProviderDescriptor) {
        if followed {
            guard monitor.follow(providerId: descriptor.id) else {
                activationError = "Cannot enable \(descriptor.name): no provider could be built from the catalogue."
                return
            }
        } else {
            monitor.unfollow(providerId: descriptor.id)
        }
        activationError = nil
    }

    private func binding(moduleId: String, fallback: ModuleVisibility) -> Binding<ModuleVisibility> {
        Binding(
            get: { settings.moduleVisibility(id: moduleId, fallback: fallback) },
            set: { settings.setModuleVisibility($0, id: moduleId) }
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.statusColor(for: .warning))
            Text(message)
                .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                .fill(theme.glassBackground)
        )
    }
}
