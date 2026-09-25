import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("FailoverChainReader Tests")
struct FailoverChainReaderTests {

    private func makeHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failover-chain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".config/opencode"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude/state"),
                                                withIntermediateDirectories: true)
        return dir
    }

    private func write(_ home: URL, _ relative: String, _ json: [String: Any]) throws {
        let url = home.appendingPathComponent(relative)
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func `orders go then ollama and marks the first go slot as head`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".config/opencode/failover-ssot.json", [
            "tier1": ["slots": ["opencode-go", "opencode"],
                      "accounts": [["slot": "opencode-go", "label": "Compte 1"],
                                   ["slot": "opencode", "label": "Compte 2"]]],
            "ollama_pool": ["slots": ["ollama-cloud"],
                            "accounts": [["slot": "ollama-cloud", "label": "Ollama 1"]]],
            "tier2": ["enabled": true, "fallback": ["providerID": "ollama-cloud", "modelID": "deepseek-v4.1-flash"]],
        ])

        let state = FailoverChainReader(homeDirectory: home.path, now: { self.now }).read()

        #expect(state.goSlots.map(\.slot) == ["opencode-go", "opencode"])
        #expect(state.ollamaSlots.map(\.slot) == ["ollama-cloud"])
        #expect(state.goSlots.first?.status == .head)
        #expect(state.goSlots.last?.status == .healthy)
        #expect(state.ollamaSlots.first?.status == .head)
        #expect(state.tier2Target == "ollama-cloud/deepseek-v4.1-flash")
        #expect(state.ollamaArmed)
    }

    @Test func `a future quarantine benches the slot and promotes the next`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".config/opencode/failover-ssot.json", [
            "tier1": ["slots": ["opencode-go", "opencode"]],
        ])
        let untilMs = now.timeIntervalSince1970 * 1000 + 3_600_000
        try write(home, ".claude/state/opencode-go-failover-quarantine.json",
                  ["opencode-go": untilMs])

        let state = FailoverChainReader(homeDirectory: home.path, now: { self.now }).read()

        #expect(state.goSlots[0].status == .quarantined(until: Date(timeIntervalSince1970: untilMs / 1000)))
        #expect(state.goSlots[1].status == .head)
        #expect(state.servingGo?.slot == "opencode")
    }

    @Test func `an expired quarantine does not bench the slot`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".config/opencode/failover-ssot.json", ["tier1": ["slots": ["opencode-go"]]])
        try write(home, ".claude/state/opencode-go-failover-quarantine.json",
                  ["opencode-go": now.timeIntervalSince1970 * 1000 - 1_000])

        let state = FailoverChainReader(homeDirectory: home.path, now: { self.now }).read()
        #expect(state.goSlots.first?.status == .head)
    }

    @Test func `tier2 disabled or all ollama quarantined is not armed`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".config/opencode/failover-ssot.json", [
            "ollama_pool": ["slots": ["ollama-cloud"]],
            "tier2": ["enabled": false, "fallback": ["providerID": "ollama-cloud", "modelID": "deepseek-v4.1-flash"]],
        ])
        let disabled = FailoverChainReader(homeDirectory: home.path, now: { self.now }).read()
        #expect(!disabled.ollamaArmed)

        try write(home, ".config/opencode/failover-ssot.json", [
            "ollama_pool": ["slots": ["ollama-cloud"]],
            "tier2": ["enabled": true, "fallback": ["providerID": "ollama-cloud", "modelID": "deepseek-v4.1-flash"]],
        ])
        try write(home, ".claude/state/ollama-cloud-failover-quarantine.json",
                  ["ollama-cloud": now.timeIntervalSince1970 * 1000 + 3_600_000])
        let allQuarantined = FailoverChainReader(homeDirectory: home.path, now: { self.now }).read()
        #expect(!allQuarantined.ollamaArmed)
    }

    @Test func `counts sessions replaying on the fallback`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude/state/opencode-provider-fallback-origin.json", [
            "ses_a": ["providerID": "opencode", "modelID": "glm-5.3-flash", "switchedAt": 1],
            "ses_b": ["providerID": "opencode-go", "modelID": "deepseek-v4.1-flash", "switchedAt": 1],
        ])
        let state = FailoverChainReader(homeDirectory: home.path, now: { self.now }).read()
        #expect(state.sessionsOnOllama == 2)
    }

    @Test func `missing files yield the empty state without throwing`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let state = FailoverChainReader(homeDirectory: home.path, now: { self.now }).read()
        #expect(state.slots.isEmpty)
        #expect(!state.tier2Enabled)
        #expect(state.tier2Target == nil)
        #expect(!state.ollamaArmed)
    }
}
