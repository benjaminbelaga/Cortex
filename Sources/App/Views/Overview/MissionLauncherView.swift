import AppKit
import Infrastructure
import SwiftUI

struct MissionLauncherView: View {
    var onClose: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var mission = ""
    @State private var repoPath = ""
    @State private var load: MissionLoad = .light
    @State private var suggestion: MissionSuggestion?
    @State private var isSuggesting = false
    @State private var expandedCandidate: String?
    @State private var feedback: String?
    @State private var errorMessage: String?
    @FocusState private var missionFocused: Bool

    private let client = LLMRouterSuggestionClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Nouvelle mission", systemImage: "sparkles")
                    .font(theme.font(size: 12, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(theme.font(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
            }

            TextField("What do you want to launch?", text: $mission)
                .textFieldStyle(.roundedBorder)
                .focused($missionFocused)
                .onSubmit { requestSuggestion() }

            HStack(spacing: 6) {
                TextField("Repo Git", text: $repoPath)
                    .textFieldStyle(.roundedBorder)
                Button(action: chooseRepository) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                loadChip(.light, label: "Light", icon: "bolt")
                loadChip(.heavy, label: "Lourde", icon: "brain.head.profile")
                Spacer()
                Button {
                    requestSuggestion()
                } label: {
                    if isSuggesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Proposer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSuggesting || mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.statusWarning)
            }

            if let suggestion {
                VStack(spacing: 7) {
                    decisionProofLine(suggestion)
                    ForEach(Array(suggestion.candidates.enumerated()), id: \.element.id) { index, candidate in
                        candidateCard(candidate, recommended: index == 0)
                    }
                    if let wait = suggestion.waitSuggestion {
                        waitLine(wait)
                    }
                    if !suggestion.ineligible.isEmpty {
                        ineligibleList(suggestion.ineligible)
                    }
                }
            }

            if let feedback {
                Text(feedback)
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .glassCard(cornerRadius: 12, padding: 12)
        .onAppear { missionFocused = true }
    }

    private func loadChip(_ value: MissionLoad, label: String, icon: String) -> some View {
        Button {
            load = value
        } label: {
            Label(label, systemImage: icon)
                .font(theme.font(size: 9, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(load == value ? theme.accentPrimary.opacity(0.25) : theme.glassBackground))
        }
        .buttonStyle(.plain)
    }

    private func candidateCard(_ candidate: MissionCandidate, recommended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(candidate.provider)
                            .font(theme.font(size: 10, weight: .bold))
                        if recommended {
                            Text("RECOMMENDED")
                                .font(theme.font(size: 7, weight: .bold))
                                .foregroundStyle(theme.accentPrimary)
                        }
                        if let multiplier = candidate.timeMultiplier, multiplier < 1 {
                            Text("DISCOUNT ×\(multiplier, specifier: "%g")")
                                .font(theme.font(size: 7, weight: .bold))
                                .foregroundStyle(theme.statusHealthy)
                        }
                    }
                    Text(candidateRouteDetail(candidate))
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    Text(candidateProofDetail(candidate))
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(proofColor(candidate))
                }
                Spacer()
                if let headroom = candidate.quotaHeadroomPercent {
                    Text("\(Int(headroom.rounded()))%")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                Button("Lancer") {
                    launch(candidate)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button(expandedCandidate == candidate.id ? "Hide why" : "Pourquoi") {
                expandedCandidate = expandedCandidate == candidate.id ? nil : candidate.id
            }
            .buttonStyle(.plain)
            .font(theme.font(size: 9, weight: .semibold))
            .foregroundStyle(theme.accentPrimary)

            if expandedCandidate == candidate.id {
                ForEach(Array(candidate.reasons.prefix(4).enumerated()), id: \.offset) { _, reason in
                    Text("• \(reason)")
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(candidate.penalties.enumerated()), id: \.offset) { _, penalty in
                    Text("⚠ \(penalty)")
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.glassBackground))
    }

    /// Which route this really is: model + selected account + effort. Two
    /// accounts on the same model must not look like one route (audit V2 §3).
    private func candidateRouteDetail(_ candidate: MissionCandidate) -> String {
        [candidate.model, candidate.account?.label, candidate.effort]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Where the quota behind the decision comes from and how old it is. A
    /// missing age prints as unknown — never as a reassuring zero (audit V2 §3).
    private func candidateProofDetail(_ candidate: MissionCandidate) -> String {
        let source = candidate.statusSource ?? "source inconnue"
        guard let age = candidate.statusAgeMinutes else { return "\(source) · âge du quota inconnu" }
        return "\(source) · quota il y a \(Int(age.rounded())) min"
    }

    private func proofColor(_ candidate: MissionCandidate) -> Color {
        guard let age = candidate.statusAgeMinutes else { return theme.textTertiary }
        return age > 20 ? theme.statusWarning : theme.textTertiary
    }

    /// Age of the decision itself, plus the privacy scope it was taken under.
    private func decisionProofLine(_ suggestion: MissionSuggestion) -> some View {
        HStack(spacing: 6) {
            if let generatedAt = suggestion.generatedAt {
                Text("décision")
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Text(generatedAt, style: .relative)
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            if let privacy = suggestion.privacy, !privacy.isEmpty {
                Text("· \(privacy)")
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            if let context = suggestion.contextEstimate, context > 0 {
                Text("· ≈\(context / 1000)k tokens")
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
        }
    }

    /// The engine's own "wait for this window" advice — displayed, never acted on.
    private func waitLine(_ wait: MissionWaitSuggestion) -> some View {
        Text("Créneau favorable : \(wait.provider) \(wait.model)"
            + (wait.opensInMinutes.map { " dans \($0) min" } ?? "")
            + (wait.opensAtDisplay.map { " (\($0))" } ?? "")
            + (wait.multiplier.map { " ×\($0)" } ?? ""))
            .font(theme.font(size: 9, weight: .medium))
            .foregroundStyle(theme.statusHealthy)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Routes the engine rejected, with its reasons (audit V2 §12).
    private func ineligibleList(_ routes: [MissionIneligibleRoute]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Écartées")
                .font(theme.font(size: 8, weight: .bold))
                .foregroundStyle(theme.textTertiary)
            ForEach(Array(routes.prefix(4).enumerated()), id: \.offset) { _, route in
                Text("· \(route.provider) — \(route.reasons.joined(separator: " ; "))")
                    .font(theme.font(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func requestSuggestion() {
        let prompt = mission.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSuggesting else { return }
        isSuggesting = true
        errorMessage = nil
        feedback = nil
        Task {
            do {
                suggestion = try await client.suggest(mission: prompt, load: load)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSuggesting = false
        }
    }

    private func launch(_ candidate: MissionCandidate) {
        feedback = "Ouverture…"
        Task {
            let result = await MissionSessionLauncher.launch(
                candidate: candidate,
                mission: mission,
                repoPath: repoPath
            )
            feedback = result.message
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("repos")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repoPath = url.path
    }
}
