import SwiftUI
import Domain

/// Sheet for adding a new Claude account profile.
///
/// Prompts for a display label and the isolated Claude config directory.
/// The account ID is derived from the label; the probe uses the config
/// directory as `CLAUDE_CONFIG_DIR`.
struct AddAccountSheet: View {
    let provider: any MultiAccountProvider

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var configPath = ""
    @State private var email = ""

    private var accountId: String {
        label
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .joined()
    }

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && !configPath.trimmingCharacters(in: .whitespaces).isEmpty
            && !accountId.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Claude Account")
                .font(theme.font(size: 16, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Label")
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                TextField("e.g. Work", text: $label)
                    .font(theme.font(size: 12, weight: .medium))
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Config directory")
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                TextField("~/.claude-work", text: $configPath)
                    .font(theme.font(size: 12, weight: .medium))
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Email (optional)")
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                TextField("you@example.com", text: $email)
                    .font(theme.font(size: 12, weight: .medium))
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.glassBackground)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    saveAccount()
                } label: {
                    Text("Add Account")
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isValid ? theme.accentPrimary : theme.glassBackground)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func saveAccount() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedPath = configPath.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces).nilIfEmpty

        let config = ProviderAccountConfig(
            accountId: accountId,
            label: trimmedLabel,
            email: trimmedEmail,
            probeConfig: ["claudeConfigDir": trimmedPath]
        )

        if provider.addAccount(config) {
            dismiss()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
