import Foundation
import Testing
import Domain
@testable import Infrastructure

@Suite("AlibabaAuthStatus")
struct AlibabaAuthStatusTests {

    private static func decode(_ json: String) throws -> AlibabaAuthStatus {
        try JSONDecoder().decode(AlibabaAuthStatus.self, from: Data(json.utf8))
    }

    @Test("Authenticated reply parses workspace principal from the base-URL host")
    func authenticatedWorkspace() throws {
        let status = try Self.decode("""
        {
          "authenticated": true,
          "config": "cortex-monitor",
          "config_file": "/Users/example/.bailian/config.json",
          "api_key": {
            "source": "config",
            "masked": "sk-w...QvzE",
            "base_url": "https://ws-hhugyjljove6wldy.ap-southeast-1.maas.aliyuncs.com"
          },
          "console": {
            "source": "config", "masked": "890b...3402",
            "region": "ap-southeast-1", "site": "international"
          }
        }
        """)
        #expect(status.authenticated)
        #expect(status.workspaceId == "ws-hhugyjljove6wldy")
        #expect(status.principal == "ws-hhugyjljove6wldy")
        let identity = status.verifiedIdentity(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(identity?.email == "ws-hhugyjljove6wldy")
        #expect(identity?.orgId == "ws-hhugyjljove6wldy")
        #expect(identity?.orgName == "international")
        #expect(identity?.method == .alibabaConsole)
        #expect(identity?.verifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Not-authenticated reply is valid and yields no identity")
    func notAuthenticated() throws {
        let status = try Self.decode("""
        { "authenticated": false, "config": "cortex-monitor", "message": "Not authenticated." }
        """)
        #expect(status.authenticated == false)
        #expect(status.workspaceId == nil)
        #expect(status.verifiedIdentity() == nil)
    }

    @Test("Non-workspace base URL carries no invented workspace id")
    func nonWorkspaceBaseURL() throws {
        let status = try Self.decode("""
        { "authenticated": true, "api_key": { "base_url": "https://dashscope.aliyuncs.com" } }
        """)
        #expect(status.workspaceId == nil)
        // Falls back to the masked console token, else stays nil — never a guess.
        #expect(status.principal == nil)
    }

    @Test("Authenticated but with no identifiable principal stays unverified")
    func authenticatedNoPrincipal() throws {
        let status = try Self.decode("""
        { "authenticated": true, "api_key": { "base_url": "https://dashscope.aliyuncs.com" } }
        """)
        #expect(status.verifiedIdentity() == nil)
    }

    @Test("Masked console token is the fallback principal when there is no workspace")
    func maskedFallback() throws {
        let status = try Self.decode("""
        {
          "authenticated": true,
          "api_key": { "base_url": "https://dashscope.aliyuncs.com" },
          "console": { "masked": "890b...3402", "site": "international" }
        }
        """)
        #expect(status.principal == "890b...3402")
        #expect(status.verifiedIdentity()?.email == "890b...3402")
    }

    @Test("Unknown fields are ignored (the CLI may add more)")
    func unknownFieldsTolerated() throws {
        let status = try Self.decode("""
        { "authenticated": true, "brand_new": {"x": 1}, "api_key": { "extra": true } }
        """)
        #expect(status.authenticated)
    }
}
