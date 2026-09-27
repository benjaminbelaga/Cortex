import Foundation
import Testing
@testable import Infrastructure

@Suite("LLMRouterSuggestionClient")
struct LLMRouterSuggestionClientTests {
    @Test("suggest passes the mission and selected load to llm-router")
    func buildsArguments() async throws {
        let runner = SuggestionStubRunner(payload: Self.payload())
        let client = LLMRouterSuggestionClient(
            runner: runner,
            executableResolver: { "/bin/echo" }
        )

        let suggestion = try await client.suggest(mission: "repair checkout", load: .heavy)

        #expect(await runner.arguments == [
            "suggest", "repair checkout", "--criticality", "high", "--json",
        ])
        #expect(suggestion.candidates.map(\.launcherCommand) == ["claude-minimax", "claude-bedrock think"])
        #expect(suggestion.candidates.first?.quotaHeadroomPercent == 62)
    }

    @Test("candidates without a catalog launcher never reach the UI")
    func omitsUnlaunchableCandidate() throws {
        let suggestion = try LLMRouterSuggestionClient.parse(Self.payload())

        #expect(suggestion.candidates.count == 2)
        #expect(suggestion.candidates.allSatisfy { !$0.launcherCommand.isEmpty })
    }

    @Test("two accounts on the same provider and model get distinct identities")
    func twoAccountsAreDistinctRoutes() throws {
        let suggestion = try LLMRouterSuggestionClient.parse(Self.twoAccountPayload())

        #expect(suggestion.candidates.count == 2)
        #expect(suggestion.candidates[0].provider == suggestion.candidates[1].provider)
        #expect(suggestion.candidates[0].model == suggestion.candidates[1].model)
        // T11: same model, two accounts — a route identity that stopped at
        // provider:model handed SwiftUI's ForEach a duplicate id.
        #expect(suggestion.candidates[0].id != suggestion.candidates[1].id)
        #expect(Set(suggestion.candidates.map(\.id)).count == 2)
        #expect(suggestion.candidates[0].account?.label == "go-1")
        #expect(suggestion.candidates[1].account?.label == "go-2")
    }

    @Test("effort and launcher also separate routes on the same model")
    func effortAndLauncherSeparateRoutes() throws {
        let suggestion = try LLMRouterSuggestionClient.parse(Self.effortPayload())

        #expect(suggestion.candidates[0].id != suggestion.candidates[1].id)
        #expect(suggestion.candidates[0].effort == "high")
    }

    @Test("a single-account candidate keeps a stable, secret-free identity")
    func singleAccountIdentityIsStable() throws {
        let suggestion = try LLMRouterSuggestionClient.parse(Self.payload())

        // No account dimension in this payload → identity stays provider:model,
        // and the launcher id joins it only when a structured plan carries one.
        #expect(suggestion.candidates[0].account == nil)
        #expect(suggestion.candidates[0].id == "minimax_max:MiniMax-M2.5-highspeed")
    }

    @Test("the decision carries its own provenance and rejected routes")
    func decisionProvenanceIsDecoded() throws {
        let suggestion = try LLMRouterSuggestionClient.parse(Self.realShapedPayload())

        // The engine stamps the decision; Cortex shows its age (audit V2 §12).
        #expect(suggestion.generatedAt != nil)
        #expect(suggestion.privacy == "internal")
        #expect(suggestion.contextEstimate == 100_000)
        #expect(suggestion.fallbackChain == ["deepseek", "bedrock"])
        #expect(suggestion.waitSuggestion == nil)
        #expect(suggestion.ineligible.count == 1)
        #expect(suggestion.ineligible[0].provider == "kimi")
        #expect(suggestion.ineligible[0].reasons.first?.contains("quota") == true)
    }

    @Test("quota provenance is exposed, and a missing age stays unknown")
    func quotaProvenanceIsHonest() throws {
        let suggestion = try LLMRouterSuggestionClient.parse(Self.realShapedPayload())

        #expect(suggestion.candidates[0].statusSource == "quota_broker")
        #expect(suggestion.candidates[0].statusAgeMinutes == 12.5)
        #expect(suggestion.candidates[0].timeMultiplier == 0.5)
        #expect(suggestion.candidates[0].penalties == ["latency=0.2"])
        // Second route: the engine reports no age. Unknown is not zero.
        #expect(suggestion.candidates[1].statusAgeMinutes == nil)
        #expect(suggestion.candidates[1].statusSource == nil)
    }

    @Test("the router's microsecond timestamps parse")
    func microsecondTimestampsParse() {
        // Shape captured live from `llm-router suggest --json`.
        let parsed = LLMRouterSuggestionClient.parseTimestamp("2026-09-27T15:22:34.045801+02:00")

        #expect(parsed != nil)
        #expect(LLMRouterSuggestionClient.parseTimestamp("2026-09-27T15:22:34Z") != nil)
        #expect(LLMRouterSuggestionClient.parseTimestamp(nil) == nil)
        #expect(LLMRouterSuggestionClient.parseTimestamp("not a date") == nil)
    }

    private static func realShapedPayload() -> Data {
        Data(
            """
            {
              "mission_id": "m-456",
              "task_class": "EXECUTE_COMPLEX",
              "generated_at": "2026-09-27T15:22:34.045801+02:00",
              "privacy": "internal",
              "context_estimate": 100000,
              "fallback_chain": ["deepseek", "bedrock"],
              "suggest_wait_until": null,
              "ineligible": [
                {"provider": "kimi", "reasons": ["quota épuisé/réserve atteinte (restant 0%)"]}
              ],
              "recommended": {
                "provider": "claude", "model": "sonnet", "score": 0.88,
                "launcher_command": "claude-broker",
                "quota_headroom_pct": 0.42, "reasons": ["quota healthy"], "warnings": [],
                "eligible": true, "time_multiplier": 0.5,
                "penalties": ["latency=0.2"],
                "status_source": "quota_broker", "status_age_min": 12.5
              },
              "alternatives": [
                {
                  "provider": "bedrock", "model": "think", "score": 0.7,
                  "launcher_command": "claude-bedrock think",
                  "quota_headroom_pct": 0.9, "reasons": [], "warnings": [],
                  "eligible": true, "penalties": []
                }
              ],
              "explanation": ["Mission classée EXECUTE_COMPLEX"],
              "warnings": []
            }
            """.utf8
        )
    }

    private static func twoAccountPayload() -> Data {
        Data(
            """
            {
              "mission_id": "m-123",
              "task_class": "EXECUTE_COMPLEX",
              "recommended": {
                "provider": "opencode_go", "model": "kimi-k2",
                "score": 0.9, "launcher_command": "opencode run go-1",
                "quota_headroom_pct": 0.4, "reasons": [], "warnings": [],
                "account": {"id": "acct-1", "alias": "go-1", "identity": "account one"}
              },
              "alternatives": [
                {
                  "provider": "opencode_go", "model": "kimi-k2",
                  "score": 0.8, "launcher_command": "opencode run go-2",
                  "quota_headroom_pct": 0.3, "reasons": [], "warnings": [],
                  "account": {"id": "acct-2", "alias": "go-2", "identity": "account two"}
                }
              ],
              "explanation": [],
              "warnings": []
            }
            """.utf8
        )
    }

    private static func effortPayload() -> Data {
        Data(
            """
            {
              "mission_id": "m-123",
              "task_class": "EXECUTE_COMPLEX",
              "recommended": {
                "provider": "claude", "model": "opus", "effort": "high",
                "score": 0.9, "launcher_command": "claude-high",
                "quota_headroom_pct": 0.5, "reasons": [], "warnings": []
              },
              "alternatives": [
                {
                  "provider": "claude", "model": "opus", "effort": "low",
                  "score": 0.7, "launcher_command": "claude-low",
                  "quota_headroom_pct": 0.5, "reasons": [], "warnings": []
                }
              ],
              "explanation": [],
              "warnings": []
            }
            """.utf8
        )
    }

    private static func payload() -> Data {
        Data(
            """
            {
              "mission_id": "m-123",
              "task_class": "EXECUTE_COMPLEX",
              "recommended": {
                "provider": "minimax_max", "model": "MiniMax-M2.5-highspeed",
                "score": 0.91, "launcher_command": "claude-minimax",
                "quota_headroom_pct": 0.62, "reasons": ["quota healthy"], "warnings": []
              },
              "alternatives": [
                {
                  "provider": "bedrock", "model": "think", "score": 0.84,
                  "launcher_command": "claude-bedrock think", "quota_headroom_pct": 0.90,
                  "reasons": ["zero cash"], "warnings": []
                },
                {
                  "provider": "unconfigured", "model": "x", "score": 0.7,
                  "launcher_command": null, "quota_headroom_pct": null,
                  "reasons": [], "warnings": []
                }
              ],
              "explanation": ["Mission classée EXECUTE_COMPLEX"],
              "warnings": []
            }
            """.utf8
        )
    }
}

private actor SuggestionStubRunner: LLMRouterCommandRunning {
    private let payload: Data
    private(set) var arguments: [String] = []

    init(payload: Data) {
        self.payload = payload
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        self.arguments = arguments
        return payload
    }
}
