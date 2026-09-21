import Foundation
import Domain

public struct AlibabaUsageProbe: UsageProbe {
    private let settingsRepository: any AlibabaSettingsRepository
    private let networkClient: any NetworkClient
    private let cookieProvider: any AlibabaCookieProviding
    private let timeout: TimeInterval

    public init(
        settingsRepository: any AlibabaSettingsRepository,
        networkClient: (any NetworkClient)? = nil,
        cookieProvider: any AlibabaCookieProviding,
        timeout: TimeInterval = 15.0
    ) {
        self.settingsRepository = settingsRepository
        self.networkClient = networkClient ?? URLSession.shared
        self.cookieProvider = cookieProvider
        self.timeout = timeout
    }

    // MARK: - UsageProbe

    public func isAvailable() async -> Bool {
        // Available if we have either a cookie or an API key
        if let apiKey = settingsRepository.getAlibabaApiKey(), !apiKey.isEmpty {
            return true
        }

        let cookieSource = settingsRepository.alibabaCookieSource()
        switch cookieSource {
        case .manual:
            if let cookie = settingsRepository.getAlibabaManualCookie(), !cookie.isEmpty {
                return true
            }
        case .auto:
            if let cookie = cookieProvider.extractBrowserCookies(), !cookie.isEmpty {
                return true
            }
        }

        return false
    }

    public func probe() async throws -> UsageSnapshot {
        let region = settingsRepository.alibabaRegion()

        // Try API key first
        if let apiKey = settingsRepository.getAlibabaApiKey(), !apiKey.isEmpty {
            return try await fetchWithApiKey(apiKey, region: region)
        }

        // Try cookie
        let cookie = try resolveCookie()
        return try await fetchWithCookie(cookie, region: region)
    }

    // MARK: - Private

    private func resolveCookie() throws -> String {
        let source = settingsRepository.alibabaCookieSource()
        switch source {
        case .manual:
            guard let cookie = settingsRepository.getAlibabaManualCookie(), !cookie.isEmpty else {
                throw ProbeError.authenticationRequired
            }
            return cookie
        case .auto:
            return try extractBrowserCookies()
        }
    }

    private func extractBrowserCookies() throws -> String {
        guard let cookie = cookieProvider.extractBrowserCookies(), !cookie.isEmpty else {
            throw ProbeError.authenticationRequired
        }
        return cookie
    }

    private func fetchWithApiKey(_ apiKey: String, region: AlibabaRegion) async throws -> UsageSnapshot {
        let url = Self.apiQuotaURL(for: region)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = Self.apiRequestBody(for: region)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "X-DashScope-API-Key")

        let (data, response) = try await networkClient.request(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeError.executionFailed("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ProbeError.authenticationRequired
        }

        guard httpResponse.statusCode == 200 else {
            throw ProbeError.executionFailed("HTTP \(httpResponse.statusCode)")
        }

        return try Self.parseResponse(data, providerId: "alibaba")
    }

    private func fetchWithCookie(_ cookie: String, region: AlibabaRegion) async throws -> UsageSnapshot {
        let url = Self.consoleRPCURL(for: region)
        let secToken = try await resolveSecToken(cookie: cookie, region: region)

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = Self.consoleRequestBody(for: region, secToken: secToken)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        if let csrf = Self.extractCookieValue(name: "login_aliyunid_csrf", from: cookie) {
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }

        let (data, response) = try await networkClient.request(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeError.executionFailed("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ProbeError.sessionExpired(hint: "Re-authenticate in Alibaba Cloud console.")
        }

        guard httpResponse.statusCode == 200 else {
            throw ProbeError.executionFailed("HTTP \(httpResponse.statusCode)")
        }

        return try Self.parseResponse(data, providerId: "alibaba")
    }

    private func resolveSecToken(cookie: String, region: AlibabaRegion) async throws -> String {
        // Try extracting from cookie first
        if let secToken = Self.extractCookieValue(name: "sec_token", from: cookie), !secToken.isEmpty {
            return secToken
        }

        // Fetch from dashboard HTML
        let dashboardURL = region.dashboardURL
        var request = URLRequest(url: dashboardURL, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let (data, _) = try await networkClient.request(request)
        guard let html = String(data: data, encoding: .utf8),
              let token = Self.extractSecTokenFromHTML(html) else {
            throw ProbeError.sessionExpired(hint: "Re-authenticate in Alibaba Cloud console.")
        }

        return token
    }

    // MARK: - URL Construction

    static func apiQuotaURL(for region: AlibabaRegion) -> URL {
        var components = URLComponents(string: region.gatewayBaseURLString)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: region.currentRegionID),
        ]
        return components.url!
    }

    static func consoleRPCURL(for region: AlibabaRegion) -> URL {
        var components = URLComponents(string: region.consoleRPCBaseURLString)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: region.consoleRPCAction),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
        ]
        return components.url!
    }

    static func apiRequestBody(for region: AlibabaRegion) -> Data {
        let payload: [String: Any] = [
            "queryCodingPlanInstanceInfoRequest": [
                "commodityCode": region.commodityCode,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    static func consoleRequestBody(for region: AlibabaRegion, secToken: String) -> Data {
        let paramsObject: [String: Any] = [
            "Api": "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2",
            "V": "1.0",
            "Data": [
                "queryCodingPlanInstanceInfoRequest": [
                    "commodityCode": region.commodityCode,
                    "onlyLatestOne": true,
                ],
            ],
        ]

        guard let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
              let paramsString = String(data: paramsData, encoding: .utf8) else {
            return Data()
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "region", value: region.currentRegionID),
            URLQueryItem(name: "sec_token", value: secToken),
        ]
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    // MARK: - Parsing (Static for testability)

    static func parseResponse(_ data: Data, providerId: String) throws -> UsageSnapshot {
        guard !data.isEmpty else {
            throw ProbeError.parseFailed("Empty response body")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProbeError.parseFailed("Invalid JSON: \(error.localizedDescription)")
        }

        guard let dictionary = object as? [String: Any] else {
            throw ProbeError.parseFailed("Unexpected payload format")
        }

        // Check for login required
        if let code = findFirstString(forKeys: ["code", "status"], in: dictionary) {
            let normalized = code.lowercased()
            if normalized.contains("needlogin") || normalized.contains("login") {
                throw ProbeError.sessionExpired(hint: "Re-authenticate in Alibaba Cloud console.")
            }
        }

        if let message = findFirstString(forKeys: ["message", "msg"], in: dictionary) {
            let normalized = message.lowercased()
            if normalized.contains("log in") || normalized.contains("login") {
                throw ProbeError.sessionExpired(hint: "Re-authenticate in Alibaba Cloud console.")
            }
        }

        // Check for auth errors
        if let statusCode = findFirstInt(forKeys: ["statusCode", "status_code"], in: dictionary),
           statusCode == 401 || statusCode == 403 {
            throw ProbeError.authenticationRequired
        }

        // Find the active instance info with quota data
        let expanded = expandedJSON(dictionary)
        guard let expandedDict = expanded as? [String: Any] else {
            throw ProbeError.parseFailed("Could not expand response")
        }

        let instanceInfo = findActiveInstanceInfo(in: expandedDict)
        // Prefer quota from active instance, then fall back to full payload search
        guard let quotaInfo = findQuotaInfo(in: instanceInfo ?? [:]) ?? findQuotaInfo(in: expandedDict) else {
            throw ProbeError.parseFailed("Missing coding plan quota data")
        }

        let planName = findPlanName(in: expandedDict)
        var quotas: [UsageQuota] = []

        // 5-hour session window
        if let used = anyInt(for: ["per5HourUsedQuota", "perFiveHourUsedQuota"], in: quotaInfo),
           let total = anyInt(for: ["per5HourTotalQuota", "perFiveHourTotalQuota"], in: quotaInfo),
           total > 0 {
            let remaining = Double(max(0, total - used)) / Double(total) * 100
            let resetDate = anyDate(for: ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"], in: quotaInfo)
            quotas.append(UsageQuota(
                percentRemaining: remaining,
                quotaType: .session,
                providerId: providerId,
                resetsAt: resetDate,
                resetText: "\(used) / \(total) used"
            ))
        }

        // Weekly window
        if let used = anyInt(for: ["perWeekUsedQuota"], in: quotaInfo),
           let total = anyInt(for: ["perWeekTotalQuota"], in: quotaInfo),
           total > 0 {
            let remaining = Double(max(0, total - used)) / Double(total) * 100
            let resetDate = anyDate(for: ["perWeekQuotaNextRefreshTime"], in: quotaInfo)
            quotas.append(UsageQuota(
                percentRemaining: remaining,
                quotaType: .weekly,
                providerId: providerId,
                resetsAt: resetDate,
                resetText: "\(used) / \(total) used"
            ))
        }

        // Monthly window
        if let used = anyInt(for: ["perBillMonthUsedQuota", "perMonthUsedQuota"], in: quotaInfo),
           let total = anyInt(for: ["perBillMonthTotalQuota", "perMonthTotalQuota"], in: quotaInfo),
           total > 0 {
            let remaining = Double(max(0, total - used)) / Double(total) * 100
            let resetDate = anyDate(for: ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"], in: quotaInfo)
            quotas.append(UsageQuota(
                percentRemaining: remaining,
                quotaType: .timeLimit("Monthly"),
                providerId: providerId,
                resetsAt: resetDate,
                resetText: "\(used) / \(total) used"
            ))
        }

        guard !quotas.isEmpty else {
            throw ProbeError.parseFailed("No quota windows found in payload")
        }

        return UsageSnapshot(
            providerId: providerId,
            quotas: quotas,
            capturedAt: Date(),
            loginMethod: planName
        )
    }

    // MARK: - JSON Helpers

    /// Recursively expands nested "data" keys to flatten DataV2 wrappers
    static func expandedJSON(_ value: Any) -> Any {
        guard let dict = value as? [String: Any] else { return value }
        var result = dict

        // Recursively expand nested "data", "DataV2" wrappers
        for key in ["data", "DataV2", "successResponse", "success_response"] {
            if let nested = dict[key] as? [String: Any] {
                let expanded = expandedJSON(nested)
                if let expandedDict = expanded as? [String: Any] {
                    for (k, v) in expandedDict {
                        if result[k] == nil {
                            result[k] = v
                        }
                    }
                }
            }
        }

        return result
    }

    static func findActiveInstanceInfo(in payload: [String: Any]) -> [String: Any]? {
        guard let infos = findFirstArray(forKeys: ["codingPlanInstanceInfos", "coding_plan_instance_infos"], in: payload) else {
            return nil
        }

        var first: [String: Any]?
        for item in infos {
            guard let info = item as? [String: Any] else { continue }
            first = first ?? info
            let status = anyString(for: ["status", "instanceStatus"], in: info)?.uppercased()
            if status == "VALID" || status == "ACTIVE" {
                return info
            }
        }
        return first
    }

    static func findQuotaInfo(in payload: [String: Any]) -> [String: Any]? {
        // Direct key lookup
        if let direct = findFirstDictionary(forKeys: ["codingPlanQuotaInfo", "coding_plan_quota_info"], in: payload) {
            return direct
        }
        // Search for dictionary containing quota keys
        return findFirstDictionary(
            matchingAnyKey: ["per5HourUsedQuota", "per5HourTotalQuota", "perWeekUsedQuota", "perWeekTotalQuota"],
            in: payload
        )
    }

    static func findPlanName(in payload: [String: Any]) -> String? {
        if let infos = findFirstArray(forKeys: ["codingPlanInstanceInfos", "coding_plan_instance_infos"], in: payload) {
            for item in infos {
                guard let info = item as? [String: Any] else { continue }
                let status = anyString(for: ["status", "instanceStatus"], in: info)?.uppercased()
                if status == "VALID" || status == "ACTIVE" || status == nil {
                    if let name = anyString(for: ["planName", "plan_name", "instanceName", "packageName"], in: info), !name.isEmpty {
                        return name
                    }
                }
            }
        }
        return findFirstString(forKeys: ["planName", "plan_name", "packageName"], in: payload)
    }

    // MARK: - Cookie Helpers

    static func extractCookieValue(name: String, from cookieHeader: String) -> String? {
        let pairs = cookieHeader.split(separator: ";")
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == name {
                return String(parts[1])
            }
        }
        return nil
    }

    static func extractSecTokenFromHTML(_ html: String) -> String? {
        // Pattern: "sec_token":"<token>" or sec_token = '<token>'
        let patterns = [
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"sec_token\s*=\s*'([^']+)'"#,
            #"sec_token\s*=\s*"([^"]+)""#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
        }
        return nil
    }

    // MARK: - Generic JSON Traversal Helpers

    static func findFirstString(forKeys keys: [String], in value: Any) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        for key in keys {
            if let str = dict[key] as? String, !str.isEmpty { return str }
        }
        for nested in dict.values {
            if let found = findFirstString(forKeys: keys, in: nested) { return found }
        }
        return nil
    }

    static func findFirstInt(forKeys keys: [String], in value: Any) -> Int? {
        guard let dict = value as? [String: Any] else { return nil }
        for key in keys {
            if let val = parseInt(dict[key]) { return val }
        }
        for nested in dict.values {
            if let found = findFirstInt(forKeys: keys, in: nested) { return found }
        }
        return nil
    }

    static func findFirstArray(forKeys keys: [String], in value: Any) -> [Any]? {
        guard let dict = value as? [String: Any] else { return nil }
        for key in keys {
            if let arr = dict[key] as? [Any] { return arr }
        }
        for nested in dict.values {
            if let found = findFirstArray(forKeys: keys, in: nested) { return found }
        }
        return nil
    }

    static func findFirstDictionary(forKeys keys: [String], in value: Any) -> [String: Any]? {
        guard let dict = value as? [String: Any] else { return nil }
        for key in keys {
            if let nested = dict[key] as? [String: Any] { return nested }
        }
        for nestedValue in dict.values {
            if let found = findFirstDictionary(forKeys: keys, in: nestedValue) { return found }
        }
        return nil
    }

    static func findFirstDictionary(matchingAnyKey keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if keys.contains(where: { dict[$0] != nil }) { return dict }
            for nestedValue in dict.values {
                if let found = findFirstDictionary(matchingAnyKey: keys, in: nestedValue) { return found }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let found = findFirstDictionary(matchingAnyKey: keys, in: item) { return found }
            }
        }
        return nil
    }

    static func anyInt(for keys: [String], in dict: [String: Any]) -> Int? {
        for key in keys {
            if let val = parseInt(dict[key]) { return val }
        }
        return nil
    }

    static func anyString(for keys: [String], in dict: [String: Any]) -> String? {
        for key in keys {
            if let str = dict[key] as? String, !str.isEmpty { return str }
        }
        return nil
    }

    static func anyDate(for keys: [String], in dict: [String: Any]) -> Date? {
        for key in keys {
            if let date = parseDate(dict[key]) { return date }
        }
        return nil
    }

    static func parseInt(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let doubleVal = value as? Double { return Int(doubleVal) }
        if let strVal = value as? String, let intVal = Int(strVal) { return intVal }
        return nil
    }

    static func parseDate(_ value: Any?) -> Date? {
        guard let value else { return nil }

        if let str = value as? String {
            // ISO 8601 with timezone offset (e.g., "2026-03-12T19:17:15+08:00")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) { return date }

            // ISO 8601 with fractional seconds
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date }

            // Epoch seconds as string
            if let epoch = Double(str) {
                return Date(timeIntervalSince1970: epoch)
            }
        }

        if let epoch = value as? Double {
            return Date(timeIntervalSince1970: epoch)
        }

        if let epoch = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(epoch))
        }

        return nil
    }
}

// MARK: - AlibabaRegion URL Extensions

extension AlibabaRegion {
    var gatewayBaseURLString: String {
        switch self {
        case .international: "https://modelstudio.console.alibabacloud.com"
        case .chinaMainland: "https://bailian.console.aliyun.com"
        }
    }

    public var dashboardURL: URL {
        switch self {
        case .international:
            URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/detail")!
        case .chinaMainland:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!
        }
    }

    var consoleRPCBaseURLString: String {
        switch self {
        case .international: "https://bailian-singapore-cs.alibabacloud.com"
        case .chinaMainland: "https://bailian-beijing-cs.aliyuncs.com"
        }
    }

    var consoleRPCAction: String {
        switch self {
        case .international: "IntlBroadScopeAspnGateway"
        case .chinaMainland: "BroadScopeAspnGateway"
        }
    }

    var commodityCode: String {
        switch self {
        case .international: "sfm_codingplan_public_intl"
        case .chinaMainland: "sfm_codingplan_public_cn"
        }
    }

    var currentRegionID: String {
        switch self {
        case .international: "ap-southeast-1"
        case .chinaMainland: "cn-beijing"
        }
    }
}
