import Foundation
import Domain

/// Probes the Kimi API for coding usage quota information.
///
/// Kimi offers subscription tiers (Andante/Moderato/Allegretto) with weekly request quotas
/// and a 5-hour rate limit. Auth uses the `kimi-auth` browser cookie.
///
/// API: POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages
/// Body: {"scope":["FEATURE_CODING"]}
public struct KimiUsageProbe: UsageProbe {

    private let networkClient: any NetworkClient
    private let tokenProvider: any KimiTokenProviding
    private let timeout: TimeInterval

    private static let usageURL = URL(
        string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"
    )!

    /// Known tier mappings based on weekly limit
    private static let tierByLimit: [Int: String] = [
        1024: "Andante",
        2048: "Moderato",
        7168: "Allegretto",
    ]

    public init(
        networkClient: any NetworkClient = URLSession.shared,
        tokenProvider: any KimiTokenProviding = KimiCookieTokenProvider(),
        timeout: TimeInterval = 30
    ) {
        self.networkClient = networkClient
        self.tokenProvider = tokenProvider
        self.timeout = timeout
    }

    // MARK: - UsageProbe

    public func isAvailable() async -> Bool {
        do {
            _ = try tokenProvider.resolveToken()
            return true
        } catch {
            return false
        }
    }

    public func probe() async throws -> UsageSnapshot {
        AppLog.probes.info("Starting Kimi probe...")

        // Step 1: Resolve authentication token
        let token: String
        do {
            token = try tokenProvider.resolveToken()
        } catch {
            throw ProbeError.authenticationRequired
        }

        // Step 2: Build request
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])

        Self.applyHeaders(&request, token: token)

        // Step 3: Make request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await networkClient.request(request)
        } catch {
            AppLog.probes.error("Kimi probe failed: \(error.localizedDescription)")
            throw ProbeError.executionFailed("Kimi API request failed: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeError.executionFailed("Invalid HTTP response")
        }

        AppLog.probes.debug("Kimi API response status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            AppLog.probes.error("Kimi probe failed: authentication error (\(httpResponse.statusCode))")
            throw ProbeError.authenticationRequired
        default:
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            AppLog.probes.error("Kimi probe failed: HTTP \(httpResponse.statusCode)")
            throw ProbeError.executionFailed("Kimi API returned HTTP \(httpResponse.statusCode): \(body)")
        }

        // Step 4: Log raw response for debugging
        if let rawString = String(data: data, encoding: .utf8) {
            AppLog.probes.debug("Kimi raw response: \(rawString.prefix(2000))")
        }

        // Step 5: Parse response
        let snapshot = try Self.parseResponse(data, providerId: "kimi")

        AppLog.probes.info("Kimi probe success: \(snapshot.quotas.count) quotas found")
        for quota in snapshot.quotas {
            AppLog.probes.info("  - \(quota.quotaType.displayName): \(Int(quota.percentRemaining))% remaining")
        }

        return snapshot
    }

    // MARK: - Static Parsing (for testability)

    /// Parses the Kimi API response into a UsageSnapshot.
    ///
    /// The response contains a `usages` array. We look for the entry with `scope == "FEATURE_CODING"`.
    /// From that entry:
    /// - `detail` contains the weekly quota (limit, used, remaining, resetTime)
    /// - `limits` array contains rate limits (e.g., 5-hour window with 300min/TIME_UNIT_MINUTE)
    static func parseResponse(_ data: Data, providerId: String) throws -> UsageSnapshot {
        let decoded: KimiUsageResponse
        do {
            decoded = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        } catch {
            throw ProbeError.parseFailed("Failed to decode Kimi response: \(error.localizedDescription)")
        }

        guard let coding = decoded.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw ProbeError.parseFailed("Missing FEATURE_CODING scope in response")
        }

        // Parse weekly quota from detail
        let weekly = parseUsageNumbers(detail: coding.detail)
        var quotas: [UsageQuota] = []

        let weeklyPercentRemaining: Double
        if weekly.limit > 0 {
            weeklyPercentRemaining = (Double(weekly.remaining) / Double(weekly.limit)) * 100.0
        } else {
            weeklyPercentRemaining = 100.0
        }

        let weeklyResetDate = parseISO8601(coding.detail.resetTime)

        quotas.append(UsageQuota(
            percentRemaining: weeklyPercentRemaining,
            quotaType: .weekly,
            providerId: providerId,
            resetsAt: weeklyResetDate,
            resetText: "\(weekly.used)/\(weekly.limit) requests"
        ))

        // Parse 5-hour rate limit from limits array
        // Look for window with duration=300, timeUnit=TIME_UNIT_MINUTE (300 min = 5 hours)
        let fiveHourRate = coding.limits?.first(where: {
            $0.window.duration == 300 && $0.window.timeUnit == "TIME_UNIT_MINUTE"
        }) ?? coding.limits?.first

        if let rateLimit = fiveHourRate {
            let rate = parseUsageNumbers(detail: rateLimit.detail)
            let ratePercentRemaining: Double
            if rate.limit > 0 {
                ratePercentRemaining = (Double(rate.remaining) / Double(rate.limit)) * 100.0
            } else {
                ratePercentRemaining = 100.0
            }

            let rateResetDate = parseISO8601(rateLimit.detail.resetTime)

            quotas.append(UsageQuota(
                percentRemaining: ratePercentRemaining,
                quotaType: .session,
                providerId: providerId,
                resetsAt: rateResetDate,
                resetText: "\(rate.used)/\(rate.limit) requests (5h)"
            ))
        }

        // Detect account tier from weekly limit
        let tier = tierByLimit[weekly.limit].map { AccountTier.custom($0) }

        return UsageSnapshot(
            providerId: providerId,
            quotas: quotas,
            capturedAt: Date(),
            accountTier: tier
        )
    }

    // MARK: - Private Helpers

    private static func applyHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) {
            return value
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func parseUsageNumbers(detail: KimiUsageResponse.Usage.Detail) -> (used: Int, limit: Int, remaining: Int) {
        let limit = Int(detail.limit) ?? 0
        let rawUsed = Int(detail.used ?? "")
        let rawRemaining = Int(detail.remaining ?? "")

        let used: Int
        let remaining: Int

        if let rawUsed, let rawRemaining {
            used = rawUsed
            remaining = rawRemaining
        } else if let rawUsed {
            used = rawUsed
            remaining = max(0, limit - rawUsed)
        } else if let rawRemaining {
            used = max(0, limit - rawRemaining)
            remaining = rawRemaining
        } else {
            used = 0
            remaining = max(0, limit)
        }

        return (used: used, limit: limit, remaining: remaining)
    }
}

// MARK: - Response Models

struct KimiUsageResponse: Decodable {
    struct Usage: Decodable {
        struct Detail: Decodable {
            let limit: String
            let used: String?
            let remaining: String?
            let resetTime: String
        }

        struct RateLimit: Decodable {
            struct Window: Decodable {
                let duration: Int
                let timeUnit: String
            }

            let window: Window
            let detail: Detail
        }

        let scope: String
        let detail: Detail
        let limits: [RateLimit]?
    }

    let usages: [Usage]
}
