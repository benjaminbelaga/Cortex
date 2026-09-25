import AppKit

/// Copies a secret to the pasteboard for a deliberate operator gesture, without
/// letting it linger: the value is marked concealed (clipboard managers and
/// Universal Clipboard skip it) and cleared automatically when the pasteboard
/// still holds our copy. The value never reaches a log.
@MainActor
enum SecretClipboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(
        _ value: String,
        to pasteboard: NSPasteboard = .general,
        clearAfter seconds: TimeInterval = 60
    ) {
        guard !value.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // Presence of the type is the signal clipboard managers read; the
        // payload itself is meaningless (an empty string may not even declare
        // the type, which is why it is a marker byte).
        pasteboard.setString("1", forType: concealedType)
        let changeCount = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
        }
    }
}
