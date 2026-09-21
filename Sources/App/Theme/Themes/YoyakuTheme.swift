import Domain
import SwiftUI

// MARK: - Yoyaku Theme

/// Dark terminal theme matching Benjamin's iTerm2 "Default" profile dark mode exactly.
/// Colors extracted from com.googlecode.iterm2.plist (Dark Mode variants).
/// Font: CaskaydiaCoveNFM-Regular (Caskaydia Cove Nerd Font Mono)
public struct YoyakuTheme: AppThemeProvider {
    // MARK: - Identity

    public let id = "yoyaku"
    public let displayName = "Yoyaku"
    public let icon = "brain.fill"
    public let subtitle: String? = "Terminal"
    public let statusBarIconName: String? = "brain.fill"
    public var customFontName: String? { "IBMPlexMono" }

    // MARK: - iTerm2 Dark Mode Color Palette (exact values from plist (Dark) keys)

    // Backgrounds
    static let bgDark      = Color(red: 0.1128, green: 0.1475, blue: 0.1661)  // #1C252A
    static let bgCard      = Color(red: 0.17,   green: 0.21,   blue: 0.23)    // #2B353B
    static let bgSelection = Color(red: 0.3066, green: 0.4146, blue: 0.4710)  // #4E6978 (Selection BG)

    // Foreground / Text
    static let fg      = Color(red: 0.9073, green: 0.9214, blue: 0.9312)  // #E7EAED
    static let fgBold  = Color(red: 0.9165, green: 0.9167, blue: 0.9165)  // #E9E9E9
    static let fgDim   = Color(red: 0.6306, green: 0.6917, blue: 0.7232)  // #A0B0B8 (Br.Black)

    // ANSI Colors — exact iTerm2 dark mode values
    static let cyan        = Color(red: 0.3486, green: 1.0000, blue: 0.8206)  // #58FFD1 (ANSI Cyan)
    static let cyanBright  = Color(red: 0.6029, green: 1.0000, blue: 0.9018)  // #99FFE5 (Br.Cyan)
    static let red         = Color(red: 0.9871, green: 0.2210, blue: 0.2558)  // #FB3841 (ANSI Red)
    static let redBright   = Color(red: 0.9896, green: 0.4531, blue: 0.4282)  // #FC736D (Br.Red)
    static let magenta     = Color(red: 0.9865, green: 0.1331, blue: 0.4318)  // #FB216E (ANSI Magenta)
    static let yellow      = Color(red: 0.9963, green: 0.8167, blue: 0.1973)  // #FED032 (ANSI Yellow)
    static let yellowBrg   = Color(red: 0.9977, green: 0.8826, blue: 0.4251)  // #FEE16C (Br.Yellow)
    static let blue        = Color(red: 0.2151, green: 0.7150, blue: 0.9987)  // #36B6FE (ANSI Blue)
    static let blueBright  = Color(red: 0.4388, green: 0.8107, blue: 0.9990)  // #6FCEFE (Br.Blue)
    static let green       = Color(red: 0.3620, green: 0.9439, blue: 0.6204)  // #5CF09E (ANSI Green)
    static let black       = Color(red: 0.2629, green: 0.3562, blue: 0.4025)  // #435A66 (ANSI Black)

    // MARK: - Background

    public var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Self.bgDark, Self.bgDark],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var showBackgroundOrbs: Bool { false }

    // MARK: - Cards & Glass

    public static let cardGradientValue = LinearGradient(
        colors: [bgCard.opacity(0.9), bgCard.opacity(0.7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public var cardGradient: LinearGradient { Self.cardGradientValue }
    public var glassBackground: Color { Self.bgCard.opacity(0.8) }
    public var glassBorder: Color { Self.black.opacity(0.6) }
    public var glassHighlight: Color { Self.cyan.opacity(0.12) }
    public var cardCornerRadius: CGFloat { 10 }
    public var pillCornerRadius: CGFloat { 12 }

    // MARK: - Typography

    public var textPrimary: Color { Self.fgBold }
    public var textSecondary: Color { Self.fg }
    public var textTertiary: Color { Self.fgDim }
    public var fontDesign: Font.Design { .monospaced }

    // MARK: - Status Colors

    public var statusHealthy: Color { Self.cyan }
    public var statusWarning: Color { Self.yellow }
    public var statusCritical: Color { Self.red }
    public var statusDepleted: Color { Self.redBright.opacity(0.7) }

    // MARK: - Accents

    public var accentPrimary: Color { Self.cyan }
    public var accentSecondary: Color { Self.cyanBright }

    public var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Self.cyan, Self.blue],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    public var pillGradient: LinearGradient {
        LinearGradient(
            colors: [
                Self.cyan.opacity(0.20),
                Self.blue.opacity(0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var shareGradient: LinearGradient {
        LinearGradient(
            colors: [Self.yellow, Self.yellowBrg],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Interactive States

    public var hoverOverlay: Color { Self.cyan.opacity(0.10) }
    public var pressedOverlay: Color { Self.cyan.opacity(0.16) }

    // MARK: - Progress Bar

    public var progressTrack: Color { Self.bgSelection }

    // MARK: - Custom Progress Gradient

    public func progressGradient(for percent: Double) -> LinearGradient {
        let colors: [Color] = switch percent {
        case 0..<20: [Self.red, Self.redBright]
        case 20..<50: [Self.yellow, Self.yellowBrg]
        default: [Self.cyan, Self.cyanBright]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Status Icons (ANSI-flavored SF Symbols)

    /// YoyakuTheme overrides the default status icons with an ANSI-styled set:
    /// filled circles for healthy, triangles for warning, octagons for
    /// critical/depleted. The geometry reads as "low → high alert" on a
    /// terminal aesthetic, matching the ANSI color palette above.
    public func statusIcon(for status: QuotaStatus) -> String {
        switch status {
        case .healthy: "circle.fill"
        case .warning: "triangle.fill"
        case .critical: "exclamationmark.triangle.fill"
        case .depleted: "xmark.octagon.fill"
        }
    }

    // MARK: - Initializer

    public init() {}
}
