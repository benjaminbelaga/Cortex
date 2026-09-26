import Foundation
import Domain

/// Reads the centralized local usage ledger written by
/// `scripts/cortex-usage-ledger.py`. The script is the ONLY aggregator (it owns
/// the transcript/Codex/OpenCode parsing); this reader only decodes its output,
/// so the app and the CLI can never disagree.
public struct LocalUsageLedgerReader: Sendable {

    public init() {}

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudebar", isDirectory: true)
            .appendingPathComponent("usage", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }

    /// Decodes the ledger, or nil when absent/unreadable — the UI then says so
    /// instead of showing a fabricated zero.
    public func read(at url: URL = LocalUsageLedgerReader.defaultURL()) -> LocalUsageLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(LocalUsageLedger.self, from: data)
    }

    public func modifiedDate(at url: URL = LocalUsageLedgerReader.defaultURL()) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
