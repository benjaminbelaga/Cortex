import SwiftUI

// MARK: - Dark Theme

/// The default dark theme with purple-pink gradients and glassmorphism.
public struct DarkTheme: AppThemeProvider {
    // MARK: - Identity

    public let id = "dark"
    public let displayName = "Dark"
    public let icon = "moon.stars.fill"

    // MARK: - Background

    public var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.08, blue: 0.22),
                Color(red: 0.18, green: 0.10, blue: 0.28),
                Color(red: 0.22, green: 0.12, blue: 0.32)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var showBackgroundOrbs: Bool { true }

    // MARK: - Cards & Glass

    public var cardGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.18),
                Color.white.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var glassBackground: Color {
        Color.white.opacity(0.12)
    }

    public var glassBorder: Color {
        Color.white.opacity(0.25)
    }

    public var glassHighlight: Color {
        Color.white.opacity(0.35)
    }

    public var cardCornerRadius: CGFloat { 14 }
    public var pillCornerRadius: CGFloat { 20 }

    // MARK: - Typography

    public var textPrimary: Color {
        Color.white.opacity(0.95)
    }

    public var textSecondary: Color {
        Color.white.opacity(0.70)
    }

    public var textTertiary: Color {
        Color.white.opacity(0.50)
    }

    public var fontDesign: Font.Design { .rounded }

    // MARK: - Status Colors

    public var statusHealthy: Color { BaseTheme.defaultStatusHealthy }
    public var statusWarning: Color { BaseTheme.defaultStatusWarning }
    public var statusCritical: Color { BaseTheme.defaultStatusCritical }
    public var statusDepleted: Color { BaseTheme.defaultStatusDepleted }

    // MARK: - Accents

    public var accentPrimary: Color { BaseTheme.pinkHot }
    public var accentSecondary: Color { BaseTheme.purpleVibrant }

    public var accentGradient: LinearGradient {
        LinearGradient(
            colors: [BaseTheme.coralAccent, BaseTheme.pinkHot],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var pillGradient: LinearGradient {
        LinearGradient(
            colors: [
                BaseTheme.purpleVibrant.opacity(0.6),
                BaseTheme.pinkHot.opacity(0.4)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var shareGradient: LinearGradient {
        LinearGradient(
            colors: [BaseTheme.goldenGlow, BaseTheme.coralAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Interactive States

    public var hoverOverlay: Color {
        Color.white.opacity(0.08)
    }

    public var pressedOverlay: Color {
        Color.white.opacity(0.12)
    }

    // MARK: - Progress Bar

    public var progressTrack: Color {
        Color.white.opacity(0.15)
    }

    // MARK: - Initializer

    public init() {}
}
