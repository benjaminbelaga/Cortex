import Foundation
import Testing
@testable import Domain

@Suite("RouterRegistrationRequest")
struct RouterRegistrationRequestTests {

    private static let identity = VerifiedIdentity(
        email: "personal@example.com",
        orgId: nil, orgName: nil,
        verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        method: .claudeAuthStatus
    )

    @Test("Claude target builds expected argv")
    func claudeArguments() {
        let req = RouterRegistrationRequest(
            target: .claude, alias: "WORK",
            authHome: "/home/u/.claude-work",
            verifiedIdentity: Self.identity
        )
        #expect(req.arguments() == [
            "account", "add", "claude",
            "--alias", "WORK",
            "--auth-home", "/home/u/.claude-work",
            "--verified-identity", "personal@example.com",
            "--auth-state", "connected",
        ])
    }

    @Test("Codex target uses --codex-home instead of --auth-home")
    func codexArguments() {
        let req = RouterRegistrationRequest(
            target: .codex, alias: "PERSONAL",
            authHome: "/home/u/.codex-personal",
            verifiedIdentity: Self.identity
        )
        #expect(req.arguments() == [
            "account", "add", "codex",
            "--alias", "PERSONAL",
            "--codex-home", "/home/u/.codex-personal",
            "--verified-identity", "personal@example.com",
            "--auth-state", "connected",
        ])
    }

    @Test("Request carries alias + email + auth-home verbatim, no trimming")
    func noTrimming() {
        let req = RouterRegistrationRequest(
            target: .claude, alias: "WEB-MASTER",
            authHome: "/path/with spaces/.claude-x",
            verifiedIdentity: VerifiedIdentity(
                email: "personal@example.com",
                orgId: nil, orgName: nil,
                verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                method: .claudeAuthStatus
            )
        )
        let args = req.arguments()
        #expect(args.contains("WEB-MASTER"))
        #expect(args.contains("/path/with spaces/.claude-x"))
        #expect(args.contains("personal@example.com"))  // case NOT lowered — the router owns the email normalization
    }

    @Test("--auth-state is always 'connected' (the contract — never 'revoked' on first registration)")
    func authStateContract() {
        let claudeReq = RouterRegistrationRequest(
            target: .claude, alias: "A", authHome: "/p", verifiedIdentity: Self.identity
        )
        let codexReq = RouterRegistrationRequest(
            target: .codex, alias: "A", authHome: "/p", verifiedIdentity: Self.identity
        )
        #expect(claudeReq.arguments().contains("--auth-state"))
        let sIdx = claudeReq.arguments().firstIndex(of: "--auth-state")!
        #expect(claudeReq.arguments()[sIdx + 1] == "connected")
        let csIdx = codexReq.arguments().firstIndex(of: "--auth-state")!
        #expect(codexReq.arguments()[csIdx + 1] == "connected")
    }
}
