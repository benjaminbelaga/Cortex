import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// The two read-only Lot 4 seams: `llm-router attention --json` (the « À
/// traiter » feed) and `llm-router mission inspect <id>` (the mission
/// inspector). Every JSON payload below was captured from this machine,
/// verbatim — including `recommended.reasons` as `null` and the router's
/// `0/1/null` success encoding.
@Suite("LLMRouterAttentionClient / LLMRouterMissionInspector")
struct LLMRouterAttentionClientTests {

    @Test("attention runs exactly `attention --json` and decodes the live feed")
    func attentionBuildsArgumentsAndDecodes() async throws {
        let runner = AttentionStubRunner(payload: Self.attentionPayload)
        let client = LLMRouterAttentionClient(
            runner: runner,
            executableResolver: { "/usr/local/bin/llm-router" }
        )

        let feed = try await client.attention()

        #expect(await runner.lastExecutable == "/usr/local/bin/llm-router")
        #expect(await runner.lastArguments == ["attention", "--json"])
        #expect(await runner.lastTimeout == 15)

        #expect(feed.count == 1)
        let item = try #require(feed.items.first)
        #expect(item.kind == .accountReconnect)
        #expect(item.severity == .high)
        #expect(item.accountId == "default")
        #expect(item.provider == "kimi")
        #expect(item.cortexProviderId == "kimi")
        #expect(item.model == nil)
        #expect(item.missionId == nil)
        #expect(item.detail == "Kimi (expired)")
        #expect(item.requested.isEmpty)
        #expect(item.observed.isEmpty)
        // The router's own count is echoed, and a reconnect needs no decision
        // from Cortex — it is still the most urgent row on screen.
        #expect(feed.isEmpty == false)
        #expect(feed.decisionCount == 0)
        #expect(feed.highestSeverity == .high)
    }

    @Test("parse is pure and decodes the envelope without a runner")
    func parseDecodesFeed() throws {
        let feed = try LLMRouterAttentionClient.parse(Self.attentionPayload)

        #expect(feed.items.count == 1)
        #expect(feed.count == 1)
        #expect(feed.items.first?.id == "account_reconnect:kimi:default")
    }

    @Test("both parsers wrap an undecodable payload in a RouterQuotaIssue")
    func parseRejectsGarbage() {
        #expect(throws: RouterQuotaIssue.self) {
            _ = try LLMRouterAttentionClient.parse(Data("not json".utf8))
        }
        // A JSON array is not the `{count, items}` envelope.
        #expect(throws: RouterQuotaIssue.self) {
            _ = try LLMRouterAttentionClient.parse(Data("[]".utf8))
        }
        #expect(throws: RouterQuotaIssue.self) {
            _ = try LLMRouterMissionInspector.parse(Data("not json".utf8))
        }
    }

    @Test("inspect runs exactly `mission inspect <id>` and decodes the chain")
    func inspectBuildsArgumentsAndDecodes() async throws {
        let runner = AttentionStubRunner(payload: Self.missionWithReasonsAndAccount)
        let inspector = LLMRouterMissionInspector(
            runner: runner,
            executableResolver: { "/usr/local/bin/llm-router" }
        )

        let inspection = try await inspector.inspect(missionId: "m-20261003-185206-e0aa27")

        #expect(await runner.lastArguments == ["mission", "inspect", "m-20261003-185206-e0aa27"])
        #expect(await runner.lastTimeout == 15)
        #expect(inspection.missionId == "m-20261003-185206-e0aa27")
        #expect(inspection.hasRecommendation)
        #expect(inspection.cortexProviderId == "claude")

        // A padded id is trimmed, so no leading/trailing space reaches argv.
        _ = try await inspector.inspect(missionId: " m-20261003-185206-e0aa27 ")
        #expect(await runner.lastArguments == ["mission", "inspect", "m-20261003-185206-e0aa27"])
    }

    @Test("parse decodes a mission with no recommendation, `reasons: null` included")
    func parsesMissionWithoutRecommendation() throws {
        let inspection = try LLMRouterMissionInspector.parse(Self.missionWithoutRecommendation)

        #expect(inspection.missionId == "wp-b-wp-20260823-072840-57428")
        // `null` reasons is an empty list, never an invented reason.
        #expect(inspection.recommended.provider == nil)
        #expect(inspection.recommended.model == nil)
        #expect(inspection.recommended.score == nil)
        #expect(inspection.recommended.account == nil)
        #expect(inspection.recommended.reasons.isEmpty)
        #expect(inspection.hasRecommendation == false)

        #expect(inspection.requested.isEmpty)
        #expect(inspection.observed.isEmpty)
        #expect(inspection.receiptState == .unknown)
        #expect(inspection.isExecutionConfirmed == false)
        #expect(inspection.divergence == nil)

        // `success: 1` is the router's int encoding, and it decodes.
        #expect(inspection.result.resultState == "unknown")
        #expect(inspection.result.success == true)
        #expect(inspection.result.closed == true)
        #expect(inspection.result.processNotes == "work-package run, http=200")
        #expect(inspection.result.isVerified)
        #expect(inspection.result.isUnverifiedClose == false)

        #expect(inspection.metrics.durationSeconds == 2.0)
        #expect(inspection.metrics.inputTokens == 3255)
        #expect(inspection.metrics.outputTokens == 108)
        #expect(inspection.metrics.testsPassed == nil)
        #expect(inspection.metrics.estimatedCost == nil)
        #expect(inspection.metrics.isEmpty == false)
    }

    @Test("parse decodes a mission with a recommendation, account and reasons")
    func parsesMissionWithReasonsAndAccount() throws {
        let inspection = try LLMRouterMissionInspector.parse(Self.missionWithReasonsAndAccount)

        #expect(inspection.missionId == "m-20261003-185206-e0aa27")
        #expect(inspection.recommended.provider == "claude")
        #expect(inspection.recommended.model == "claude-sonnet")
        #expect(inspection.recommended.score == 88.1)
        let account = try #require(inspection.recommended.account)
        #expect(account["alias"]?.displayText == "WEBMASTER")
        #expect(account["identity"]?.displayText == "tech@yoyaku.fr")
        #expect(account["id"]?.displayText == "acct_ae31b0d5e1854ed19b6624b94cf9a63a")
        #expect(inspection.recommended.reasons == [
            "quota effectif 99% (réserve 35%)",
            "Ben absent → priorité coût",
        ])
        #expect(inspection.hasRecommendation)

        // `success: null` is "never evaluated"; a closed flag would have been
        // the tempting lie (see `isUnverifiedClose`).
        #expect(inspection.result.success == nil)
        #expect(inspection.result.closed == false)
        #expect(inspection.result.isVerified == false)
        #expect(inspection.result.isUnverifiedClose == false)
        #expect(inspection.result.processNotes == nil)
        #expect(inspection.metrics.isEmpty)
        #expect(inspection.cortexProviderId == "claude")
    }

    @Test("a non-zero router exit rejects the read — never an empty inspection")
    func nonZeroExitRejectsTheRead() async {
        // `/usr/bin/false` stands in for the binary: exit 1 with no stdout, the
        // router's own answer for an unknown mission. The exit-status contract
        // lives in the runner; the client must never turn it into a blank item.
        let inspector = LLMRouterMissionInspector(
            runner: LLMRouterProcessRunner(),
            executableResolver: { "/usr/bin/false" }
        )

        await #expect(throws: RouterQuotaIssue.self) {
            _ = try await inspector.inspect(missionId: "m-unknown")
        }
    }

    @Test("an issue raised by the runner propagates unchanged")
    func runnerIssuePropagates() async {
        let runner = AttentionStubRunner(
            failure: RouterQuotaIssue("llm-router attention exited 2: boom")
        )
        let client = LLMRouterAttentionClient(
            runner: runner,
            executableResolver: { "/usr/local/bin/llm-router" }
        )

        do {
            _ = try await client.attention()
            Issue.record("expected the runner's issue to propagate")
        } catch let issue as RouterQuotaIssue {
            #expect(issue.message.contains("exited 2"))
        } catch {
            Issue.record("expected RouterQuotaIssue, got \(error)")
        }
        #expect(await runner.callCount == 1)
    }

    @Test("a blank stdout is rejected instead of decoded as an empty feed")
    func blankStdoutIsRejected() async {
        let client = LLMRouterAttentionClient(
            runner: AttentionStubRunner(payload: Data(" \n\t\n".utf8)),
            executableResolver: { "/usr/local/bin/llm-router" }
        )
        await #expect(throws: RouterQuotaIssue.self) {
            _ = try await client.attention()
        }

        // Same through the real runner: exit 0 with nothing on stdout.
        let silent = LLMRouterMissionInspector(
            runner: LLMRouterProcessRunner(),
            executableResolver: { "/usr/bin/true" }
        )
        await #expect(throws: RouterQuotaIssue.self) {
            _ = try await silent.inspect(missionId: "m-20261003-185206-e0aa27")
        }
    }

    @Test("a timed-out runner surfaces as the explicit timeout issue")
    func timeoutMapsToIssue() async {
        let runner = AttentionStubRunner(
            failure: ProcessRunError.timedOut(after: 15, stderrTail: "router busy")
        )
        let client = LLMRouterAttentionClient(
            runner: runner,
            executableResolver: { "/usr/local/bin/llm-router" }
        )

        do {
            _ = try await client.attention()
            Issue.record("expected a timeout issue")
        } catch let issue as RouterQuotaIssue {
            #expect(issue.message.contains("timed out"))
            #expect(issue.message.contains("router busy"))
            // The raw-ProcessRunError path must name the subcommand this client ran,
            // not a hardcoded / mismatched one.
            #expect(issue.message.contains("attention"))
        } catch {
            Issue.record("expected RouterQuotaIssue, got \(error)")
        }
    }

    @Test("a launch failure surfaces as the explicit launch issue")
    func launchFailureMapsToIssue() async {
        let runner = AttentionStubRunner(
            failure: ProcessRunError.launchFailed("permission denied")
        )
        let inspector = LLMRouterMissionInspector(
            runner: runner,
            executableResolver: { "/usr/local/bin/llm-router" }
        )

        do {
            _ = try await inspector.inspect(missionId: "m-20261003-185206-e0aa27")
            Issue.record("expected a launch issue")
        } catch let issue as RouterQuotaIssue {
            #expect(issue.message.contains("could not launch"))
            #expect(issue.message.contains("permission denied"))
            // `mission inspect`, never the hardcoded "status".
            #expect(issue.message.contains("mission inspect"))
            #expect(issue.message.contains("status") == false)
        } catch {
            Issue.record("expected RouterQuotaIssue, got \(error)")
        }
    }

    @Test("a cancellation stays a CancellationError")
    func cancellationStaysCancellable() async {
        let viaProcessError = AttentionStubRunner(
            failure: ProcessRunError.cancelled(stderrTail: "")
        )
        let client = LLMRouterAttentionClient(
            runner: viaProcessError,
            executableResolver: { "/usr/local/bin/llm-router" }
        )
        await #expect(throws: CancellationError.self) {
            _ = try await client.attention()
        }

        let viaCancellation = AttentionStubRunner(failure: CancellationError())
        let inspector = LLMRouterMissionInspector(
            runner: viaCancellation,
            executableResolver: { "/usr/local/bin/llm-router" }
        )
        await #expect(throws: CancellationError.self) {
            _ = try await inspector.inspect(missionId: "m-20261003-185206-e0aa27")
        }
    }

    @Test("no llm-router binary fails loudly on both clients, running nothing")
    func missingExecutableThrows() async {
        let attentionRunner = AttentionStubRunner(payload: Self.attentionPayload)
        let client = LLMRouterAttentionClient(runner: attentionRunner, executableResolver: { nil })
        await #expect(throws: RouterQuotaIssue.self) {
            _ = try await client.attention()
        }
        #expect(await attentionRunner.callCount == 0)

        let inspectRunner = AttentionStubRunner(payload: Self.missionWithReasonsAndAccount)
        let inspector = LLMRouterMissionInspector(runner: inspectRunner, executableResolver: { nil })
        await #expect(throws: RouterQuotaIssue.self) {
            _ = try await inspector.inspect(missionId: "m-20261003-185206-e0aa27")
        }
        #expect(await inspectRunner.callCount == 0)
    }

    @Test("an empty mission id never reaches the router")
    func emptyMissionIdIsRejected() async {
        let runner = AttentionStubRunner(payload: Self.missionWithReasonsAndAccount)
        let inspector = LLMRouterMissionInspector(
            runner: runner,
            executableResolver: { "/usr/local/bin/llm-router" }
        )

        await #expect(throws: RouterQuotaIssue.self) {
            _ = try await inspector.inspect(missionId: "   ")
        }
        #expect(await runner.callCount == 0)
    }

    // MARK: - Fixtures (captured verbatim from this machine)

    /// `llm-router attention --json`.
    private static let attentionPayload = Data(
        """
        {"count":1,"items":[{"kind":"account_reconnect","severity":"high","account_id":"default","provider":"kimi","detail":"Kimi (expired)"}]}
        """.utf8
    )

    /// `llm-router mission inspect wp-b-wp-20260823-072840-57428` — no
    /// recommendation at all, `reasons` explicitly `null`.
    private static let missionWithoutRecommendation = Data(
        """
        {"mission_id":"wp-b-wp-20260823-072840-57428","recommended":{"provider":null,"model":null,"score":null,"account":null,"reasons":null},"requested":{},"observed":{},"receipt_state":"unknown","divergence":null,"result":{"result_state":"unknown","success":1,"closed":true,"process_notes":"work-package run, http=200"},"metrics":{"duration_s":2.0,"input_tokens":3255,"output_tokens":108,"tests_passed":null,"estimated_cost":null}}
        """.utf8
    )

    /// `llm-router mission inspect m-20261003-185206-e0aa27` — a recommendation
    /// with its account and reasons, and a mission never evaluated.
    private static let missionWithReasonsAndAccount = Data(
        """
        {"mission_id":"m-20261003-185206-e0aa27","recommended":{"provider":"claude","model":"claude-sonnet","score":88.1,"account":{"id":"acct_ae31b0d5e1854ed19b6624b94cf9a63a","alias":"WEBMASTER","identity":"tech@yoyaku.fr"},"reasons":["quota effectif 99% (réserve 35%)","Ben absent → priorité coût"]},"requested":{},"observed":{},"receipt_state":"unknown","divergence":null,"result":{"result_state":"unknown","success":null,"closed":false,"process_notes":null},"metrics":{"duration_s":null,"input_tokens":null,"output_tokens":null,"tests_passed":null,"estimated_cost":null}}
        """.utf8
    )
}

/// Records the exact invocation and hands back a payload (or a failure) in its
/// place, so the argv contract is asserted without a subprocess.
private actor AttentionStubRunner: LLMRouterCommandRunning {
    private let outcome: Result<Data, Error>
    private(set) var callCount = 0
    private(set) var lastExecutable: String?
    private(set) var lastArguments: [String] = []
    private(set) var lastTimeout: TimeInterval?

    init(payload: Data) {
        outcome = .success(payload)
    }

    init(failure: Error) {
        outcome = .failure(failure)
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        callCount += 1
        lastExecutable = executable
        lastArguments = arguments
        lastTimeout = timeout
        return try outcome.get()
    }
}
