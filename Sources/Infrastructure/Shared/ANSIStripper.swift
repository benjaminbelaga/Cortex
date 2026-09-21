import Foundation

/// Strips ANSI escape sequences from raw terminal output.
///
/// The Claude CLI emits cursor-positioning sequences (CSI), OS commands (OSC)
/// and single-character escapes while drawing its TUI. Left in place, they can
/// leak into logs and, when a screen render fails or a prompt is on screen,
/// into parsed fields. `TerminalRenderer` interprets these sequences; this
/// stripper removes them up front so downstream parsing and logging operate on
/// plain text regardless of renderer state.
public enum ANSIStripper {

    /// CSI sequences: ESC [ <params> <final byte> — e.g. `ESC[3G` (column 3).
    private static let csiPattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"

    /// Cursor-POSITION CSI sequences (final bytes G H f A B C D d ` and
    /// relative movers). Removing them outright would concatenate the words
    /// they separated ("Claude[10Gin" → "Claudein"), so they are replaced by
    /// a single space instead.
    private static let csiPositionPattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-`GHDdf]"

    /// OSC sequences: ESC ] <payload> (BEL | ESC \) — e.g. window titles.
    private static let oscPattern = "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"

    /// Two-character escapes: ESC followed by a single final byte (no bracket).
    private static let shortEscapePattern = "\u{1B}[@-Z\\-_]"

    /// Remaining C0 control characters except tab, newline and carriage return.
    private static let controlPattern = "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1A\\x1C-\\x1F]"

    private static let positionRegex: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(pattern: csiPositionPattern) else {
            fatalError("ANSIStripper: invalid position pattern")
        }
        return regex
    }()

    private static let combined: NSRegularExpression = {
        let pattern = "\(csiPattern)|\(oscPattern)|\(shortEscapePattern)|\(controlPattern)"
        // A malformed pattern here is a programming error — crash loudly in debug.
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            fatalError("ANSIStripper: invalid combined pattern")
        }
        return regex
    }()

    /// Returns `text` with all ANSI escape sequences and stray control
    /// characters removed. Cursor-position sequences become a single space
    /// so word separation survives; line breaks and tabs are preserved.
    public static func strip(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        positionRegex.replaceMatches(
            in: mutable, options: [],
            range: NSRange(location: 0, length: mutable.length),
            withTemplate: " "
        )
        // Recompute the range: the pass above may have shrunk the string.
        combined.replaceMatches(
            in: mutable, options: [],
            range: NSRange(location: 0, length: mutable.length),
            withTemplate: ""
        )
        return mutable as String
    }
}
