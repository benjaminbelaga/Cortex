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

    @Test("a mission with only its creation row proves registration and nothing more")
    func creationRowIsNotProgress() {
        let rows = [MissionPlaneRow(missionId: "msn_a", objective: "op")]

        let projected = MissionPlaneReader.project(rows, receipts: [:])

        #expect(projected.count == 1)
        #expect(projected[0].steps == [.registered])
        #expect(projected[0].harness == nil)
        #expect(projected[0].receiptAt == nil)
    }

    @Test("each plane fact adds exactly one proven step, in order")
    func planeFactsBecomeSteps() {
        let rows = [
            MissionPlaneRow(
                missionId: "msn_a",
                objective: "op",
                worktree: "/Users/x/worktrees/repo/claude-1",
                phase: "canary",
                runtime: "codex",
                leaseCount: 2,
                updatedAt: "2026-09-26T16:34:39.715Z"
            )
        ]
        let receipt = Date(timeIntervalSince1970: 1_772_000_000)

        let projected = MissionPlaneReader.project(rows, receipts: ["msn_a": receipt])

        #expect(projected[0].steps == [.registered, .leased, .bound, .terminalOpened])
        #expect(projected[0].harness == "codex")
        #expect(projected[0].receiptAt == receipt)
        #expect(projected[0].updatedAt != nil)
        #expect(projected[0].worktreeName == "claude-1")
    }

    @Test("a receipt with an unreadable timestamp still proves the terminal opened")
    func receiptWithoutTimestampStillProves() {
        let rows = [MissionPlaneRow(missionId: "msn_a", objective: "op")]

        let projected = MissionPlaneReader.project(rows, receipts: ["msn_a": nil])

        #expect(projected[0].steps == [.registered, .terminalOpened])
        #expect(projected[0].receiptAt == nil)
    }

    @Test("an unreadable receiving plane yields no missions instead of guessed ones")
    func missingPlaneIsEmpty() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-plane-\(UUID().uuidString)")

        #expect(MissionPlaneReader.read(home: home, limit: 5).isEmpty)
        #expect(MissionPlaneReader.receipts(home: home).isEmpty)
    }

    @Test("receipt files are keyed by mission id and tolerate a broken file")
    func receiptsAreKeyedByMission() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("plane-\(UUID().uuidString)")
        let directory = MissionPlaneReader.receiptsDirectory(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try #"{"mission_id":"msn_ok","ts":"2026-09-26T16:34:39.865013+00:00"}"#
            .write(to: directory.appendingPathComponent("msn_ok.json"), atomically: true, encoding: .utf8)
        try "{ not json".write(
            to: directory.appendingPathComponent("msn_broken.json"), atomically: true, encoding: .utf8)
        try "ignored".write(
            to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let receipts = MissionPlaneReader.receipts(home: home)

        // Presence is the evidence, the date is best-effort: a broken receipt
        // must still key its mission (regression 2026-09-27 — an optional-nil
        // assignment silently dropped the key).
        #expect(receipts.keys.sorted() == ["msn_broken", "msn_ok"])
        #expect(receipts["msn_ok"] ?? nil != nil)
        #expect((receipts["msn_broken"] ?? nil) == nil)
    }
}
