import Foundation
import Domain

/// Official Bailian console quota, never an inference request with a subscription key.
public struct QwenPlanUsageProbe: UsageProbe {
    private let profile: String
    private let site: String
    private let region: String
    private let runner: BoundedProcessRunner

    public init(profile: String = "default", site: String = "international", region: String = "ap-southeast-1",
                runner: BoundedProcessRunner = BoundedProcessRunner()) {
        self.profile = profile
        self.site = site
        self.region = region
        self.runner = runner
    }

    public func isAvailable() async -> Bool { BinaryLocator.findInCommonPaths("bl") != nil }

    /// Compile-time constant: the console endpoint is never read from settings,
    /// an environment variable or a remote source (security review QB1).
    static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"

    public func probe() async throws -> UsageSnapshot {
        guard let executable = BinaryLocator.findInCommonPaths("bl") else { throw ProbeError.cliNotFound("bl") }
        var arguments = [
            "console", "call",
            "--api", Self.usageAPI,
            "--data", "{}",
            "--output", "json",
        ]
        // `default` means "no named profile": let `bl` fall back to its active
        // console config instead of demanding a profile that may not exist (a
        // bogus name yields "No console access token found").
        if !profile.isEmpty, profile != "default" { arguments += ["--config", profile] }
        arguments += ["--console-site", site, "--console-region", region, "--timeout", "20"]
        let result = try await runner.run(executable: executable, arguments: arguments,
            options: .init(timeout: 25, maxBytesPerStream: 128 * 1024, terminationGrace: 1))
        guard result.exitStatus == 0 else {
            // Never surface console output that might contain an authentication URL.
            AppLog.probes.warning("QwenPlan: console call failed — console session likely missing")
            throw ProbeError.sessionExpired(hint: "Connect the Alibaba console with bl auth login --console, then refresh.")
        }
        let snapshot = try Self.parse(result.stdout)
        AppLog.probes.info("QwenPlan: live console quota fetched — \(snapshot.quotas.count) window(s)")
        return snapshot
    }

    /// The console gateway wraps the payload as `data.DataV2.data.data`; an
    /// unwrapped/older shape may publish the percentages at the root. Accept
    /// both, never guess.
    static func quotaFields(in root: [String: Any]) -> [String: Any] {
        if let data = root["data"] as? [String: Any],
           let dataV2 = data["DataV2"] as? [String: Any],
           let gateway = dataV2["data"] as? [String: Any],
           let inner = gateway["data"] as? [String: Any] {
            return inner
        }
        return root
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.parseFailed("Invalid Token Plan quota response")
        }
        let root = Self.quotaFields(in: raw)
        var quotas: [UsageQuota] = []
        // Edition 2026-09-22 dropped the weekly cap for a monthly credit envelope
        // (bible §4.1): read whichever windows the console publishes; an absent
        // window stays absent ("non applicable"), never a synthetic 100 %.
        let windows: [(String, QuotaType, Double?)] = [
            ("per5Hour", .session, 18000), ("per1Week", .weekly, 604800),
            ("per1Month", .timeLimit("Monthly"), nil), ("perMonth", .timeLimit("Monthly"), nil),
        ]
        for (prefix, type, duration) in windows {
            if type == .timeLimit("Monthly"), quotas.contains(where: { $0.quotaType == type }) { continue }
            guard let used = (root[prefix + "Percentage"] as? NSNumber)?.doubleValue, used.isFinite, used >= 0 else { continue }
            let rawReset = (root[prefix + "ResetTime"] as? NSNumber)?.doubleValue
            let reset = rawReset.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) : nil }
            quotas.append(.init(percentRemaining: max(0, min(100, (1 - used) * 100)),
                quotaType: type, providerId: "qwen", resetsAt: reset, windowDuration: duration))
        }
        guard !quotas.isEmpty else { throw ProbeError.parseFailed("No Token Plan window published by the console.") }
        return UsageSnapshot(providerId: "qwen", quotas: quotas, capturedAt: now)
    }
}
