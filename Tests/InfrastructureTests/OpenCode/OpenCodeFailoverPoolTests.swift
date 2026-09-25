import Testing
import Foundation
@testable import Infrastructure

@Suite("OpenCodeFailoverPool Tests")
struct OpenCodeFailoverPoolTests {
    private let key = "oc_sTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTEST1"

    private func makeHome() throws -> (OpenCodeCredentialLoader, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-pool-tests-\(UUID().uuidString)", isDirectory: true)
        let auth = home.appendingPathComponent(".local/share/opencode")
        let cfg = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["opencode-go": ["type": "api", "key": "oc_sEXISTINGEXISTINGEXISTINGEXISTINGEXISTING"]])
            .write(to: auth.appendingPathComponent("auth.json"))
        try JSONSerialization.data(withJSONObject: ["tier1": ["slots": ["opencode-go", "opencode"],
            "accounts": [["slot": "opencode-go", "label": "compte 1"]]], "tier2": ["enabled": true]])
            .write(to: cfg.appendingPathComponent("failover-ssot.json"))
        return (OpenCodeCredentialLoader(homeDirectory: home.path, environment: [:]), home)
    }

    @Test
    func `enrol appends slot, label and key without touching the first slots`() throws {
        let (loader, _) = try makeHome()
        let slot = try OpenCodeFailoverPool(loader: loader).enroll(label: "Objects", key: key)
        #expect(slot == "opencode-objects")
        let pool = loader.loadPool()
        #expect(pool.map(\.slot) == ["opencode-go", "opencode-objects"])
        #expect(pool.last?.label == "Objects")
        #expect(pool.last?.key == key)
        let attrs = try FileManager.default.attributesOfItem(atPath: loader.authFilePath)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test
    func `enrol is idempotent for the same key`() throws {
        let (loader, _) = try makeHome()
        let pool = OpenCodeFailoverPool(loader: loader)
        let first = try pool.enroll(label: "Objects", key: key)
        let second = try pool.enroll(label: "Objects bis", key: key)
        #expect(first == second)
        #expect(loader.loadPool().count == 2)
    }

    @Test
    func `slug collision picks a free suffix and keeps other SSOT sections`() throws {
        #expect(OpenCodeFailoverPool.freeSlot(for: "Workspace Objects", taken: ["opencode-objects"]) == "opencode-objects-2")
        let (loader, home) = try makeHome()
        try OpenCodeFailoverPool(loader: loader).enroll(label: "Interwave", key: key)
        let data = try Data(contentsOf: home.appendingPathComponent(".config/opencode/failover-ssot.json"))
        let ssot = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(ssot?["tier2"] != nil)
    }
}
