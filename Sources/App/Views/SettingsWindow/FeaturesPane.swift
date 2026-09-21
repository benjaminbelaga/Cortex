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
            title: "Fonctionnalités",
            subtitle: "Choisissez ce que Cortex suit et ce qu'il affiche. Masquer n'arrête pas la collecte ; arrêter le suivi n'efface pas les données déjà lues."
        ) {
            if let activationError {
                errorBanner(activationError)
            }
            modulesCard
            toolsCard(
                title: "OUTILS ET COMPTES SUIVIS",
                descriptors: ProviderCatalog.all.filter { !$0.isOptional }
            )
            toolsCard(
                title: "CONNEXIONS À ACTIVER",
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
                                ? "Suivre cette connexion : Cortex l'instancie et lance une collecte immédiatement."
                                : "Suivre cette connexion. La désactiver arrête la collecte et les alertes, sans effacer le dernier relevé."
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
            (.discovery, "détection"),
            (.sessions, "sessions"),
            (.history, "historique"),
            (.costEstimate, "coûts"),
            (.reconnect, "reconnexion"),
        ]
        let names = labels.filter { descriptor.capabilities.contains($0.0) }.map(\.1)
        let source: String
        switch descriptor.runtime {
        case .router: source = "source routeur"
        case .native: source = "source native"
        case .routerOrNative: source = "source routeur ou native"
        }
        return "\(names.joined(separator: " · ")) — \(source)"
    }

    // MARK: - Sessions

    private var sessionsCard: some View {
        SettingsCard {
            SettingsFieldLabel(text: "SESSIONS")
                .padding(.bottom, 4)

            Text("Choisissez les outils dont les sessions sont affichées. Un outil masqué reste suivi pour ses quotas.")
                .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, 8)

            ForEach(Array(sessionTools.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(title: descriptor.name, subtitle: "sessions détectées localement") {
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
                subtitle: "Compter les sous-agents sous leur session principale, avec un compteur séparé."
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
            SettingsFieldLabel(text: "INTÉGRATIONS AVANCÉES")
                .padding(.bottom, 8)

            SettingsRow(
                title: "Routeur llm-router",
                subtitle: routerPresent
                    ? "Détecté — les lignes routeur lisent le snapshot partagé."
                    : "Absent — Cortex sonde nativement les outils installés."
            ) {
                Text(routerPresent ? "Détecté" : "Absent")
                    .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(routerPresent ? theme.statusHealthy : theme.textTertiary)
            }

            SettingsRowDivider()

            SettingsRow(
                title: "Détection automatique",
                subtitle: "Cortex détecte au démarrage, au réveil et sur demande. Un outil installé seul reste une suggestion ; une configuration ou un usage constaté le rend visible."
            ) {
                Text("Active")
                    .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            if let failoverSummary {
                SettingsRowDivider()

                SettingsRow(
                    title: "Bascule OpenCode Go",
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

    /// Lecture seule du SSOT de bascule (mapping clé → compte, quarantaine
    /// partagée) : Cortex montre l'état réel sans dupliquer le fichier.
    private var failoverSummary: String? {
        let path = ("~/.config/opencode/failover-ssot.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier1 = root["tier1"] as? [String: Any] else {
            return nil
        }
        let slots = (tier1["slots"] as? [String]) ?? []
        let minKeys = (tier1["min_keys"] as? Int) ?? 2
        return "\(slots.count) comptes déclarés (minimum \(minKeys) pour basculer) · quarantaine partagée entre processus"
    }

    // MARK: - Actions

    private func setFollowed(_ followed: Bool, descriptor: ProviderDescriptor) {
        if followed {
            guard monitor.follow(providerId: descriptor.id) else {
                activationError = "Impossible d'activer \(descriptor.name) : aucun provider n'a pu être construit depuis le catalogue."
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
