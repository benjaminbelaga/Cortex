import Foundation
import Domain

/// Reads the mac-guardian daemon's state snapshot
/// (`~/.claude/state/guardian/state.json`) — machine health, live session
/// counts, and findings — replacing the SwiftBar guardian dots.
///
/// The daemon (LaunchAgent `com.yoyaku.mac-guardian`, 60 s tick) stays the
/// writer; this reader only consumes. A snapshot older than the staleness
/// gate renders as a warning state, never green (plugin-parity rule: a mute
/// daemon must not look healthy).
///
/// The reader is an **adapter**: it decodes the on-disk JSON into the domain
/// model `GuardianSnapshot` (defined in `Sources/Domain/Provider/Guardian/`),
/// so consumers can import `Domain` alone and stay decoupled from this file.
public enum GuardianStateReader {

    public static let stateURL = URL(fileURLWithPath:
        (("~/.claude/state/guardian/state.json" as NSString).expandingTildeInPath as String)
    )

    /// Plugin-parity staleness gate (the SwiftBar plugin used 180 s).
    public static let stalenessLimit: TimeInterval = 180

    /// Reads and validates the snapshot. Returns nil when unreadable.
    public static func read(now: Date = Date()) -> GuardianSnapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return decode(data, now: now)
    }

    public static func decode(_ data: Data, now: Date = Date()) -> GuardianSnapshot? {
        struct Payload: Decodable {
            let ts: Double
            let status: String
            let metrics: GuardianSnapshot.Metrics
            let findings: [GuardianSnapshot.Finding]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let capturedAt = Date(timeIntervalSince1970: payload.ts)
        return GuardianSnapshot(
            status: payload.status,
            capturedAt: capturedAt,
            metrics: payload.metrics,
            findings: payload.findings ?? [],
            isStale: now.timeIntervalSince(capturedAt) > stalenessLimit
        )
    }
}

/// Counts harness sessions by transcript freshness — the "traquer ce que
/// j'utilise" data point. One file-count per harness directory, throttled
/// and never run on the render path.
public enum HarTranscriptCounter {

    public struct Counts: Sendable, Equatable {
        public let claude: Int
        public let codex: Int
        public let kimi: Int
        public let qwen: Int
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Harness transcript roots. KeyPath-free on purpose: storing keypaths
    /// in a static tuple exists as `any KeyPath & Sendable` under strict
    /// concurrency, which then can't convert back for the write.
    static var roots: [URL] {
        [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".kimi-code/sessions"),
            home.appendingPathComponent(".qwen/projects"),
        ]
    }

    /// Counts transcripts modified within `window` (default 24 h) across the
    /// harness roots. Cheap enough at 5-minute cadence; never call per-frame.
    public static func countActive(within window: TimeInterval = 86_400, now: Date = Date()) -> Counts {
        let cutoff = now.addingTimeInterval(-window)
        return Counts(
            claude: countJSONL(in: roots[0], modifiedAfter: cutoff),
            codex: countJSONL(in: roots[1], modifiedAfter: cutoff),
            kimi: countJSONL(in: roots[2], modifiedAfter: cutoff),
            qwen: countJSONL(in: roots[3], modifiedAfter: cutoff)
        )
    }

    /// Walks `dir` (two levels — enough for ~/.claude/projects/<munged-cwd>/
    /// and ~/.codex/sessions/YYYY/MM/) counting recent .jsonl files.
    static func countJSONL(in dir: URL, modifiedAfter cutoff: Date) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            if modified > cutoff { count += 1 }
        }
        return count
    }
}
