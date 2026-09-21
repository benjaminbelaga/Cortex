import SwiftUI
import Domain
import Infrastructure

/// AWS Bedrock provider configuration card for SettingsView.
struct BedrockConfigCard: View {
    let monitor: QuotaMonitor

    @State private var settings = AppSettings.shared
    @Environment(\.appTheme) private var theme

    @State private var bedrockConfigExpanded: Bool = false
    @State private var awsProfileNameInput: String = ""
    @State private var bedrockRegionsInput: String = ""
    @State private var bedrockDailyBudgetInput: String = ""

    var body: some View {
        DisclosureGroup(isExpanded: $bedrockConfigExpanded) {
            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 14) {
                // AWS Profile Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("AWS PROFILE NAME")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    TextField("", text: $awsProfileNameInput, prompt: Text("default").foregroundStyle(theme.textTertiary))
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
                        .onChange(of: awsProfileNameInput) { _, newValue in
                            settings.bedrock.setAWSProfileName(newValue)
                        }
                }

                // Regions
                VStack(alignment: .leading, spacing: 6) {
                    Text("REGIONS (COMMA-SEPARATED)")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    TextField("", text: $bedrockRegionsInput, prompt: Text("us-east-1, us-west-2").foregroundStyle(theme.textTertiary))
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
                        .onChange(of: bedrockRegionsInput) { _, newValue in
                            let regions = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            settings.bedrock.setBedrockRegions(regions)
                        }
                }

                // Daily Budget
                VStack(alignment: .leading, spacing: 6) {
                    Text("DAILY BUDGET (USD, OPTIONAL)")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .tracking(0.5)

                    HStack(spacing: 6) {
                        Text("$")
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)

                        TextField("", text: $bedrockDailyBudgetInput, prompt: Text("50.00").foregroundStyle(theme.textTertiary))
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
                            .onChange(of: bedrockDailyBudgetInput) { _, newValue in
                                if newValue.isEmpty {
                                    settings.bedrock.setBedrockDailyBudget(nil)
                                } else if let value = Decimal(string: newValue) {
                                    settings.bedrock.setBedrockDailyBudget(value)
                                }
                            }
                    }
                }

                // Help text
                VStack(alignment: .leading, spacing: 4) {
                    Text("AWS credentials are loaded from your configured profile.")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)

                    Text("Configure with: aws configure --profile <name>")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }

                // Link to AWS console
                Link(destination: URL(string: "https://console.aws.amazon.com/bedrock/home")!) {
                    HStack(spacing: 3) {
                        Text("Open Bedrock Console")
                            .font(theme.font(size: 9, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(theme.font(size: 7, weight: .bold))
                    }
                    .foregroundStyle(theme.accentPrimary)
                }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.6, blue: 0.0),
                                    Color(red: 0.9, green: 0.45, blue: 0.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)

                    Image(systemName: "mountain.2.fill")
                        .font(theme.font(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("AWS Bedrock Configuration")
                        .font(theme.font(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)

                    Text("CloudWatch usage tracking")
                        .font(theme.font(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()
            }
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    bedrockConfigExpanded.toggle()
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
            awsProfileNameInput = settings.bedrock.awsProfileName()
            bedrockRegionsInput = settings.bedrock.bedrockRegions().joined(separator: ", ")
            if let budget = settings.bedrock.bedrockDailyBudget() {
                bedrockDailyBudgetInput = String(describing: budget)
            }
        }
    }
}
