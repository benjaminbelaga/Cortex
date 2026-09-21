import SwiftUI
import Infrastructure
import UniformTypeIdentifiers

/// Import button for terminal color scheme files.
///
/// **Primary action:** One-click sync from the active iTerm2 profile (reads preferences directly).
/// **Fallback:** File picker for `.itermcolors` files (for manual import or non-iTerm2 users).
struct ThemeImportButton: View {
    @Environment(\.appTheme) private var theme
    @State private var settings = AppSettings.shared
    @State private var isImporting = false
    @State private var importError: String?
    @State private var importedThemeName: String?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Primary: one-click sync from iTerm2
                Button {
                    syncFromITerm()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Sync from iTerm2")
                            .font(theme.font(size: 11, weight: .medium))
                    }
                    .foregroundStyle(theme.accentPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentPrimary.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.accentPrimary.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                // Secondary: file picker fallback
                Button {
                    isImporting = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 10, weight: .medium))
                        Text("File")
                            .font(theme.font(size: 10, weight: .medium))
                    }
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.glassBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: [UTType(filenameExtension: "itermcolors") ?? .propertyList],
                    allowsMultipleSelection: false
                ) { result in
                    handleFileImport(result)
                }
            }

            if let error = importError {
                Text(error)
                    .font(theme.font(size: 9))
                    .foregroundStyle(theme.statusCritical)
            }

            if let name = importedThemeName {
                Text("Synced: \(name)")
                    .font(theme.font(size: 9))
                    .foregroundStyle(theme.statusHealthy)
            }
        }
    }

    // MARK: - One-Click Sync

    @MainActor private func syncFromITerm() {
        importError = nil
        importedThemeName = nil

        do {
            let scheme = try ITermProfileReader.readActiveProfile()
            guard scheme.isValid else {
                importError = "Invalid scheme: \(scheme.ansiColors.count) ANSI colors (need 16)"
                return
            }
            let imported = try ThemeRegistry.shared.importScheme(scheme)
            importedThemeName = scheme.name
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                settings.themeMode = imported.id
            }
        } catch ITermProfileReader.ReadError.notInstalled {
            importError = "iTerm2 not found"
        } catch ITermProfileReader.ReadError.noProfiles {
            importError = "No iTerm2 profiles found"
        } catch ITermProfileReader.ReadError.profileNotFound {
            importError = "Default profile not found"
        } catch ITermProfileReader.ReadError.missingColors(let key) {
            importError = "Missing color: \(key)"
        } catch {
            importError = "Sync failed: \(error)"
        }
    }

    // MARK: - File Import Fallback

    @MainActor private func handleFileImport(_ result: Result<[URL], Error>) {
        importError = nil
        importedThemeName = nil

        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Cannot access file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let imported = try ThemeRegistry.shared.importItermcolors(from: url)
                importedThemeName = imported.displayName
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    settings.themeMode = imported.id
                }
            } catch {
                importError = "Import failed: \(error.localizedDescription)"
            }

        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}
