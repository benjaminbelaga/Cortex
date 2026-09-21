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

            TextField("Que veux-tu lancer ?", text: $mission)
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
                loadChip(.light, label: "Légère", icon: "bolt")
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
                    ForEach(Array(suggestion.candidates.enumerated()), id: \.element.id) { index, candidate in
                        candidateCard(candidate, recommended: index == 0)
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
                            Text("RECOMMANDÉ")
                                .font(theme.font(size: 7, weight: .bold))
                                .foregroundStyle(theme.accentPrimary)
                        }
                    }
                    Text(candidate.model)
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
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

            Button(expandedCandidate == candidate.id ? "Masquer pourquoi" : "Pourquoi") {
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
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.glassBackground))
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
