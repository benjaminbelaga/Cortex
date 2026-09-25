import Foundation

/// Dumps raw probe payloads to disk when a parse fails, so the exact bytes
/// that broke the parser can be inspected after the fact.
///
/// Captures land in `~/Library/Application Support/Cortex/Diagnostics/`
/// as `<kind>-<ISO timestamp>.txt` (colons replaced so the name is
/// filesystem-safe). Only the newest `keepLast` captures per kind are kept —
/// this is a diagnostic ring buffer, not a log. Use sparingly: one file per
/// genuine failure, never on the happy path.
public enum RawCaptureWriter {

    static var diagnosticsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Cortex", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Writes `payload` to a timestamped file under Diagnostics and prunes
    /// older captures of the same kind.
    ///
    /// - Parameters:
    ///   - kind: short slug used as filename prefix, e.g. `failed-parse`.
    ///   - payload: the raw bytes/string that failed processing.
    ///   - keepLast: how many captures of this kind to retain (default 10).
    public static func capture(kind: String, payload: String, keepLast: Int = 10) {
        let directory = diagnosticsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            AppLog.probes.error("RawCaptureWriter: could not create \(directory.path): \(error.localizedDescription)")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileURL = directory.appendingPathComponent("\(kind)-\(formatter.string(from: Date())).txt")

        do {
            try payload.write(to: fileURL, atomically: true, encoding: .utf8)
            AppLog.probes.warning("RawCaptureWriter: captured failing payload to \(fileURL.lastPathComponent)")
        } catch {
            AppLog.probes.error("RawCaptureWriter: write failed: \(error.localizedDescription)")
            return
        }

        prune(kind: kind, keepLast: keepLast, in: directory)
    }

    /// Removes all but the newest `keepLast` captures for `kind`.
    private static func prune(kind: String, keepLast: Int, in directory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let captures = entries
            .filter { $0.lastPathComponent.hasPrefix("\(kind)-") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        guard captures.count > keepLast else { return }
        for stale in captures.dropFirst(keepLast) {
            try? fm.removeItem(at: stale)
        }
    }
}
