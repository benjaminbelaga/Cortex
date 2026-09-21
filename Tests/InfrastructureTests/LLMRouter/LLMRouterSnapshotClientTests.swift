import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("LLMRouterSnapshotClient")
struct LLMRouterSnapshotClientTests {
    @Test("v2 parser preserves normalized fractions")
    func preservesNormalizedFractions() throws {
        let snapshot = try LLMRouterSnapshotClient.parse(Self.payload())

        #expect(snapshot.providers["claude"]?.windows.first?.remainingFraction == 0.58)
        #expect(snapshot.providers["claude"]?.accounts.map(\.alias) == ["WORK", "PERSONAL"])
        #expect(snapshot.providers["claude"]?.accounts[1].present == false)
        #expect(snapshot.providers["claude"]?.forecast?.severity == "orange")
        #expect(snapshot.providers["claude"]?.forecast?.burnRatePercentPerHour == 12.5)
    }

    @Test("concurrent provider refreshes execute one router command")
    func coalescesConcurrentCalls() async throws {
        let runner = StubRunner(results: [.success(Self.payload())], delay: .milliseconds(100))
        let client = LLMRouterSnapshotClient(
            runner: runner,
            executableResolver: { "/bin/echo" },
            forcedCoalescingWindow: 0,
            snapshotCacheURL: nil
        )

        async let first = client.snapshot(forceRefresh: true, usageMaxAgeSeconds: 60)
        async let second = client.snapshot(forceRefresh: true, usageMaxAgeSeconds: 60)
        async let third = client.snapshot(forceRefresh: true, usageMaxAgeSeconds: 60)
        _ = try await (first, second, third)

        #expect(await runner.callCount == 1)
        #expect(await runner.lastArguments == [
            "status", "--format", "json-v2", "--usage-max-age-seconds", "60",
        ])
    }

    @Test("failed refresh returns an explicitly stale last-good snapshot")
    func fallsBackToLastGoodSnapshot() async throws {
        let runner = StubRunner(results: [
            .success(Self.payload()),
            .failure(StubFailure.commandFailed),
        ])
        let client = LLMRouterSnapshotClient(
            runner: runner,
            executableResolver: { "/bin/echo" },
            forcedCoalescingWindow: 0,
            snapshotCacheURL: nil
        )

        let fresh = try await client.snapshot(forceRefresh: true, usageMaxAgeSeconds: 0)
        let fallback = try await client.snapshot(forceRefresh: true, usageMaxAgeSeconds: 0)

        #expect(fresh.isStale == false)
        #expect(fallback.isStale == true)
        #expect(fallback.fallbackError?.contains("commandFailed") == true)
        #expect(fallback.providers == fresh.providers)
        #expect(fallback.usage == fresh.usage)
        #expect(fallback.costEstimate == fresh.costEstimate)
        #expect(await runner.callCount == 2)
    }

    @Test("usage freshness metadata and unpriced Qwen decode additively")
    func decodesUsageFreshnessAndQwen() throws {
        let snapshot = try LLMRouterSnapshotClient.parse(Self.payload())
        let usage = try #require(snapshot.usage)

        #expect(usage.cacheAgeSeconds == 12)
        #expect(usage.isStale == false)
        #expect(usage.isPartial == true)
        #expect(usage.partialSources == ["qwen"])
        #expect(usage.last24h?.byModel["qwen3.8-max"]?.totalTokens == 1_050)
        #expect(snapshot.costEstimate?.last24h?.unpricedModels == ["qwen3.8-max"])
        #expect(snapshot.costEstimate?.reportingCurrency == "EUR")
        #expect(snapshot.costEstimate?.last24h?.totalEur == 0)
        #expect(snapshot.costEstimate?.fxObservedAt == "2026-08-24")
    }

    @Test("usage anomalies are decoded and surfaced on the snapshot")
    func decodesUsageAnomalies() throws {
        let snapshot = try LLMRouterSnapshotClient.parse(Self.payload())
        #expect(snapshot.usageAnomalies.count == 1)
        let anomaly = try #require(snapshot.usageAnomalies.first)
        #expect(anomaly.window == "24h")
        #expect(anomaly.backend == "qwen")
        #expect(anomaly.flags == ["large_context", "partial"])
        #expect(anomaly.inputTokens == 250_000)
    }

    @Test("validated snapshot persists for cold-start hydration")
    func persistsLastKnownSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("router-snapshot-v2.json")
        let first = LLMRouterSnapshotClient(
            runner: StubRunner(results: [.success(Self.payload())]),
            executableResolver: { "/bin/echo" },
            forcedCoalescingWindow: 0,
            snapshotCacheURL: cacheURL
        )
        _ = try await first.snapshot(forceRefresh: true, usageMaxAgeSeconds: 0)

        let relaunched = LLMRouterSnapshotClient(
            runner: StubRunner(results: []),
            executableResolver: { "/bin/echo" },
            snapshotCacheURL: cacheURL
        )
        let restored = await relaunched.lastKnownSnapshot()

        #expect(restored?.usage?.last24h?.byModel["qwen3.8-max"]?.messages == 1)
    }

    @Test("percentages above one are rejected as contract drift")
    func rejectsWholePercentValues() {
        #expect(throws: RouterQuotaIssue.self) {
            try LLMRouterSnapshotClient.parse(Self.payload(remaining: 58))
        }
    }

    @Test("schema-required nullable fields cannot silently disappear")
    func rejectsMissingRequiredNullableField() throws {
        let valid = try #require(String(data: Self.payload(), encoding: .utf8))
        let missingGrade = valid.replacingOccurrences(of: "\"grade\": \"B\",", with: "")

        #expect(throws: RouterQuotaIssue.self) {
            try LLMRouterSnapshotClient.parse(Data(missingGrade.utf8))
        }
    }

    private static func payload(remaining: Double = 0.58) -> Data {
        Data(
            """
            {
              "schema_version": 2,
              "generated_at": "2026-08-21T00:00:00+00:00",
              "providers": {
                "claude": {
                  "provider_id": "claude",
                  "windows": [{
                    "kind": "five_hour",
                    "remaining_pct": \(remaining),
                    "limit": null,
                    "unit": null,
                    "resets_at": "2026-08-21T05:00:00Z",
                    "note": null
                  }],
                  "error": null,
                  "source": "quota_broker",
                  "grade": "B",
                  "captured_at": 1787263200,
                  "manual": false,
                  "accounts": [
                    {
                      "alias": "WORK",
                      "windows": [{
                        "kind": "five_hour",
                        "remaining_pct": \(remaining),
                        "limit": null,
                        "unit": null,
                        "resets_at": null,
                        "note": null
                      }],
                      "present": true,
                      "error": null,
                      "source": "claude-swap",
                      "active": true,
                      "stale": false
                    },
                    {
                      "alias": "PERSONAL",
                      "windows": [],
                      "present": false,
                      "error": "compte attendu absent du relevé",
                      "source": null,
                      "active": false,
                      "stale": false
                    }
                  ],
                  "warnings": ["PERSONAL: compte attendu absent du relevé"],
                  "forecast": {
                    "window_kind": "five_hour",
                    "sample_count": 12,
                    "observation_hours": 3.5,
                    "confidence": "early",
                    "burn_rate_pct_per_hour": 12.5,
                    "projected_exhaustion_at": "2026-08-21T04:30:00Z",
                    "projected_remaining_at_reset_pct": 0,
                    "severity": "orange"
                  },
                  "effective_headroom": \(remaining),
                  "confidence": "fresh",
                  "age_seconds": 2
                }
              },
              "usage": {
                "generated_at": "2026-08-25T08:00:00+00:00",
                "source_updated_at": "2026-08-25T07:59:58+00:00",
                "cache_age_seconds": 12,
                "is_stale": false,
                "is_partial": true,
                "partial_sources": ["qwen"],
                "refresh_error": null,
                "24h": {
                  "by_model": {
                    "qwen3.8-max": {
                      "input_tokens": 200,
                      "output_tokens": 50,
                      "cache_read_tokens": 800,
                      "cache_creation_tokens": 0,
                      "messages": 1
                    }
                  },
                  "by_backend": {},
                  "sessions_by_harness": {"qwen": 1},
                  "totals": {
                    "input_tokens": 200,
                    "output_tokens": 50,
                    "cache_read_tokens": 800,
                    "cache_creation_tokens": 0,
                    "messages": 1
                  }
                },
                "7d": null
              },
              "usage_anomalies": [
                {
                  "window": "24h",
                  "harness": "qwen",
                  "backend": "qwen",
                  "flags": ["large_context", "partial"],
                  "input_tokens": 250000,
                  "cache_read_tokens": 0,
                  "messages": 1
                }
              ],
              "cost_estimate": {
                "verified": false,
                "reporting_currency": "EUR",
                "pricing_sources": ["https://developers.openai.com/api/docs/models/gpt-5.6-sol"],
                "fx_reference": {
                  "usd_per_eur": 1.1664,
                  "observed_at": "2026-08-24",
                  "source_url": "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html"
                },
                "24h": {
                  "by_model_usd": {},
                  "by_model_eur": {},
                  "total_usd": 0,
                  "total_eur": 0,
                  "usd_per_mtok": null,
                  "usd_per_session": null,
                  "coverage_pct": 0,
                  "unpriced_models": ["qwen3.8-max"]
                },
                "7d": null
              }
            }
            """.utf8
        )
    }
}

@Suite("LLMRouterProcessRunner (real subprocess)")
struct LLMRouterProcessRunnerTests {
    @Test("a non-zero router exit surfaces as RouterQuotaIssue with the stderr tail")
    func nonZeroExitMapsToRouterQuotaIssue() async throws {
        let runner = LLMRouterProcessRunner()
        await #expect(throws: RouterQuotaIssue.self) {
            _ = try await runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "echo boom 1>&2; exit 2"],
                timeout: 10
            )
        }
    }

    @Test("stdout is returned verbatim on success")
    func successReturnsStdout() async throws {
        let runner = LLMRouterProcessRunner()
        let data = try await runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '{\"ok\":1}'"],
            timeout: 10
        )
        #expect(String(decoding: data, as: UTF8.self) == "{\"ok\":1}")
    }
}

private enum StubFailure: Error, LocalizedError {
    case commandFailed

    var errorDescription: String? { "commandFailed" }
}

private actor StubRunner: LLMRouterCommandRunning {
    private var results: [Result<Data, Error>]
    private let delay: Duration?
    private(set) var callCount = 0
    private(set) var lastArguments: [String] = []

    init(results: [Result<Data, Error>], delay: Duration? = nil) {
        self.results = results
        self.delay = delay
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        callCount += 1
        lastArguments = arguments
        if let delay { try await Task.sleep(for: delay) }
        guard !results.isEmpty else { throw StubFailure.commandFailed }
        return try results.removeFirst().get()
    }
}
