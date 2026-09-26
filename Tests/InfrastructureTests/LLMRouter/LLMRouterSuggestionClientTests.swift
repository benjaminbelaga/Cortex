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
