import SwiftUI
import Domain
import Infrastructure

/// Appearance pane: theme selection and custom theme import.
struct AppearancePane: View {
    @Environment(\.appTheme) private var theme
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsPane(
            title: "Appearance",
            subtitle: "Themes apply across the popover, menu bar, and this window."
        ) {
            SettingsCard {
                SettingsFieldLabel(text: "THEME")
                    .padding(.bottom, 10)

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 10) {
                    ForEach(ThemeRegistry.shared.allThemes, id: \.id) { registeredTheme in
                        ThemeOptionButton(
                            themeProvider: registeredTheme,
                            isSelected: settings.themeMode == registeredTheme.id
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                settings.themeMode = registeredTheme.id
                            }
                        }
                    }
                }

                ThemeImportButton()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
    }
}
