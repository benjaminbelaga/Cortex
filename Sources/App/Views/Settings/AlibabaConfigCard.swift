import SwiftUI
import Domain
import Infrastructure

/// Alibaba Coding Plan provider configuration card for SettingsView.
struct AlibabaConfigCard: View {
    let monitor: QuotaMonitor

    @State private var settings = AppSettings.shared
    @Environment(\.appTheme) private var theme

    @State private var alibabaConfigExpanded: Bool = false
    @State private var alibabaRegion: AlibabaRegion = .international
    @State private var alibabaCookieSource: AlibabaCookieSource = .auto
    @State private var alibabaManualCookieInput: String = ""
    @State private var alibabaApiKeyInput: String = ""
    @State private var showAlibabaApiKey: Bool = false
    @State private var isTestingAlibaba = false
    @State private var alibabaTestResult: String?

    private var dashboardURL: URL {
        alibabaRegion.dashboardURL
    }

    var body: some View {
        DisclosureGroup(isExpanded: $alibabaConfigExpanded) {
            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 12)

            alibabaConfigForm
        } label: {
            alibabaConfigHeader
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        alibabaConfigExpanded.toggle()
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
            alibabaRegion = settings.alibaba.alibabaRegion()
            alibabaCookieSource = settings.alibaba.alibabaCookieSource()
            alibabaManualCookieInput = settings.alibaba.getAlibabaManualCookie() ?? ""
        }
    }

    private var alibabaConfigHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.55, blue: 0.0),
                                Color(red: 0.9, green: 0.35, blue: 0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: "cloud.fill")
                    .font(theme.font(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Alibaba Configuration")
                    .font(theme.font(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text("Coding Plan quota tracking")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()
        }
    }

    private var alibabaConfigForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Region selector
            VStack(alignment: .leading, spacing: 6) {
                Text("REGION")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                Picker("", selection: $alibabaRegion) {
                    ForEach(AlibabaRegion.allCases, id: \.self) { region in
                        Text(region.displayName).tag(region)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: alibabaRegion) { _, newValue in
                    settings.alibaba.setAlibabaRegion(newValue)
                    Task {
                        await monitor.refresh(providerId: "alibaba")
                    }
                }
            }

            // Cookie source selector
            VStack(alignment: .leading, spacing: 6) {
                Text("COOKIE SOURCE")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                Picker("", selection: $alibabaCookieSource) {
                    ForEach(AlibabaCookieSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: alibabaCookieSource) { _, newValue in
                    settings.alibaba.setAlibabaCookieSource(newValue)
                }
            }

            // Manual cookie input (visible when cookieSource == .manual)
            if alibabaCookieSource == .manual {
                VStack(alignment: .leading, spacing: 6) {
                    Text("COOKIE STRING")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    TextField("", text: $alibabaManualCookieInput, prompt: Text("Paste cookie string...").foregroundStyle(theme.textTertiary))
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
                        .onChange(of: alibabaManualCookieInput) { _, newValue in
                            if !newValue.isEmpty {
                                settings.alibaba.saveAlibabaManualCookie(newValue)
                            }
                        }

                    Text("Copy the cookie from your browser's developer tools after logging in to Alibaba Cloud.")
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
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

                    if settings.alibaba.hasAlibabaApiKey() {
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
                        if showAlibabaApiKey {
                            TextField("", text: $alibabaApiKeyInput, prompt: Text("sk-...").foregroundStyle(theme.textTertiary))
                        } else {
                            SecureField("", text: $alibabaApiKeyInput, prompt: Text("sk-...").foregroundStyle(theme.textTertiary))
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
                        showAlibabaApiKey.toggle()
                    } label: {
                        Image(systemName: showAlibabaApiKey ? "eye.slash.fill" : "eye.fill")
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

            // Save & Test button
            if isTestingAlibaba {
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
                        await testAlibabaConnection()
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

            if let result = alibabaTestResult {
                Text(result)
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(result.contains("Success") ? theme.statusHealthy : theme.statusCritical)
            }

            // Dashboard link
            Link(destination: dashboardURL) {
                HStack(spacing: 3) {
                    Text("Open Alibaba Cloud Console")
                        .font(theme.font(size: 9, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(theme.font(size: 7, weight: .bold))
                }
                .foregroundStyle(theme.accentPrimary)
            }

            // Delete credentials
            if settings.alibaba.hasAlibabaApiKey() {
                Button {
                    settings.alibaba.deleteAlibabaApiKey()
                    alibabaApiKeyInput = ""
                    alibabaTestResult = nil
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

    private func testAlibabaConnection() async {
        isTestingAlibaba = true
        alibabaTestResult = nil

        // Save current inputs
        if !alibabaApiKeyInput.isEmpty {
            AppLog.credentials.info("Saving Alibaba API key for connection test")
            settings.alibaba.saveAlibabaApiKey(alibabaApiKeyInput)
            alibabaApiKeyInput = ""
        }
        if alibabaCookieSource == .manual && !alibabaManualCookieInput.isEmpty {
            settings.alibaba.saveAlibabaManualCookie(alibabaManualCookieInput)
        }

        AppLog.credentials.info("Testing Alibaba connection via provider refresh")
        await monitor.refresh(providerId: "alibaba")

        if let error = monitor.provider(for: "alibaba")?.lastError {
            AppLog.credentials.error("Alibaba connection test failed: \(error.localizedDescription)")
            alibabaTestResult = "Failed: \(error.localizedDescription)"
        } else {
            AppLog.credentials.info("Alibaba connection test succeeded")
            alibabaTestResult = "Success: Connection verified"
        }

        isTestingAlibaba = false
    }
}
