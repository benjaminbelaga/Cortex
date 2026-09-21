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
