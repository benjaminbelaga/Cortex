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

    // MARK: - v2 (measured windows, typed cost, source status)

    private static let v2Fixture = """
    {
      "schema_version": 2,
      "generated_at": "2026-09-26T05:38:09+02:00",
      "sources": {
        "claude": {"status": "ok", "files": 1587, "last_observed_at": "2026-09-26T05:30:00+02:00"},
        "opencode": {"status": "unsupported_schema", "error": "no such table: message"}
      },
      "windows": {
        "last24h": {
          "start": "2026-09-25T05:38:09+02:00",
          "end": "2026-09-26T05:38:09+02:00",
          "tools": {
            "claude": {"input": 100, "output": 300, "cache_read": 900, "cache_creation": 0,
                       "reasoning": 0, "messages": 12, "cost": {"kind": "unavailable", "usd": null}},
            "opencode": {"input": 100, "output": 100, "cache_read": 800, "cache_creation": 0,
                         "reasoning": 0, "messages": 40, "cost": {"kind": "declared", "usd": 12.5}}
          }
        },
        "last7d": {
          "start": "2026-09-19T05:38:09+02:00",
          "end": "2026-09-26T05:38:09+02:00",
          "tools": {
            "claude": {"input": 1000, "output": 3000, "cache_read": 9000, "cache_creation": 0,
                       "reasoning": 0, "messages": 120, "cost": {"kind": "unavailable", "usd": null}}
          }
        }
      },
      "days": {}
    }
    """

    private func decodeV2() throws -> LocalUsageLedger {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LocalUsageLedger.self, from: Data(Self.v2Fixture.utf8))
    }

    @Test("v2 windows decode with a computed cache share — never a hardcoded constant")
    func windowsCarryAMeasuredCacheShare() throws {
        let ledger = try decodeV2()
        let bucket = try #require(ledger.window("last24h")?.tools["claude"])
        #expect(bucket.totalTokens == 1300)
        let share = try #require(bucket.cacheShare)
        #expect(abs(share - 900.0 / 1300.0) < 0.0001)
        #expect(ledger.availableWindowNames == ["last24h", "last7d"])
        #expect(ledger.window("today") == nil)
    }

    @Test("typed cost distinguishes a declared price from an unavailable one")
    func typedCost() throws {
        let ledger = try decodeV2()
        let claude = try #require(ledger.window("last24h")?.tools["claude"]?.cost)
        #expect(!claude.isDeclared)
        #expect(claude.usd == nil)
        let opencode = try #require(ledger.window("last24h")?.tools["opencode"]?.cost)
        #expect(opencode.isDeclared)
        #expect(opencode.usd == 12.5)
    }

    @Test("a non-ok source surfaces instead of silently reading zero")
    func degradedSourceSurfaces() throws {
        let ledger = try decodeV2()
        #expect(ledger.degradedSources.map(\.name) == ["opencode"])
        #expect(ledger.degradedSources.first?.status.status == "unsupported_schema")
    }

    @Test("perTool(inWindow:) ranks the measured window, not the last stored day")
    func perWindowRanking() throws {
        let ledger = try decodeV2()
        let rows = ledger.perTool(inWindow: "last24h")
        #expect(rows.map(\.tool) == ["claude", "opencode"])
        #expect(rows.first?.bucket.messages == 12)
        #expect(ledger.perTool(inWindow: "today").isEmpty)
    }
}
