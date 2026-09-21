import Testing
import Foundation
import Domain
@testable import Infrastructure

/// C4-5 tests: the `account/read` reply parser and request shape. The parser
/// is the part whose input we do not control (Codex's schema lives outside
/// Cortex), so it is tested against every shape variant we know of — camelCase,
/// snake_case, nested `account` wrapper, error envelope, empty result — and
/// every failure must yield "not authed" (nil), never a fabricated identity.
@Suite("CodexAuthStatusRPCProbe")
struct CodexAuthStatusRPCProbeTests {

    // MARK: - Request shape

    @Test("request() is newline-free JSON-RPC 2.0 calling account/read")
    func requestShape() throws {
        let data = CodexAuthStatusRPCProbe.request(id: 7)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(obj["jsonrpc"] as? String == "2.0")
        #expect(obj["id"] as? Int == 7)
        #expect(obj["method"] as? String == "account/read")
        #expect(obj["params"] is [String: Any])
    }

    @Test("app-server arguments keep the read-only sandbox + never-approval combo (#259)")
    func argumentsSafe() {
        #expect(CodexAuthStatusRPCProbe.arguments.contains("read-only"))
        #expect(CodexAuthStatusRPCProbe.arguments.contains("never"))
        #expect(CodexAuthStatusRPCProbe.arguments.contains("app-server"))
    }

    // MARK: - Reply parsing — happy paths

    @Test("Flat camelCase account with email + plan")
    func parseFlatCamelCase() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"email":"p@y.fr","planType":"plus","accountId":"acct_1"}}"#
        let status = try #require(CodexAuthStatusRPCProbe.parse(Data(json.utf8)))
        #expect(status.loggedIn)
        #expect(status.email == "p@y.fr")
        #expect(status.planType == "plus")
        #expect(status.accountId == "acct_1")
    }

    @Test("snake_case plan_type + account_id spellings accepted")
    func parseSnakeCase() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"email":"p@y.fr","plan_type":"metered_api","account_id":"a2"}}"#
        let status = try #require(CodexAuthStatusRPCProbe.parse(Data(json.utf8)))
        #expect(status.loggedIn)
        #expect(status.planType == "metered_api")
        #expect(status.accountId == "a2")
    }

    @Test("Nested {\"account\": {...}} wrapper accepted")
    func parseNestedWrapper() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"account":{"email":"n@y.fr","plan":"pro"}}}"#
        let status = try #require(CodexAuthStatusRPCProbe.parse(Data(json.utf8)))
        #expect(status.loggedIn)
        #expect(status.email == "n@y.fr")
        #expect(status.planType == "pro")
    }

    @Test("Account present without email but with plan → loggedIn, nil email (never fabricated)")
    func parseNoEmailStillLoggedIn() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"plan":"team"}}"#
        let status = try #require(CodexAuthStatusRPCProbe.parse(Data(json.utf8)))
        #expect(status.loggedIn)
        #expect(status.email == nil)
    }

    // MARK: - Reply parsing — every failure means "not authed"

    @Test("JSON-RPC error envelope → nil")
    func parseErrorEnvelopeNil() {
        let json = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}"#
        #expect(CodexAuthStatusRPCProbe.parse(Data(json.utf8)) == nil)
    }

    @Test("Empty result object → nil")
    func parseEmptyResultNil() {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        #expect(CodexAuthStatusRPCProbe.parse(Data(json.utf8)) == nil)
    }

    @Test("Malformed JSON → nil, never a crash")
    func parseGarbageNil() {
        #expect(CodexAuthStatusRPCProbe.parse(Data("not json".utf8)) == nil)
        #expect(CodexAuthStatusRPCProbe.parse(Data("{}".utf8)) == nil)
    }

    @Test("Reply without a result key → nil")
    func parseNoResultNil() {
        let json = #"{"jsonrpc":"2.0","id":1}"#
        #expect(CodexAuthStatusRPCProbe.parse(Data(json.utf8)) == nil)
    }
}
