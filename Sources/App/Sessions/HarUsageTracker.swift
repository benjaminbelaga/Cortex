import SwiftUI
import Observation
import Domain
import Infrastructure

/// Per-harness session/activity tracker for the panel ("traquer ce que
/// j'utilise"): live counters from the mac-guardian daemon (60 s tick) and
/// 24-hour transcript counts (throttled 5-min scan, panel-open only).
///
/// No new daemon: everything is read from existing state files. Observations
/// append to `~/.claudebar/har-activity.jsonl` (2 MB rotation) so usage
/// history outlives the app.
@MainActor
@Observable
public final class HarUsageTracker {

    // MARK: - Published state

    public private(set) var liveClaude: Int?
    public private(set) var liveCodex: Int?
    public private(set) var counts24h: HarTranscriptCounter.Counts?
    public private(set) var countsAt: Date?
    public private(set) var guardian: GuardianSnapshot?

    // MARK: - Plumbing

    private var tickTimer: Timer?
    private var lastScanAt: Date?
    /// Transcript scans happen at most every 5 minutes (they walk four
    /// directory trees; the guardian tail is a single file read).
    private static let scanInterval: TimeInterval = 300
    nonisolated private static let activityFileURL = URL(fileURLWithPath:
        (("~/.claudebar/har-activity.jsonl" as NSString).expandingTildeInPath as String)
    )
    nonisolated private static let rotationBytes = 2_000_000

    public init() {}

    /// Starts the 60 s light tick. Call when the panel appears; stopping is
    /// optional (the timer dies with the runloop task) but `stop()` is
    /// provided for symmetry.
    public func start() {
        guard tickTimer == nil else { return }
        refresh(now: Date())
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    public func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// One pass: guardian tail every call, transcript scan under the
    /// throttle. The heavy scan runs OFF the main actor.
    private func refresh(now: Date) {
        guardian = GuardianStateReader.read(now: now)
        liveClaude = guardian?.metrics.liveClaude
        liveCodex = guardian?.metrics.liveCodex

        let scanDue = lastScanAt.map { now.timeIntervalSince($0) >= Self.scanInterval } ?? true
        guard scanDue else { return }
        lastScanAt = now
        let capturedAt = now
        Task { [weak self] in
            let counts = await Task.detached(priority: .utility) {
                HarTranscriptCounter.countActive(now: capturedAt)
            }.value
            guard let self else { return }
            self.counts24h = counts
            self.countsAt = capturedAt
            Self.appendObservation(counts: counts, at: capturedAt)
        }
    }

    /// Appends one observation line; rotates to `.old` past 2 MB.
    /// File IO off the main path (called from the detached completion).
    nonisolated private static func appendObservation(counts: HarTranscriptCounter.Counts, at date: Date) {
        let fm = FileManager.default
        let url = activityFileURL
        fm.createFile(atPath: url.path, contents: nil)

        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > rotationBytes {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + ".old"))
            try? fm.moveItem(at: url, to: URL(fileURLWithPath: url.path + ".old"))
        }

        let line = String(
            format: "{\"ts\":%.3f,\"claude\":%d,\"codex\":%d,\"kimi\":%d,\"qwen\":%d}\n",
            date.timeIntervalSince1970, counts.claude, counts.codex, counts.kimi, counts.qwen
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}
