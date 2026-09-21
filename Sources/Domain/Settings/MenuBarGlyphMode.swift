import Foundation

/// What the menu-bar glyph shows.
///
/// Cortex = LLM only (Ben 2026-08-24): the glyph is a static stylized brain
/// whose tint reflects overall quota health. The cat animation stays RunCat's
/// job (CPU/system) — features are kept separate. Raw values remain "cat" /
/// "catAndText" so an existing `~/.claudebar/settings.json` still decodes.
public enum MenuBarGlyphMode: String, Sendable, CaseIterable, Identifiable {
    case text
    case brain = "cat"
    case brainAndText = "catAndText"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: return "Texte"
        case .brain: return "Cerveau"
        case .brainAndText: return "Cerveau + texte"
        }
    }

    /// Whether the brain glyph renders at all.
    public var showsBrain: Bool { self != .text }

    /// Whether the usage text renders next to the brain.
    public var showsText: Bool { self != .brain }

    /// SF Symbol for the settings choice chip.
    public var choiceIconName: String {
        switch self {
        case .text: return "textformat"
        case .brain: return "brain.fill"
        case .brainAndText: return "circle.grid.2x1.left.filled"
        }
    }
}
