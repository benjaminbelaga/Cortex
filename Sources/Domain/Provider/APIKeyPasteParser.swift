import Foundation

/// Parses a pasted block of labelled API keys, e.g. a notes excerpt:
///
///     Workspace objects
///     oc_s…
///
///     Workspace interwave
///     oc_s…
///
/// A key line binds to the nearest preceding label line; a lone key takes
/// `fallbackLabel`. Leading "Workspace " is dropped from labels. Values never
/// leave the returned pairs (no logging).
public enum APIKeyPasteParser {
    public struct Entry: Equatable, Sendable {
        public let label: String
        public let key: String
        /// Provider the key shape belongs to (`opencode-go`, `ollama`), or nil
        /// when the shape is a generic secret (`sk-…`) and the caller decides.
        public let providerHint: String?

        public init(label: String, key: String, providerHint: String? = nil) {
            self.label = label
            self.key = key
            self.providerHint = providerHint
        }
    }

    public static func parse(_ text: String, fallbackLabel: String = "") -> [Entry] {
        var entries: [Entry] = []
        var pending: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if isKey(line) {
                let label = pending ?? fallbackLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                entries.append(Entry(label: clean(label), key: line, providerHint: providerHint(for: line)))
                pending = nil
            } else {
                pending = line
            }
        }
        return entries
    }

    static func isKey(_ line: String) -> Bool {
        guard line.count >= 20, !line.contains(where: \.isWhitespace), !line.contains("*") else { return false }
        return line.hasPrefix("oc_") || line.hasPrefix("sk-") || isOllamaCloudKey(line)
    }

    /// Shape → provider. `oc_…` is an OpenCode Go key, the Ollama Cloud key is
    /// `32hex.16+base64url`, and `sk-…` is a generic secret whose provider the
    /// caller picks (nil).
    static func providerHint(for line: String) -> String? {
        if line.hasPrefix("oc_") { return "opencode-go" }
        if isOllamaCloudKey(line) { return "ollama" }
        return nil
    }

    /// Ollama Cloud: 32 hex, a dot, then a ≥16-char `[A-Za-z0-9_-]` body.
    static func isOllamaCloudKey(_ line: String) -> Bool {
        guard let dot = line.firstIndex(of: "."), line[..<dot].count == 32,
              line[..<dot].allSatisfy(\.isHexDigit) else { return false }
        let body = line[line.index(after: dot)...]
        return body.count >= 16 && body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    static func clean(_ label: String) -> String {
        var s = label
        if s.lowercased().hasPrefix("workspace ") { s = String(s.dropFirst("workspace ".count)) }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}
