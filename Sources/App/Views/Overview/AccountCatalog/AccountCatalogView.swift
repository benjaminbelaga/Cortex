import SwiftUI
import Domain

/// The `+` panel (D tranche): two honest entries.
///
/// 1. "Ajouter un compte" — detected profiles (identity masked, origin path
///    shown, read-back verified by the sweep) + new isolated accounts via the
///    official tool login. Every outcome is a typed `EnrolmentState`; the
///    panel NEVER reports success from a mere terminal launch.
/// 2. "Ajouter une connexion" — optional integrations (qwen-api / bedrock /
///    local) with explicit activation, never silently enabled.
///
/// Rendered inside the popover (no `.sheet` — those never render from an
/// NSPopover-backed MenuBarExtra).
struct AccountCatalogView: View {
    @Bindable var model: AccountCatalogModel
    var onClose: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var apiKey = ""
    @State private var newLabel = ""
    @State private var expectedEmail = ""

    private static let providers = ["claude", "codex", "opencode-go", "commandcode"]
    private var usesAPIKey: Bool { ["opencode-go", "commandcode"].contains(model.selectedProvider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(CatalogStrings.accountsSectionTitle)
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }

            newAccountControls
            detectedList
            activeEnrolments

            Divider().overlay(theme.glassBorder)

            connectionsSection
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.glassBackground))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.glassBorder, lineWidth: 1))
    }

    // MARK: - New account

    private var newAccountControls: some View {
        VStack(spacing: 5) {
            Picker("Outil", selection: $model.selectedProvider) {
                ForEach(Self.providers, id: \.self) { Text(ProviderCatalog.descriptor(forId: $0)?.name ?? $0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                TextField("Libellé (ex. STUDIO)", text: $newLabel)
                    .textFieldStyle(.plain)
                if usesAPIKey {
                    SecureField("Clé API", text: $apiKey).textFieldStyle(.plain)
                } else {
                    TextField("Identité attendue (facultatif)", text: $expectedEmail)
                        .textFieldStyle(.plain)
                }
            }
            .font(theme.font(size: 9))

            HStack(spacing: 6) {
                Button {
                    if usesAPIKey {
                        let key = apiKey
                        apiKey = ""
                        Task { await model.addAPIAccount(providerId: model.selectedProvider, label: newLabel, apiKey: key) }
                    } else {
                        model.enrolNew(providerId: model.selectedProvider, label: newLabel, expectedEmail: expectedEmail)
                    }
                } label: {
                    Text(model.isValidatingKey ? "Validation…" : "Ajouter ce compte")
                        .font(theme.font(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isValidatingKey || newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (usesAPIKey && apiKey.isEmpty))

                Button {
                    Task { await model.search() }
                } label: {
                    HStack(spacing: 3) {
                        if model.isSearching {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(theme.font(size: 8, weight: .semibold))
                        }
                        Text(CatalogStrings.searchAction)
                            .font(theme.font(size: 9, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentPrimary)
                .disabled(model.isSearching)
                .help("Balaye ~/.claude-accounts, ~/.codex-accounts et les dossiers plats — seuls les profils authentifiés remontent, identité masquée.")
            }

            if let label = model.addedAccountLabel {
                Label("\(label) ajouté · quotas vérifiés", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.statusHealthy)
            }
            if let error = model.proposalError {
                Text(error)
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.statusColor(for: .warning))
            }
        }
    }

    // MARK: - Detected profiles

    @ViewBuilder
    private var detectedList: some View {
        if !model.detectedProfiles.isEmpty {
            VStack(spacing: 3) {
                ForEach(model.detectedProfiles, id: \.canonicalPath) { proposal in
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle")
                            .font(theme.font(size: 9))
                            .foregroundStyle(theme.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(IdentityMasking.mask(proposal.email) ?? proposal.email ?? "Profil détecté")
                                .font(theme.font(size: 9, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text(proposal.canonicalPath)
                                .font(theme.font(size: 7, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Button(CatalogStrings.followAction) {
                            model.follow(proposal)
                        }
                        .font(theme.font(size: 9, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accentPrimary)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.glassBackground))
                }
            }
        }
    }

    // MARK: - Active enrolments

    private var activeEnrolments: some View {
        VStack(spacing: 3) {
            ForEach(model.states.sorted(by: { $0.key.uuidString < $1.key.uuidString }), id: \.key) { uuid, state in
                EnrolmentProgressView(state: state) {
                    model.cancel(uuid: uuid)
                }
                .contextMenu {
                    Button("Effacer cette ligne") { model.forget(uuid: uuid) }
                }
            }
        }
    }

    // MARK: - Integrations

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CatalogStrings.connectionsSectionTitle)
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            ForEach(model.integrationDescriptors, id: \.id) { descriptor in
                HStack(spacing: 5) {
                    Image(systemName: descriptor.symbolName)
                        .font(theme.font(size: 9))
                        .foregroundStyle(theme.textTertiary)
                    Text(descriptor.name)
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                    if model.isActiveIntegration(descriptor.id) {
                        Text(CatalogStrings.activeLabel)
                            .font(theme.font(size: 8, weight: .semibold))
                            .foregroundStyle(theme.statusColor(for: .healthy))
                    } else {
                        Button(CatalogStrings.activateAction) {
                            model.activate(descriptor.id)
                        }
                        .font(theme.font(size: 9, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accentPrimary)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.glassBackground))
            }
        }
    }
}
