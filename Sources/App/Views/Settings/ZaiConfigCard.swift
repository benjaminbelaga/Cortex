import SwiftUI
import Domain
import Infrastructure

/// Z.ai / GLM provider configuration card for SettingsView.
struct ZaiConfigCard: View {
    let monitor: QuotaMonitor

    @State private var settings = AppSettings.shared
    @Environment(\.appTheme) private var theme

    @State private var zaiConfigExpanded: Bool = false
    @State private var zaiConfigPathInput: String = ""
    @State private var glmAuthEnvVarInput: String = ""

    var body: some View {
        DisclosureGroup(isExpanded: $zaiConfigExpanded) {
            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 14) {
                // Explanation text
                VStack(alignment: .leading, spacing: 6) {
                    Text("TOKEN LOOKUP ORDER")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    Text("1. First looks for token in the settings.json file")
                        .font(theme.font(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    Text("2. Falls back to environment variable if not found in file")
                        .font(theme.font(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("SETTINGS.JSON PATH")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    TextField("", text: $zaiConfigPathInput, prompt: Text("~/.claude/settings.json").foregroundStyle(theme.textTertiary))
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.glassBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.glassBorder, lineWidth: 1)
                                )
                        )
                        .onChange(of: zaiConfigPathInput) { _, newValue in
                            settings.zai.setZaiConfigPath(newValue)
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("AUTH TOKEN ENV VAR (FALLBACK)")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    TextField("", text: $glmAuthEnvVarInput, prompt: Text("GLM_AUTH_TOKEN").foregroundStyle(theme.textTertiary))
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.glassBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.glassBorder, lineWidth: 1)
                                )
                        )
                        .onChange(of: glmAuthEnvVarInput) { _, newValue in
                            settings.zai.setGlmAuthEnvVar(newValue)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Leave both empty to use default path with no env var fallback")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.2, green: 0.6, blue: 0.9),
                                    Color(red: 0.15, green: 0.45, blue: 0.8)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)

                    Image(systemName: "gearshape.fill")
                        .font(theme.font(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Z.ai / GLM Configuration")
                    .font(theme.font(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text("Authentication fallback settings")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

                Spacer()
            }
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    zaiConfigExpanded.toggle()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.cardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            LinearGradient(
                                colors: [theme.glassBorder, theme.glassBorder.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .onAppear {
            zaiConfigPathInput = settings.zai.zaiConfigPath()
            glmAuthEnvVarInput = settings.zai.glmAuthEnvVar()
        }
    }
}
