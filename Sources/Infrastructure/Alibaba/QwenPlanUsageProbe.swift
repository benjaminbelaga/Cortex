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

    public func probe() async throws -> UsageSnapshot {
        guard let executable = BinaryLocator.findInCommonPaths("bl") else { throw ProbeError.cliNotFound("bl") }
        let result = try await runner.run(executable: executable, arguments: [
            "usage", "token-plan", "--output", "json", "--config", profile,
            "--console-site", site, "--console-region", region, "--timeout", "20"
        ], options: .init(timeout: 25, maxBytesPerStream: 128 * 1024, terminationGrace: 1))
        guard result.exitStatus == 0 else {
            // Never surface console output that might contain an authentication URL.
            throw ProbeError.sessionExpired(hint: "Connectez la console Alibaba avec bl auth login --console, puis actualisez.")
        }
        return try Self.parse(result.stdout)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.parseFailed("Invalid Token Plan quota response")
        }
        var quotas: [UsageQuota] = []
        for (prefix, type, duration) in [("per5Hour", QuotaType.session, 18000.0), ("per1Week", .weekly, 604800.0)] {
            guard let used = (root[prefix + "Percentage"] as? NSNumber)?.doubleValue, used.isFinite, used >= 0 else { continue }
            let rawReset = (root[prefix + "ResetTime"] as? NSNumber)?.doubleValue
            let reset = rawReset.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) : nil }
            quotas.append(.init(percentRemaining: max(0, min(100, (1 - used) * 100)),
                quotaType: type, providerId: "qwen", resetsAt: reset, windowDuration: duration))
        }
        guard !quotas.isEmpty else { throw ProbeError.parseFailed("Aucune fenêtre Token Plan publiée par la console.") }
        return UsageSnapshot(providerId: "qwen", quotas: quotas, capturedAt: now)
    }
}
