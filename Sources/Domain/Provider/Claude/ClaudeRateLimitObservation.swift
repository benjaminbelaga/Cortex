import Foundation

/// A passive observation of Claude's rate-limit state, posted by the
/// `cortex-statusline.sh` shim that wraps `~/.claude/settings.json`'s
/// `statusLine.command`.
///
/// The shim relays the Claude statusline JSON payload verbatim; this struct
/// projects the rate-limit slice (`rate_limits.five_hour`, `rate_limits.seven_day`,
/// …) into a typed domain model. A missing field is **unknown**, never a
/// fabricated 0% or 100% — the row renders as `quotaPending` upstream
/// until a real observation arrives.
public struct ClaudeRateLimitObservation: Sendable, Equatable {
    /// The Claude config directory this observation belongs to
    /// (e.g. `~/.claude`, `~/.claude-accounts/studio`).
    public let configDir: String

    /// When the shim captured the payload — read from the payload's
    /// `timestamp` field, not the receiver clock, so clock skew between
    /// the Claude process and Cortex doesn't shift the row's age.
    public let capturedAt: Date

    /// The model identifier from the payload, when present.
    public let modelId: String?

    /// The session identifier from the payload, when present.
    public let sessionId: String?

    /// One observation per quota window. Order preserved from the payload.
    public let windows: [Window]

    public init(
        configDir: String,
        capturedAt: Date,
        modelId: String? = nil,
        sessionId: String? = nil,
        windows: [Window]
    ) {
        self.configDir = configDir
        self.capturedAt = capturedAt
        self.modelId = modelId
        self.sessionId = sessionId
        self.windows = windows
    }

    /// A single quota window. `percentRemaining` is **nil** when the source
    /// payload did not carry `used_percentage` for this window — unknown,
    /// not zero.
    public struct Window: Sendable, Equatable {
        public let id: WindowID
        /// `100 - used_percentage` from the payload; nil when absent.
        public let percentRemaining: Double?
        /// Wall-clock instant at which this window resets, parsed from
        /// `resets_at` (ISO-8601) when present; nil when absent.
        public let resetsAt: Date?
        public let resetText: String?

        public init(
            id: WindowID,
            percentRemaining: Double?,
            resetsAt: Date? = nil,
            resetText: String? = nil
        ) {
            self.id = id
            self.percentRemaining = percentRemaining
            self.resetsAt = resetsAt
            self.resetText = resetText
        }
    }

    /// The canonical window identifiers the Claude statusline schema exposes.
    /// `raw(String)` is reserved for future windows the schema may add.
    public enum WindowID: Sendable, Equatable, Hashable {
        case fiveHour
        case sevenDay
        case raw(String)

        public init(rawValue: String) {
            switch rawValue {
            case "five_hour": self = .fiveHour
            case "seven_day": self = .sevenDay
            default: self = .raw(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .fiveHour: return "five_hour"
            case .sevenDay: return "seven_day"
            case .raw(let s): return s
            }
        }
    }

    // MARK: - Parsing

    public enum ParseError: Error, Equatable {
        case invalidTimestamp(String)
        case invalidWindowShape(String)
    }

    /// Parses a Claude statusline payload (the JSON object delivered to the
    /// shim's stdin). Returns `nil` for shapes that don't carry the slices
    /// we model — previews or empty payloads — so the caller can stay
    /// honest about "no data" without throwing.
    ///
    /// Throws only when the payload claims to be a statusline object but is
    /// shaped badly (no timestamp when one is required by the schema, non-
    /// object root). A payload with a valid timestamp but **no** rate-limit
    /// fields parses successfully to an observation with `windows: []` —
    /// the row will then render as "no data yet" rather than crash.
    public static func parse(
        _ data: Data,
        configDir: String,
        now: Date = Date()
    ) throws -> ClaudeRateLimitObservation? {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = json as? [String: Any] else { return nil }

        // Statuslines from older Claude builds may not carry `timestamp`;
        // surface as "no data" rather than throwing on every legacy shell.
        guard let timestampRaw = root["timestamp"] as? String else { return nil }
        guard let capturedAt = ISO8601DateFormatter.cortex.parse(timestampRaw) else {
            throw ParseError.invalidTimestamp(timestampRaw)
        }

        let modelId: String? = {
            if let s = root["model"] as? String { return s }
            if let dict = root["model"] as? [String: Any] { return dict["id"] as? String }
            return nil
        }()
        let sessionId = root["session_id"] as? String

        var windows: [Window] = []
        if let rateLimits = root["rate_limits"] as? [String: Any] {
            for key in rateLimits.keys.sorted() {
                guard let entry = rateLimits[key] as? [String: Any] else {
                    throw ParseError.invalidWindowShape(key)
                }
                let percentRemaining: Double?
                if let used = entry["used_percentage"] as? Double {
                    percentRemaining = max(0, min(100, 100 - used))
                } else if let used = entry["used_percentage"] as? Int {
                    percentRemaining = max(0, min(100, 100 - Double(used)))
                } else {
                    // Field absent — unknown, not fabricated.
                    percentRemaining = nil
                }

                let resetsAt: Date?
                let resetText: String?
                if let raw = entry["resets_at"] as? String {
                    resetText = raw
                    resetsAt = ISO8601DateFormatter.cortex.parse(raw)
                } else {
                    resetText = nil
                    resetsAt = nil
                }

                windows.append(Window(
                    id: WindowID(rawValue: key),
                    percentRemaining: percentRemaining,
                    resetsAt: resetsAt,
                    resetText: resetText
                ))
            }
        }

        return ClaudeRateLimitObservation(
            configDir: configDir,
            capturedAt: capturedAt,
            modelId: modelId,
            sessionId: sessionId,
            windows: windows
        )
    }
}

extension ISO8601DateFormatter {
    /// Tolerant parser: handles both `2026-09-16T18:00:00Z` and
    /// `2026-09-16T18:00:00.123Z` shapes the Claude statusline may emit.
    /// Built once and shared so the same tolerance applies to both the
    /// payload timestamp and per-window `resets_at` parsing.
    nonisolated(unsafe) static let cortex: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Tolerant parse entry point used by tests and call sites: accepts both
    /// `2026-09-16T18:00:00Z` and `2026-09-16T18:00:00.123Z` shapes.
    func parse(_ value: String) -> Date? {
        if let parsed = date(from: value) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
