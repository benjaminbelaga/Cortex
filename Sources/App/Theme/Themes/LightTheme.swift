import SwiftUI

// MARK: - Light Theme

/// Light theme with soft purple-pink tones optimized for bright environments.
public struct LightTheme: AppThemeProvider {
    // MARK: - Identity

    public let id = "light"
    public let displayName = "Light"
    public let icon = "sun.max.fill"

    // MARK: - Background

    public var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.96, blue: 1.0),
                Color(red: 0.96, green: 0.94, blue: 0.99),
                Color(red: 0.94, green: 0.92, blue: 0.98)
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
                Color.white.opacity(0.95),
                Color.white.opacity(0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var glassBackground: Color {
        Color.white.opacity(0.8)
    }

    public var glassBorder: Color {
        BaseTheme.purpleVibrant.opacity(0.15)
    }

    public var glassHighlight: Color {
        Color.white.opacity(0.9)
    }

    public var cardCornerRadius: CGFloat { 14 }
    public var pillCornerRadius: CGFloat { 20 }

    // MARK: - Typography

    public var textPrimary: Color {
        Color(red: 0.15, green: 0.12, blue: 0.22)
    }

    public var textSecondary: Color {
        Color(red: 0.35, green: 0.32, blue: 0.42)
    }

    public var textTertiary: Color {
        Color(red: 0.55, green: 0.52, blue: 0.62)
    }

    public var fontDesign: Font.Design { .rounded }

    // MARK: - Status Colors (richer for light mode)

    public var statusHealthy: Color {
        Color(red: 0.22, green: 0.78, blue: 0.55)
    }

    public var statusWarning: Color {
        Color(red: 0.92, green: 0.62, blue: 0.22)
    }

    public var statusCritical: Color {
        Color(red: 0.92, green: 0.32, blue: 0.42)
    }

    public var statusDepleted: Color {
        Color(red: 0.72, green: 0.18, blue: 0.28)
    }

    // MARK: - Accents (more saturated for light mode)

    public var accentPrimary: Color {
        Color(red: 0.72, green: 0.25, blue: 0.55)
    }

    public var accentSecondary: Color {
        Color(red: 0.45, green: 0.22, blue: 0.75)
    }

    public var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.92, green: 0.45, blue: 0.38),
                Color(red: 0.78, green: 0.28, blue: 0.58)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var pillGradient: LinearGradient {
        LinearGradient(
            colors: [
                accentSecondary.opacity(0.5),
                accentPrimary.opacity(0.3)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var shareGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.92, green: 0.72, blue: 0.28),
                Color(red: 0.88, green: 0.52, blue: 0.35)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Interactive States

    public var hoverOverlay: Color {
        BaseTheme.purpleDeep.opacity(0.08)
    }

    public var pressedOverlay: Color {
        BaseTheme.purpleDeep.opacity(0.15)
    }

    // MARK: - Progress Bar

    public var progressTrack: Color {
        BaseTheme.purpleDeep.opacity(0.1)
    }

    // MARK: - Initializer

    public init() {}
}
