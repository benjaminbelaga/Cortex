import Foundation
import Testing
@testable import Infrastructure

@Suite("LLM runtime inspector")
struct LLMRuntimeInspectorTests {
    @Test("counts active mission envelope without depending on mission fields")
    func countsMissions() {
        let data = Data(#"{"missions":[{"id":"one"},{"id":"two"}]}"#.utf8)
        #expect(LLMRuntimeInspector.missionCount(from: data) == 2)
        #expect(LLMRuntimeInspector.missionCount(from: Data("[]".utf8)) == nil)
    }

    @Test("counts configured hook event entries")
    func countsHooks() {
        let data = Data(#"{"hooks":{"PreToolUse":[{},{}],"PostToolUse":[{}]},"secrets":{"ignored":true}}"#.utf8)
        #expect(LLMRuntimeInspector.configuredHookCount(from: data) == 3)
    }

    @Test("bounded agentctl probe terminates a stuck child instead of leaking it")
    func boundedProbeKillsStuckChild() async {
        // Regression 2026-09-19: a blocking agentctl left the child alive and every
        // refresh stacked another (17 orphans / 10 days). The bounded probe must
        // return nil on deadline rather than wait for the child.
        let started = Date()
        let result = await LLMRuntimeInspector.runAgentctlMissionListWithDeadline(
            executable: "/bin/sleep", arguments: ["3600"], timeoutSeconds: 2)
        let elapsed = Date().timeIntervalSince(started)

        #expect(result == nil)
        #expect(elapsed < 8, "must terminate on deadline, not wait for the child (was \(elapsed)s)")
    }

    @Test("bounded agentctl probe returns the mission count for a fast child")
    func boundedProbeCountsMissions() async {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-agentctl-\(UUID().uuidString)")
        try? #"""
#!/bin/sh
printf '{"missions":[{"id":"one"},{"id":"two"}]}'
"""#.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let count = await LLMRuntimeInspector.runAgentctlMissionListWithDeadline(
            executable: script.path, arguments: [], timeoutSeconds: 10)
        #expect(count == 2)
    }
}
