import Foundation
import Domain

/// Fetches Ollama Cloud plan usage from `GET https://ollama.com/api/usage`
/// (bearer API key, undocumented but stable; verified live 2026-09-23).
///
/// Response shape:
/// ```json
/// { "limits": {
///     "session": { "usage": 0.025, "models": [...] },
///     "weekly":  { "usage": 0.335, "models": [...] },
///     "monthly": { "usage": 1,     "models": [...] } },
///   "activity": { "cost": "0.00000", "period": { ... } } }
/// ```
/// `usage` is a 0…1 *consumed* fraction. Which windows exist depends on the
/// plan edition (plans created after 2026-08-31 expose `monthly` only), so a
/// missing window is left out — never rendered as 100 %. The endpoint carries
/// no reset timestamp: `resetsAt` stays nil rather than an invented date.
public struct OllamaCloudUsageProbe: UsageProbe, @unchecked Sendable {
    static let usageURL = URL(string: "https://ollama.com/api/usage")!
    static let providerId = "ollama"
    private static let reloginHint = "Create a new API key on ollama.com/settings/keys and re-add the account."

    private let apiKey: String
    private let networkClient: any NetworkClient
    private let timeout: TimeInterval

    public init(apiKey: String, networkClient: any NetworkClient = URLSession.shared, timeout: TimeInterval = 15) {
        self.apiKey = apiKey
        self.networkClient = networkClient
        self.timeout = timeout
    }

    public func isAvailable() async -> Bool { !apiKey.isEmpty }

    public func probe() async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await networkClient.request(request)
        } catch {
            AppLog.probes.error("Ollama: Network error: \(error.localizedDescription)")
            throw ProbeError.executionFailed("Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.executionFailed("Invalid response")
        }
        switch http.statusCode {
        case 200:
            let snapshot = try Self.parseResponse(data)
            AppLog.probes.info("Ollama API probe success: \(snapshot.quotas.count) window(s)")
            return snapshot
        case 401:
            AppLog.probes.error("Ollama: API key rejected (HTTP 401)")
            throw ProbeError.sessionExpired(hint: Self.reloginHint)
        case 403:
            throw ProbeError.subscriptionRequired
        default:
            AppLog.probes.error("Ollama: HTTP error \(http.statusCode)")
            throw ProbeError.executionFailed("HTTP error: \(http.statusCode)")
        }
    }

    // MARK: - Parsing (testable)

    private static let windows: [(key: String, type: QuotaType, duration: TimeInterval?)] = [
        ("session", .session, 5 * 3600),
        ("weekly", .weekly, 7 * 86400),
        ("monthly", .timeLimit("Monthly"), nil),
    ]

    static func parseResponse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["limits"] as? [String: Any] else {
            throw ProbeError.parseFailed("Missing 'limits' in Ollama usage response")
        }
        var quotas: [UsageQuota] = []
        for window in windows {
            guard let entry = limits[window.key] as? [String: Any],
                  let used = (entry["usage"] as? NSNumber)?.doubleValue else { continue }
            quotas.append(UsageQuota(
                percentRemaining: max(0, min(100, (1 - used) * 100)),
                quotaType: window.type,
                providerId: providerId,
                resetsAt: nil,
                windowDuration: window.duration
            ))
        }
        guard !quotas.isEmpty else {
            throw ProbeError.parseFailed("No usage windows in Ollama response")
        }
        return UsageSnapshot(providerId: providerId, quotas: quotas, capturedAt: now)
    }
}
