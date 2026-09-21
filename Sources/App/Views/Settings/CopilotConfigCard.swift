import SwiftUI
import Domain
import Infrastructure

/// GitHub Copilot provider configuration card for SettingsView.
struct CopilotConfigCard: View {
    let monitor: QuotaMonitor

    @State private var settings = AppSettings.shared
    @Environment(\.appTheme) private var theme

    // Token input state
    @State private var copilotTokenInput: String = ""
    @State private var showToken: Bool = false
    @State private var saveError: String?
    @State private var saveSuccess: Bool = false
    @State private var copilotIsExpanded: Bool = false
    @State private var copilotAuthEnvVarInput: String = ""
    @State private var copilotMonthlyLimit: Int = 50
    @State private var copilotManualOverrideEnabled: Bool = false
    @State private var copilotManualUsageInput: String = ""
    @State private var copilotManualUsageInputError: String?
    @State private var copilotApiReturnedEmpty: Bool = false
    @State private var copilotProbeMode: CopilotProbeMode = .billing
    @State private var isTestingCopilot = false
    @State private var copilotTestResult: String?

    private var copilotProvider: CopilotProvider? {
        monitor.provider(for: "copilot") as? CopilotProvider
    }

    private var copilotUsernameBinding: Binding<String> {
        Binding(
            get: { copilotProvider?.username ?? "" },
            set: { newValue in copilotProvider?.username = newValue }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $copilotIsExpanded) {
            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 12)

            copilotForm
        } label: {
            copilotHeader
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copilotIsExpanded.toggle()
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
            copilotProbeMode = settings.copilot.copilotProbeMode()
            copilotAuthEnvVarInput = settings.copilot.copilotAuthEnvVar()
            copilotMonthlyLimit = settings.copilot.copilotMonthlyLimit() ?? 50
            copilotManualOverrideEnabled = settings.copilot.copilotManualOverrideEnabled()
            copilotApiReturnedEmpty = settings.copilot.copilotApiReturnedEmpty()
            if let value = settings.copilot.copilotManualUsageValue() {
                let isPercent = settings.copilot.copilotManualUsageIsPercent()
                if isPercent {
                    copilotManualUsageInput = String(Int(value)) + "%"
                } else {
                    copilotManualUsageInput = String(Int(value))
                }
            }
        }
    }

    private var copilotHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.38, green: 0.55, blue: 0.93),
                                Color(red: 0.55, green: 0.40, blue: 0.90)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(theme.font(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub Copilot Configuration")
                    .font(theme.font(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text("AI credits usage tracking")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()
        }
    }

    private var copilotForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Probe Mode Picker
            VStack(alignment: .leading, spacing: 6) {
                Text("PROBE MODE")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                Picker("", selection: $copilotProbeMode) {
                    ForEach(CopilotProbeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: copilotProbeMode) { _, newValue in
                    settings.copilot.setCopilotProbeMode(newValue)
                    AppLog.probes.info("Copilot probe mode changed to \(newValue.rawValue)")
                    Task {
                        await monitor.refresh(providerId: "copilot")
                    }
                }
            }

            // Mode descriptions
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "creditcard")
                        .font(theme.font(size: 10))
                        .foregroundStyle(copilotProbeMode == .billing ? theme.accentPrimary : theme.textTertiary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Billing Mode")
                            .font(theme.font(size: 10, weight: .semibold))
                            .foregroundStyle(copilotProbeMode == .billing ? theme.textPrimary : theme.textSecondary)

                        Text("Uses GitHub Billing API. Requires fine-grained PAT with 'Plan: read'.")
                            .font(theme.font(size: 9, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "network")
                        .font(theme.font(size: 10))
                        .foregroundStyle(copilotProbeMode == .copilotAPI ? theme.accentPrimary : theme.textTertiary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copilot API Mode")
                            .font(theme.font(size: 10, weight: .semibold))
                            .foregroundStyle(copilotProbeMode == .copilotAPI ? theme.textPrimary : theme.textSecondary)

                        Text("Uses Copilot Internal API. Works for all plans (incl. Business/Enterprise). Requires Classic PAT with 'copilot' scope.")
                            .font(theme.font(size: 9, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            // Billing mode specific fields
            if copilotProbeMode == .billing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GITHUB USERNAME")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    TextField("", text: copilotUsernameBinding, prompt: Text("username").foregroundStyle(theme.textTertiary))
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
                }
            }

            // Personal Access Token
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PERSONAL ACCESS TOKEN")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    Spacer()

                    if copilotProvider?.hasToken == true {
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
                        if showToken {
                            TextField("", text: $copilotTokenInput, prompt: Text("ghp_xxxx...").foregroundStyle(theme.textTertiary))
                        } else {
                            SecureField("", text: $copilotTokenInput, prompt: Text("ghp_xxxx...").foregroundStyle(theme.textTertiary))
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
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash.fill" : "eye.fill")
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

                if let error = saveError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(theme.font(size: 9))
                        Text(error)
                            .font(theme.font(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(theme.statusCritical)
                } else if saveSuccess {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(theme.font(size: 9))
                        Text("Token saved!")
                            .font(theme.font(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(theme.statusHealthy)
                }
            }

            // Environment Variable
            VStack(alignment: .leading, spacing: 6) {
                Text("AUTH TOKEN ENV VAR (ALTERNATIVE)")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                TextField("", text: $copilotAuthEnvVarInput, prompt: Text("GITHUB_TOKEN").foregroundStyle(theme.textTertiary))
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
                    .onChange(of: copilotAuthEnvVarInput) { _, newValue in
                        settings.copilot.setCopilotAuthEnvVar(newValue)
                    }
            }

            // Billing mode specific fields
            if copilotProbeMode == .billing {
                // Monthly Limit
                VStack(alignment: .leading, spacing: 6) {
                    Text("MONTHLY AI CREDITS LIMIT")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    Picker("", selection: $copilotMonthlyLimit) {
                        Text("Free/Pro (50)").tag(50)
                        Text("Business (300)").tag(300)
                        Text("Enterprise (1000)").tag(1000)
                        Text("Pro+ (1500)").tag(1500)
                    }
                    .pickerStyle(.menu)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.glassBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.glassBorder, lineWidth: 1)
                            )
                    )
                    .onChange(of: copilotMonthlyLimit) { _, newValue in
                        settings.copilot.setCopilotMonthlyLimit(newValue)
                    }

                    Text("Note: This is for AI credits, not code completions")
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }

                // Warning banner for org-based subscriptions
                if copilotApiReturnedEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(theme.font(size: 10))
                                .foregroundStyle(theme.statusWarning)
                            Text("API returned no usage data")
                                .font(theme.font(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                        }

                        Text("This is common for Copilot Business subscriptions. Try switching to Copilot API mode.")
                            .font(theme.font(size: 9, weight: .medium))
                            .foregroundStyle(theme.textSecondary)

                        Link(destination: URL(string: "https://github.com/settings/copilot/features")!) {
                            HStack(spacing: 4) {
                                Text("View usage on GitHub")
                                    .font(theme.font(size: 9, weight: .semibold))
                                Image(systemName: "arrow.up.right")
                                    .font(theme.font(size: 8))
                            }
                            .foregroundStyle(theme.accentPrimary)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.statusWarning.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.statusWarning.opacity(0.3), lineWidth: 1)
                            )
                    )
                }

                // Manual override toggle
                Toggle("Enable manual usage entry", isOn: $copilotManualOverrideEnabled)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .toggleStyle(.switch)
                    .onChange(of: copilotManualOverrideEnabled) { _, newValue in
                        settings.copilot.setCopilotManualOverrideEnabled(newValue)
                    }

                // Manual usage input
                if copilotManualOverrideEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CURRENT AI CREDITS USAGE")
                            .font(theme.font(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .tracking(0.5)

                        TextField("", text: $copilotManualUsageInput, prompt: Text("99 or 198%").foregroundStyle(theme.textTertiary))
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.glassBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                copilotManualUsageInputError != nil ? Color.red.opacity(0.6) : theme.glassBorder,
                                                lineWidth: copilotManualUsageInputError != nil ? 1.5 : 1
                                            )
                                    )
                            )
                            .onChange(of: copilotManualUsageInput) { _, newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespaces)

                                if trimmed.isEmpty {
                                    copilotManualUsageInputError = nil
                                    settings.copilot.setCopilotManualUsageValue(nil)
                                } else if trimmed.hasSuffix("%") {
                                    let numberPart = trimmed.dropLast()
                                    if let intValue = Int(numberPart), intValue >= 0 {
                                        copilotManualUsageInputError = nil
                                        settings.copilot.setCopilotManualUsageValue(Double(intValue))
                                        settings.copilot.setCopilotManualUsageIsPercent(true)
                                    } else {
                                        copilotManualUsageInputError = "Enter a valid number (e.g., 198%)"
                                        settings.copilot.setCopilotManualUsageValue(nil)
                                    }
                                } else if let intValue = Int(trimmed), intValue >= 0 {
                                    copilotManualUsageInputError = nil
                                    settings.copilot.setCopilotManualUsageValue(Double(intValue))
                                    settings.copilot.setCopilotManualUsageIsPercent(false)
                                } else {
                                    copilotManualUsageInputError = "Enter a whole number or percentage"
                                    settings.copilot.setCopilotManualUsageValue(nil)
                                }
                            }

                        if let error = copilotManualUsageInputError {
                            Text(error)
                                .font(theme.font(size: 9, weight: .medium))
                                .foregroundStyle(.red)
                        } else {
                            Text("Enter AI credits used (e.g., 99) or percentage (e.g., 198%)")
                                .font(theme.font(size: 9, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }

            // Token lookup order
            VStack(alignment: .leading, spacing: 4) {
                Text("TOKEN LOOKUP ORDER")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                Text("1. First checks environment variable if specified")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Text("2. Falls back to direct token entry above")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

            // Save & Test button
            if isTestingCopilot {
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
                        await testCopilotConnection()
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

            if let result = copilotTestResult {
                Text(result)
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(result.contains("Success") ? theme.statusHealthy : theme.statusCritical)
            }

            // Help text and link
            VStack(alignment: .leading, spacing: 4) {
                if copilotProbeMode == .billing {
                    Text("Create a fine-grained PAT with 'Plan: read' permission")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)

                    Link(destination: URL(string: "https://github.com/settings/tokens?type=beta")!) {
                        HStack(spacing: 3) {
                            Text("Create fine-grained token")
                                .font(theme.font(size: 9, weight: .semibold))
                            Image(systemName: "arrow.up.right")
                                .font(theme.font(size: 7, weight: .bold))
                        }
                        .foregroundStyle(theme.accentPrimary)
                    }
                } else {
                    Text("Create a Classic PAT with 'copilot' scope")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)

                    Link(destination: URL(string: "https://github.com/settings/tokens/new")!) {
                        HStack(spacing: 3) {
                            Text("Create classic token")
                                .font(theme.font(size: 9, weight: .semibold))
                            Image(systemName: "arrow.up.right")
                                .font(theme.font(size: 7, weight: .bold))
                        }
                        .foregroundStyle(theme.accentPrimary)
                    }
                }
            }

            // Delete token
            if copilotProvider?.hasToken == true {
                Button {
                    deleteToken()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(theme.font(size: 9))
                        Text("Remove Token")
                            .font(theme.font(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(theme.statusCritical)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func saveToken() {
        saveError = nil
        saveSuccess = false

        copilotProvider?.saveToken(copilotTokenInput)
        copilotTokenInput = ""
        saveSuccess = true

        if let provider = copilotProvider, provider.isEnabled {
            Task {
                try? await provider.refresh()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            saveSuccess = false
        }
    }

    private func deleteToken() {
        copilotProvider?.deleteCredentials()
        saveError = nil
    }

    private func testCopilotConnection() async {
        isTestingCopilot = true
        copilotTestResult = nil

        settings.copilot.setCopilotAuthEnvVar(copilotAuthEnvVarInput)
        if !copilotTokenInput.isEmpty {
            AppLog.credentials.info("Saving Copilot token for connection test")
            copilotProvider?.saveToken(copilotTokenInput)
            copilotTokenInput = ""
        }

        AppLog.credentials.info("Testing Copilot connection via provider refresh")
        await monitor.refresh(providerId: "copilot")

        if let error = monitor.provider(for: "copilot")?.lastError {
            AppLog.credentials.error("Copilot connection test failed: \(error.localizedDescription)")
            copilotTestResult = "Failed: \(error.localizedDescription)"
        } else {
            AppLog.credentials.info("Copilot connection test succeeded")
            copilotTestResult = "Success: Connection verified"
        }

        copilotApiReturnedEmpty = settings.copilot.copilotApiReturnedEmpty()
        isTestingCopilot = false
    }
}
