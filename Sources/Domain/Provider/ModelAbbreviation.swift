import Foundation

/// Canonical model id → short display abbreviation mapping.
///
/// Single source of truth lives in `~/repos/llm-router/config/providers.yaml`
/// under `display_abbreviations` (rules/81: data in registered SSOT, never
/// duplicated). The build phase `regen-model-abbrev.sh` (and Tuist's
/// preBuildScripts) renders the YAML into
/// `ModelAbbreviation.generated.json` next to this file. The Swift runtime
/// reads that JSON so adding a new model id is a one-line YAML edit + a
/// rebuild — no Swift code change.
///
/// Terminal-safe values only: BMP Plane 0 characters (`◆`, `◎`, `K`, `Q`,
/// `Z`, `M`, `A`, `∞`, `›`), 1–7 chars, no Nerd Font PUA (issue
/// anthropics/claude-code#49270). See `rules/05b` for the MiniMax-side
/// counterpart of the same convention.
public enum ModelAbbreviation {

    /// Bundle resource name (`Bundle.module.url(forResource:)`).
    public static let resourceName = "ModelAbbreviation.generated"

    /// Extension of the generated JSON.
    public static let resourceExtension = "json"

    /// Cache keyed by model id; lazy-loaded on first lookup.
    /// `nonisolated(unsafe)` is the Swift 6 idiom for read-mostly caches that
    /// are mutated only on the first call from any thread (the lock guarantees
    /// write atomicity). Reads of the immutable dictionary once populated are
    /// safe to perform from any actor context.
    nonisolated(unsafe) private static var cache: [String: String]?
    private static let cacheLock = NSLock()

    /// Return the short abbreviation for a model id, or `nil` when the id is
    /// unknown. Caller decides whether to render `›abbr` in a UI label.
    public static func abbreviation(for modelId: String?) -> String? {
        guard let modelId, !modelId.isEmpty else { return nil }
        let table = loadTable()
        return table[modelId]
    }

    /// Force-reload the table (e.g. after a manual YAML edit and JSON regen
    /// outside of the build). Useful for tests + developer hot-iteration.
    public static func reload() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = nil
    }

    // MARK: - Internal

    private static func loadTable() -> [String: String] {
        cacheLock.lock()
        if let cached = cache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let loaded = readBundled() ?? [:]

        cacheLock.lock()
        cache = loaded
        cacheLock.unlock()
        return loaded
    }

    private static func readBundled() -> [String: String]? {
        // Tuist merges static-framework resources into the main app bundle, so
        // Bundle.module (SPM-style) is unavailable for the Domain framework —
        // we read from the main bundle instead. The JSON lives at
        // Cortex.app/Contents/Resources/ModelAbbreviation.generated.json after
        // the build phase `regen-model-abbrev.sh` has run.
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            // Resource missing — the build phase failed to generate the JSON.
            // Degrade to an empty table rather than crash the app; UI will
            // show the harness-only label (e.g. "Claude") without the routed
            // model. A future build phase will surface this via stderr.
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Schema.self, from: data)
            return decoded.mappings
        } catch {
            // Schema drift: re-run the build phase regen-model-abbrev.sh.
            return nil
        }
    }

    /// JSON schema mirror of `display_abbreviations`. Keep in sync with
    /// `scripts/regen-model-abbrev.sh` (the only writer).
    private struct Schema: Decodable {
        let schema_version: Int
        let mappings: [String: String]
    }
}
