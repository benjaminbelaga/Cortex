import Foundation
import Domain

/// Probes MiniMax Coding Plan API for usage quota information.
/// Supports both international (minimax.io) and China (minimaxi.com) regions.
/// (支持国际版和中国版两个区域)
/// Authentication: Bearer token from env var or stored API key.
public struct MiniMaxUsageProbe: UsageProbe {
    private let networkClient: any NetworkClient
    private let settingsRepository: any MiniMaxSettingsRepository
    private let timeout: TimeInterval

    /// Resolves the API URL based on the configured region (根据区域配置动态选择 API URL)
    var apiURL: String {
        settingsRepository.minimaxRegion().codingPlanRemainsURL
    }

    public init(
        networkClient: any NetworkClient = URLSession.shared,
        settingsRepository: any MiniMaxSettingsRepository,
        timeout: TimeInterval = 30
    ) {
        self.networkClient = networkClient
        self.settingsRepository = settingsRepository
        self.timeout = timeout
    }

    // MARK: - Token Resolution

    func getApiKey() -> String? {
        // First, check environment variable if configured
        let envVarName = settingsRepository.minimaxAuthEnvVar()
        let effectiveEnvVar = envVarName.isEmpty ? "MINIMAX_API_KEY" : envVarName
        if let envValue = ProcessInfo.processInfo.environment[effectiveEnvVar], !envValue.isEmpty {
            AppLog.probes.debug("MiniMax: Using API key from env var '\(effectiveEnvVar)'")
            return envValue
        }

        // Fall back to stored API key
        if let storedKey = settingsRepository.getMinimaxApiKey(), !storedKey.isEmpty {
            AppLog.probes.debug("MiniMax: Using stored API key")
            return storedKey
        }

        return nil
    }

    // MARK: - UsageProbe

    public func isAvailable() async -> Bool {
        let hasKey = getApiKey() != nil
        if !hasKey {
            AppLog.probes.debug("MiniMax: Not available - no API key configured")
        }
        return hasKey
    }

    public func probe() async throws -> UsageSnapshot {
        guard let apiKey = getApiKey(), !apiKey.isEmpty else {
            AppLog.probes.error("MiniMax: No API key configured (check env var or settings)")
            throw ProbeError.authenticationRequired
        }

        AppLog.probes.info("Starting MiniMax probe...")

        guard let url = URL(string: apiURL) else {
            throw ProbeError.executionFailed("Invalid MiniMax API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        let (data, response) = try await networkClient.request(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeError.executionFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            AppLog.probes.error("MiniMax API returned HTTP \(httpResponse.statusCode)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ProbeError.authenticationRequired
            }
            throw ProbeError.executionFailed("MiniMax API returned HTTP \(httpResponse.statusCode)")
        }

        // Log raw response at debug level
        if let responseText = String(data: data, encoding: .utf8) {
            AppLog.probes.debug("MiniMax API response: \(responseText.prefix(500))")
        }

        let snapshot = try Self.parseResponse(data, providerId: "minimax")

        AppLog.probes.info("MiniMax probe success: \(snapshot.quotas.count) quotas found")
        for quota in snapshot.quotas {
            AppLog.probes.info("  - \(quota.quotaType.displayName): \(Int(quota.percentRemaining))% remaining")
        }

        return snapshot
    }

    // MARK: - Response Parsing (Static for testability)

    /// Parses the MiniMax Coding Plan remains API response into a UsageSnapshot
    static func parseResponse(_ data: Data, providerId: String) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response: MiniMaxRemainsResponse
        do {
            response = try decoder.decode(MiniMaxRemainsResponse.self, from: data)
        } catch {
            AppLog.probes.error("MiniMax parse failed: Invalid JSON - \(error.localizedDescription)")
            if let rawString = String(data: data, encoding: .utf8) {
                AppLog.probes.debug("MiniMax raw response: \(rawString.prefix(500))")
            }
            throw ProbeError.parseFailed("Invalid JSON: \(error.localizedDescription)")
        }

        // Check API error status
        if response.baseResp.statusCode != 0 {
            let message = response.baseResp.statusMsg ?? "Unknown error"
            AppLog.probes.error("MiniMax API error: \(response.baseResp.statusCode) - \(message)")
            throw ProbeError.executionFailed("MiniMax API error: \(message)")
        }

        let modelRemains = response.modelRemains ?? []

        guard !modelRemains.isEmpty else {
            AppLog.probes.error("MiniMax: Empty model_remains in response")
            throw ProbeError.noData
        }

        let quotas = modelRemains.map { model -> UsageQuota in
            let total = model.currentIntervalTotalCount
            // ⚠️ MiniMax API naming is misleading:
            // Despite being called "current_interval_usage_count", this field
            // actually represents the REMAINING count, not the used count.
            // Confirmed via MiniMax dashboard: when dashboard shows "3% used",
            // API returns usage_count=1459 out of total=1500 (i.e. 1459 remaining).
            // (MiniMax API 命名有误导性：usage_count 实际是剩余次数，非已用次数)
            let clampedRemaining = min(max(model.currentIntervalUsageCount, 0), total)
            let usedCount = total - clampedRemaining
            let remaining = total > 0 ? Double(clampedRemaining) / Double(total) * 100.0 : 0.0

            // Parse end_time as millisecond timestamp (毫秒时间戳)
            let resetsAt: Date? = model.endTime.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }

            let resetText = "\(usedCount)/\(total) requests"

            return UsageQuota(
                percentRemaining: remaining,
                quotaType: .modelSpecific(model.modelName),
                providerId: providerId,
                resetsAt: resetsAt,
                resetText: resetText
            )
        }

        return UsageSnapshot(
            providerId: providerId,
            quotas: quotas,
            capturedAt: Date()
        )
    }
}

// MARK: - Response Models (Internal)

struct MiniMaxRemainsResponse: Decodable {
    let baseResp: BaseResp
    let modelRemains: [ModelRemain]?
}

struct BaseResp: Decodable {
    let statusCode: Int
    let statusMsg: String?
}

struct ModelRemain: Decodable {
    let modelName: String
    let currentIntervalTotalCount: Int
    let currentIntervalUsageCount: Int
    let remainsTime: Int?
    let endTime: Int64?
}
