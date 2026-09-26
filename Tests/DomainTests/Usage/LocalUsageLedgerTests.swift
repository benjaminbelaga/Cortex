import Testing
import Foundation
@testable import Domain

@Suite("LocalUsageLedger")
struct LocalUsageLedgerTests {

    private static let fixture = """
    {
      "generated_at": "2026-09-26T00:07:33.123456+00:00",
      "history_days": 7,
      "source_files": {"claude": 1587, "codex": 121, "opencode": 898},
      "sessions": {"tmux": 4},
      "cost_note": "cost_usd is published by OpenCode only",
      "days": {
        "2026-09-25": {
          "claude": {"input": 100, "output": 300, "cache_read": 1000, "cache_creation": 50,
                     "reasoning": 0, "messages": 5056, "cost_usd": null},
          "opencode": {"input": 136, "output": 42, "cache_read": 1801, "cache_creation": 4,
                       "reasoning": 0, "messages": 119, "cost_usd": 26.01}
        },
        "2026-09-26": {
          "claude": {"input": 10, "output": 20, "cache_read": 90, "cache_creation": 5,
                     "reasoning": 0, "messages": 87, "cost_usd": null}
        }
      }
    }
    """

    private func decode() throws -> LocalUsageLedger {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LocalUsageLedger.self, from: Data(Self.fixture.utf8))
    }

    @Test("decodes the ledger wire format (snake_case, null cost)")
    func decodesWireFormat() throws {
        let ledger = try decode()
        let claude = ledger.days["2026-09-25"]?["claude"]
        #expect(claude?.cacheRead == 1000)
        #expect(claude?.costUsd == nil, "null cost must decode as nil, never 0")
        #expect(ledger.days["2026-09-25"]?["opencode"]?.costUsd == 26.01)
    }

    @Test("totals include cache reads and perTool ranks the biggest consumer first")
    func totalsAndRanking() throws {
        let ledger = try decode()
        // 2026-09-26 only: claude 10+20+90+5 = 125
        #expect(ledger.tokens(lastDays: 1) == 125)
        // both days: claude (100+300+1000+50) + opencode (136+42+1801+4) + 125
        #expect(ledger.tokens(lastDays: 7) == 1450 + 1983 + 125)
        let tools = ledger.perTool(lastDays: 7)
        #expect(tools.first?.tool == "opencode")
        #expect(tools.first?.messages == 119)
    }

    @Test("cache split stays visible — nonCache excludes cache reads/creates")
    func cacheSplit() throws {
        let ledger = try decode()
        let claude = ledger.days["2026-09-25"]?["claude"]
        #expect(claude?.nonCacheTokens == 400)
        #expect(claude?.totalTokens == 1450)
    }
}
