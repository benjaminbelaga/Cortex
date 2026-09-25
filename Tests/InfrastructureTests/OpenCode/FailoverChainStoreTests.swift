import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("FailoverChainStore Tests")
struct FailoverChainStoreTests {

    private func makeHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failover-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".config/opencode"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude/state"),
                                                withIntermediateDirectories: true)
        return dir
    }

    private func write(_ home: URL, _ relative: String, _ json: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: home.appendingPathComponent(relative))
    }

    private func read(_ home: URL, _ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(relative))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func `reactivate removes only the named slot and keeps siblings`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude/state/opencode-go-failover-quarantine.json",
                  ["opencode-go": 111, "opencode": 222])

        let store = FailoverChainStore(homeDirectory: home.path)
        #expect(store.reactivate(slot: "opencode-go", pool: .go))

        let after = try read(home, ".claude/state/opencode-go-failover-quarantine.json")
        #expect(after["opencode-go"] == nil)
        #expect((after["opencode"] as? Int) == 222)
    }

    @Test func `reactivate on an absent slot is a no-op`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude/state/ollama-cloud-failover-quarantine.json", ["ollama-cloud": 1])
        let store = FailoverChainStore(homeDirectory: home.path)
        #expect(!store.reactivate(slot: "nope", pool: .ollama))
        #expect((try read(home, ".claude/state/ollama-cloud-failover-quarantine.json"))["ollama-cloud"] as? Int == 1)
    }

    @Test func `setTier2 flips the switch without touching other keys`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".config/opencode/failover-ssot.json", [
            "tier1": ["slots": ["opencode-go"]],
            "tier2": ["enabled": true, "mode": "fallback",
                      "fallback": ["providerID": "ollama-cloud", "modelID": "deepseek-v4.1-flash"]],
        ])

        let store = FailoverChainStore(homeDirectory: home.path)
        #expect(store.setTier2(enabled: false))

        let after = try read(home, ".config/opencode/failover-ssot.json")
        let tier2 = after["tier2"] as? [String: Any]
        #expect((tier2?["enabled"] as? Bool) == false)
        // The chain the plugins read is otherwise untouched.
        #expect((tier2?["mode"] as? String) == "fallback")
        #expect((after["tier1"] as? [String: Any])?["slots"] as? [String] == ["opencode-go"])
    }

    @Test func `a round-trip through the reader reflects a reactivation`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".config/opencode/failover-ssot.json", ["tier1": ["slots": ["opencode-go", "opencode"]]])
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try write(home, ".claude/state/opencode-go-failover-quarantine.json",
                  ["opencode-go": now.timeIntervalSince1970 * 1000 + 3_600_000])

        let store = FailoverChainStore(homeDirectory: home.path)
        let reader = FailoverChainReader(homeDirectory: home.path, now: { now })
        #expect(reader.read().servingGo?.slot == "opencode")

        _ = store.reactivate(slot: "opencode-go", pool: .go)
        #expect(reader.read().servingGo?.slot == "opencode-go")
    }
}
