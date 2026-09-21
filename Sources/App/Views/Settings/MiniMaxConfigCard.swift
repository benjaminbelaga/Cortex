import SwiftUI
import Domain
import Infrastructure

/// MiniMax provider configuration card for SettingsView.
struct MiniMaxConfigCard: View {
    let monitor: QuotaMonitor

    @State private var settings = AppSettings.shared
    @Environment(\.appTheme) private var theme

    @State private var miniMaxConfigExpanded: Bool = false
    @State private var miniMaxApiKeyInput: String = ""
    @State private var miniMaxAuthEnvVarInput: String = ""
    @State private var miniMaxRegion: MiniMaxRegion = .china
    @State private var showMiniMaxApiKey: Bool = false
    @State private var isTestingMiniMax = false
    @State private var miniMaxTestResult: String?

    var body: some View {
        DisclosureGroup(isExpanded: $miniMaxConfigExpanded) {
            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 12)

            miniMaxConfigForm
        } label: {
            miniMaxConfigHeader
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        miniMaxConfigExpanded.toggle()
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
                                colors: [
                                    theme.glassBorder, theme.glassBorder.opacity(0.5)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .onAppear {
            miniMaxRegion = settings.minimax.minimaxRegion()
            miniMaxAuthEnvVarInput = settings.minimax.minimaxAuthEnvVar()
        }
    }

    private var miniMaxConfigHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.91, green: 0.27, blue: 0.42),
                                Color(red: 0.96, green: 0.53, blue: 0.24)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: "waveform")
                    .font(theme.font(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("MiniMax Configuration")
                    .font(theme.font(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text("Coding Plan quota tracking")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()
        }
    }

    private var miniMaxConfigForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Region selector
            VStack(alignment: .leading, spacing: 6) {
                Text("REGION")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                Picker("", selection: $miniMaxRegion) {
                    ForEach(MiniMaxRegion.allCases, id: \.self) { region in
                        Text(region.displayName).tag(region)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: miniMaxRegion) { _, newValue in
                    settings.minimax.setMinimaxRegion(newValue)
                    Task {
                        await monitor.refresh(providerId: "minimax")
                    }
                }
            }

            // API Key input
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API KEY")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    Spacer()

                    if settings.minimax.hasMinimaxApiKey() {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(theme.font(size: 9))
                            Text("Configured")
                                .font(theme.font(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(theme.statusHealthy)
                    }
                }

                HStack(spacing: 6) {
                    Group {
                        if showMiniMaxApiKey {
                            TextField("", text: $miniMaxApiKeyInput, prompt: Text("eyJhbGci...").foregroundStyle(theme.textTertiary))
                        } else {
                            SecureField("", text: $miniMaxApiKeyInput, prompt: Text("eyJhbGci...").foregroundStyle(theme.textTertiary))
                        }
                    }
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

                    Button {
                        showMiniMaxApiKey.toggle()
                    } label: {
                        Image(systemName: showMiniMaxApiKey ? "eye.slash.fill" : "eye.fill")
                            .font(theme.font(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(theme.glassBackground)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Environment Variable
            VStack(alignment: .leading, spacing: 6) {
                Text("API KEY ENV VAR (ALTERNATIVE)")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                TextField("", text: $miniMaxAuthEnvVarInput, prompt: Text("MINIMAX_API_KEY").foregroundStyle(theme.textTertiary))
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
                    .onChange(of: miniMaxAuthEnvVarInput) { _, newValue in
                        settings.minimax.setMinimaxAuthEnvVar(newValue)
                    }
            }

            // Token lookup order
            VStack(alignment: .leading, spacing: 4) {
                Text("API KEY LOOKUP ORDER")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                Text("1. First checks environment variable (default: MINIMAX_API_KEY)")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Text("2. Falls back to API key entered above")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

            // Save & Test button
            if isTestingMiniMax {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Testing connection...")
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                Button {
                    Task {
                        await testMiniMaxConnection()
                    }
                } label: {
                    Text("Save & Test Connection")
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentPrimary)
                        )
                }
                .buttonStyle(.plain)
            }

            if let result = miniMaxTestResult {
                Text(result)
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(result.contains("Success") ? theme.statusHealthy : theme.statusCritical)
            }

            // Help link
            VStack(alignment: .leading, spacing: 4) {
                Text("Get your API key from MiniMax platform")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)

                Link(destination: miniMaxRegion.apiKeysURL) {
                    HStack(spacing: 3) {
                        Text("Open MiniMax API Keys")
                            .font(theme.font(size: 9, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(theme.font(size: 7, weight: .bold))
                    }
                    .foregroundStyle(theme.accentPrimary)
                }
            }

            // Delete API key
            if settings.minimax.hasMinimaxApiKey() {
                Button {
                    settings.minimax.deleteMinimaxApiKey()
                    miniMaxApiKeyInput = ""
                    miniMaxTestResult = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(theme.font(size: 9))
                        Text("Remove API Key")
                            .font(theme.font(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(theme.statusCritical)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func testMiniMaxConnection() async {
        isTestingMiniMax = true
        miniMaxTestResult = nil

        settings.minimax.setMinimaxAuthEnvVar(miniMaxAuthEnvVarInput)
        if !miniMaxApiKeyInput.isEmpty {
            AppLog.credentials.info("Saving MiniMax API key for connection test")
            settings.minimax.saveMinimaxApiKey(miniMaxApiKeyInput)
            miniMaxApiKeyInput = ""
        }

        AppLog.credentials.info("Testing MiniMax connection via provider refresh")
        await monitor.refresh(providerId: "minimax")

        if let error = monitor.provider(for: "minimax")?.lastError {
            AppLog.credentials.error("MiniMax connection test failed: \(error.localizedDescription)")
            miniMaxTestResult = "Failed: \(error.localizedDescription)"
        } else {
            AppLog.credentials.info("MiniMax connection test succeeded")
            miniMaxTestResult = "Success: Connection verified"
        }

        isTestingMiniMax = false
    }
}
