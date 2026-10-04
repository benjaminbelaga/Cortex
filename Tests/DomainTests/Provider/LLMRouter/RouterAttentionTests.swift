import Foundation
import Testing
@testable import Domain

/// The `llm-router attention` feed and `mission inspect` chain.
///
/// The regression class these tests pin: a router that grows a new attention
/// kind, or drops a field Cortex reads, must not have its items silently
/// disappear — and a mission that closed without an explicit evaluation must
/// never read as verified.
@Suite("RouterAttention")
struct RouterAttentionTests {

    // MARK: - Fixtures

    /// A full feed: one of each known kind plus an unknown one a newer router
    /// might add. Deliberately unordered so the sort is exercised.
    static func payload() -> Data {
        Data("""
        {
          "count": 5,
          "items": [
            {
              "kind": "account_reconnect",
              "severity": "medium",
              "account_id": "WORK",
              "provider": "claude",
              "detail": "refresh token expired",
              "requested": {},
              "observed": {}
            },
            {
              "kind": "receipt_awaited",
              "severity": "low",
              "mission_id": "m-003",
              "provider": "claude",
              "detail": "awaiting ACCOUNT_SELECTED"
            },
            {
              "kind": "launch_divergence",
              "severity": "high",
              "mission_id": "m-001",
              "provider": "glm_pro",
              "model": "glm-4.6",
              "detail": "ran on claude instead of glm",
              "requested": { "provider": "glm_pro", "model": "glm-4.6" },
              "observed": { "provider": "claude", "model": "claude-opus-4" }
            },
            {
              "kind": "totally_new",
              "severity": "medium",
              "provider": "brand_new_cloud",
              "detail": "kind from a newer router"
            },
            {
              "kind": "result_to_validate",
              "severity": "high",
              "mission_id": "m-002",
              "provider": "codex",
              "detail": "rc=0 does not validate"
            }
          ]
        }
        """.utf8)
    }

    /// A `mission inspect` payload. `success` is a raw token (`0`/`1`/`null`)
    /// because the router emits it as an int-or-null, never a bool.
    static func missionPayload(
        success: String = "1",
        closed: Bool = true,
        receiptState: String = "confirmed",
        divergence: String? = nil
    ) -> Data {
        let divergenceLine = divergence.map { ",\n          \"divergence\": \"\($0)\"" } ?? ""
        return Data("""
        {
          "mission_id": "m-042",
          "recommended": {
            "provider": "glm_pro",
            "model": "glm-4.6",
            "score": 0.81,
            "account": { "native_slot": "primary", "alias": "GLM" },
            "reasons": ["cheapest", "quota ok"]
          },
          "requested": { "provider": "glm_pro", "model": "glm-4.6" },
          "observed": { "provider": "claude", "model": "claude-opus-4" },
          "receipt_state": "\(receiptState)",
          "result": {
            "result_state": "closed",
            "success": \(success),
            "closed": \(closed),
            "process_notes": "exit code 0"
          },
          "metrics": {
            "duration_s": 12.5,
            "input_tokens": 1200,
            "output_tokens": 340,
            "tests_passed": 42,
            "estimated_cost": 0.07
          }\(divergenceLine)
        }
        """.utf8)
    }

    // MARK: - Feed decoding

    @Test("a full feed decodes every kind, sorts high→low, and reports decision/severity counts")
    func fullFeed() throws {
        let feed = try RouterAttentionFeed.parse(Self.payload())

        #expect(feed.count == 5)
        #expect(feed.isEmpty == false)
        #expect(feed.items.count == 5)

        let ordered = RouterAttentionFeed.sorted(feed.items).map(\.id)
        #expect(ordered == [
            "launch_divergence:m-001",
            "result_to_validate:m-002",
            "account_reconnect:claude:WORK",
            "totally_new:kind from a newer router",
            "receipt_awaited:m-003",
        ], "high → medium → low, ties broken by stable id")

        #expect(feed.decisionCount == 2, "launch divergence + result to validate need a human")
        #expect(feed.highestSeverity == .high)
    }

    @Test("severity ranks and French labels are the documented order")
    func severity() {
        #expect(RouterAttentionSeverity.high.rank == 0)
        #expect(RouterAttentionSeverity.medium.rank == 1)
        #expect(RouterAttentionSeverity.low.rank == 2)
        #expect(RouterAttentionSeverity.high.label == "haute")
        #expect(RouterAttentionSeverity.medium.label == "moyenne")
        #expect(RouterAttentionSeverity.low.label == "basse")
    }

    @Test("an unknown kind is kept, never dropped, and keeps its raw value")
    func unknownKindKept() throws {
        let feed = try RouterAttentionFeed.parse(Self.payload())

        #expect(feed.items.count == 5, "the newer router's item must not vanish")
        let item = try #require(feed.items.first { $0.kind == .unknown("totally_new") })
        #expect(item.kind.rawValue == "totally_new")
        #expect(item.kind.label == "totally_new")
        #expect(item.kind.isDecision == false)
    }

    @Test("account_reconnect has no mission: target falls back to the account id and the id is stable")
    func accountFallback() throws {
        let feed = try RouterAttentionFeed.parse(Self.payload())
        let item = try #require(feed.items.first { $0.kind == .accountReconnect })

        #expect(item.missionId == nil)
        #expect(item.accountId == "WORK")
        #expect(item.target == "WORK", "no mission id → the account is the target")
        #expect(item.id == "account_reconnect:claude:WORK",
                "the reconnect id carries the provider so the same account on another provider stays distinct")

        let missionItem = try #require(feed.items.first { $0.kind == .resultToValidate })
        #expect(missionItem.target == "m-002", "a mission-backed item targets its mission")
        #expect(missionItem.id == "result_to_validate:m-002",
                "the mission-backed id carries the kind so several kinds on one mission never collide")
    }

    @Test("one mission with several kinds yields distinct ids, stable across decodes")
    func idsAreUniquePerRowAndStable() throws {
        // The collision the old `missionId ?? accountId ?? kind:detail` id hid: three
        // rows on the SAME mission_id.
        let shared = Data(#"""
        { "count": 3, "items": [
          { "kind": "launch_divergence", "severity": "high", "mission_id": "m-shared", "detail": "a" },
          { "kind": "result_to_validate", "severity": "high", "mission_id": "m-shared", "detail": "b" },
          { "kind": "receipt_awaited", "severity": "low", "mission_id": "m-shared", "detail": "c" }
        ] }
        """#.utf8)
        let feed = try RouterAttentionFeed.parse(shared)
        let ids = feed.items.map(\.id)
        #expect(Set(ids).count == ids.count, "one mission with three kinds must yield three distinct ids")
        #expect(ids == ["launch_divergence:m-shared", "result_to_validate:m-shared", "receipt_awaited:m-shared"])

        // Two reconnects for the same account on different providers must not collide.
        let reconnects = Data(#"""
        { "count": 2, "items": [
          { "kind": "account_reconnect", "severity": "medium", "account_id": "WORK", "provider": "claude", "detail": "x" },
          { "kind": "account_reconnect", "severity": "medium", "account_id": "WORK", "provider": "codex", "detail": "y" }
        ] }
        """#.utf8)
        let reconnectFeed = try RouterAttentionFeed.parse(reconnects)
        #expect(Set(reconnectFeed.items.map(\.id)).count == 2)

        // No index / UUID: decoding the same payload twice yields identical ids.
        let again = try RouterAttentionFeed.parse(shared)
        #expect(feed.items.map(\.id) == again.items.map(\.id), "ids are stable across two decodes of the same payload")
    }

    @Test("cortexProviderId maps through RouterProviderIdMap and is nil for an unmapped id")
    func providerMapping() throws {
        let feed = try RouterAttentionFeed.parse(Self.payload())

        let claude = try #require(feed.items.first { $0.accountId == "WORK" })
        #expect(claude.provider == "claude")
        #expect(claude.cortexProviderId == "claude")

        let glm = try #require(feed.items.first { $0.kind == .launchDivergence })
        #expect(glm.provider == "glm_pro")
        #expect(glm.cortexProviderId == "glm", "router glm_pro maps to Cortex glm")

        let unmapped = try #require(feed.items.first { $0.kind == .unknown("totally_new") })
        #expect(unmapped.provider == "brand_new_cloud")
        #expect(unmapped.cortexProviderId == nil, "an id absent from the table is never guessed")
    }

    @Test("requested vs observed are both kept so a divergence stays visible")
    func requestedObserved() throws {
        let feed = try RouterAttentionFeed.parse(Self.payload())
        let item = try #require(feed.items.first { $0.kind == .launchDivergence })

        #expect(item.requested["provider"] == .string("glm_pro"))
        #expect(item.requested["model"] == .string("glm-4.6"))
        #expect(item.observed["provider"] == .string("claude"))
        #expect(item.observed["model"] == .string("claude-opus-4"))
    }

    @Test("an envelope with no items parses to an empty feed with count 0")
    func emptyFeed() throws {
        let feed = try RouterAttentionFeed.parse(Data(#"{ "count": 0, "items": [] }"#.utf8))

        #expect(feed.isEmpty)
        #expect(feed.count == 0)
        #expect(feed.declaredCount == 0)
        #expect(feed.droppedCount == 0)
        #expect(feed.decisionCount == 0)
        #expect(feed.highestSeverity == nil)
    }

    @Test("a drift that announces items but decodes none keeps the router's count")
    func allItemsDroppedKeepsDeclaredCount() throws {
        // None of the three carries the `kind` that identifies it, so lenient
        // decoding drops all three while the router still declares `count: 3`.
        let json = Data(#"""
        { "count": 3, "items": [ { "severity": "high" }, { "severity": "low" }, 42 ] }
        """#.utf8)
        let feed = try RouterAttentionFeed.parse(json)

        #expect(feed.items.isEmpty)
        #expect(feed.isEmpty)
        #expect(feed.declaredCount == 3, "the router's own count must survive a total decode loss")
        #expect(feed.count == 3, "count is NOT zeroed when every item failed to decode")
        #expect(feed.rawItemCount == 3)
        #expect(feed.droppedCount == 3)
    }

    @Test("a partial decode reports the dropped items and keeps the readable ones")
    func partialDropIsReported() throws {
        let json = Data(#"""
        { "count": 2, "items": [
          { "kind": "receipt_awaited", "severity": "low", "mission_id": "m-1" },
          { "severity": "high" }
        ] }
        """#.utf8)
        let feed = try RouterAttentionFeed.parse(json)

        #expect(feed.items.count == 1)
        #expect(feed.rawItemCount == 2)
        #expect(feed.count == 2)
        #expect(feed.droppedCount == 1)
        #expect(feed.isEmpty == false)
    }

    @Test("a genuine empty and an absent count are not mistaken for drift")
    func cleanEmptyIsNotDrift() throws {
        let empty = try RouterAttentionFeed.parse(Data(#"{ "count": 0, "items": [] }"#.utf8))
        #expect(empty.droppedCount == 0)
        #expect(empty.count == 0)

        // No `count` at all: the fallback is the decoded count, still no drop.
        let noCount = try RouterAttentionFeed.parse(Data(#"{ "items": [] }"#.utf8))
        #expect(noCount.declaredCount == nil)
        #expect(noCount.count == 0)
        #expect(noCount.droppedCount == 0)

        // No `count`, but a readable item: count falls back to items.count.
        let noCountWithItem = try RouterAttentionFeed.parse(Data(#"""
        { "items": [ { "kind": "receipt_awaited", "severity": "low", "mission_id": "m-1" } ] }
        """#.utf8))
        #expect(noCountWithItem.declaredCount == nil)
        #expect(noCountWithItem.count == 1)
        #expect(noCountWithItem.droppedCount == 0)
    }

    @Test("a malformed declared count is treated as absent, never trapped on")
    func malformedDeclaredCountIsAbsent() throws {
        // `1e30` is finite but far outside `Int`'s range; a naive `Int(value)`
        // would trap. It must be treated as "no declared count".
        let weird = try RouterAttentionFeed.parse(Data(#"{ "count": 1e30, "items": [] }"#.utf8))
        #expect(weird.declaredCount == nil)
        #expect(weird.count == 0)
        #expect(weird.droppedCount == 0)

        // A numeric string is accepted, and it announces more than was read.
        let stringy = try RouterAttentionFeed.parse(Data(#"{ "count": "2", "items": [] }"#.utf8))
        #expect(stringy.declaredCount == 2)
        #expect(stringy.count == 2)
        #expect(stringy.droppedCount == 2)
    }

    @Test("an item missing a required field is salvaged when its kind is present")
    func salvagedItem() throws {
        let json = Data(#"""
        { "count": 1, "items": [ { "kind": "receipt_awaited", "severity": "low" } ] }
        """#.utf8)
        let feed = try RouterAttentionFeed.parse(json)

        #expect(feed.items.count == 1, "a malformed field must not drop the item")
        let item = try #require(feed.items.first)
        #expect(item.kind == .receiptAwaited)
        #expect(item.detail == "")
        #expect(item.severity == .low)
    }

    // MARK: - Mission inspection

    @Test("success 0 / 1 / null map to failed / verified / unverified close")
    func successMapping() throws {
        let failed = try MissionInspection.parse(Self.missionPayload(success: "0", closed: true))
        #expect(failed.result.success == false)
        #expect(failed.result.isFailed)
        #expect(failed.result.isVerified == false)
        #expect(failed.result.isUnverifiedClose == false)
        #expect(failed.isVerified == false)

        let verified = try MissionInspection.parse(Self.missionPayload(success: "1", closed: true))
        #expect(verified.result.success == true)
        #expect(verified.result.isVerified)
        #expect(verified.result.isFailed == false)
        #expect(verified.result.isUnverifiedClose == false)
        #expect(verified.isVerified)

        let gap = try MissionInspection.parse(Self.missionPayload(success: "null", closed: true))
        #expect(gap.result.success == nil, "never evaluated is not a failure and not a success")
        #expect(gap.result.isVerified == false)
        #expect(gap.result.isFailed == false)
        #expect(gap.result.isUnverifiedClose, "closed with no evaluation is the honest gap")

        let open = try MissionInspection.parse(Self.missionPayload(success: "null", closed: false))
        #expect(open.result.isUnverifiedClose == false, "still open, not yet a close")
    }

    @Test("receipt_state divergent carries its divergence; an unknown state is unknown")
    func receiptState() throws {
        let divergent = try MissionInspection.parse(
            Self.missionPayload(success: "1", receiptState: "divergent", divergence: "binding diverged")
        )
        #expect(divergent.receiptState == .divergent)
        #expect(divergent.divergence == "binding diverged")
        #expect(divergent.isExecutionConfirmed == false, "divergent is not confirmed execution")

        let unrecognized = try MissionInspection.parse(Self.missionPayload(receiptState: "something_new"))
        #expect(unrecognized.receiptState == .unknown)
        #expect(unrecognized.divergence == nil)
    }

    @Test("the three honesty booleans and the recommended provider id are exposed")
    func honestyBooleans() throws {
        let mission = try MissionInspection.parse(Self.missionPayload())

        #expect(mission.missionId == "m-042")
        #expect(mission.recommended.provider == "glm_pro")
        #expect(mission.recommended.model == "glm-4.6")
        #expect(mission.recommended.score == 0.81)
        #expect(mission.recommended.reasons == ["cheapest", "quota ok"])
        #expect(mission.recommended.account?["native_slot"] == .string("primary"))

        #expect(mission.hasRecommendation)
        #expect(mission.isExecutionConfirmed, "receipt_state confirmed")
        #expect(mission.isVerified)

        #expect(mission.cortexProviderId == "glm")
        #expect(mission.metrics.isEmpty == false)
        #expect(mission.metrics.durationSeconds == 12.5)
        #expect(mission.metrics.estimatedCost == 0.07)
    }

    @Test("a mission_view with no recommendation and no result is an honest empty, not a failure")
    func sparseMission() throws {
        let mission = try MissionInspection.parse(Data(#"{ "mission_id": "m-9" }"#.utf8))

        #expect(mission.missionId == "m-9")
        #expect(mission.hasRecommendation == false)
        #expect(mission.isExecutionConfirmed == false)
        #expect(mission.isVerified == false)
        #expect(mission.receiptState == .unknown)
        #expect(mission.metrics.isEmpty)
        #expect(mission.result.isUnverifiedClose == false)
    }

    // MARK: - JSON value rendering

    @Test("displayText renders each JSON case in one line")
    func displayText() {
        #expect(RouterJSONValue.string("hello").displayText == "hello")
        #expect(RouterJSONValue.number(42.0).displayText == "42", "trailing .0 is trimmed")
        #expect(RouterJSONValue.number(1.5).displayText == "1.5")
        #expect(RouterJSONValue.bool(true).displayText == "true")
        #expect(RouterJSONValue.bool(false).displayText == "false")
        #expect(RouterJSONValue.null.displayText == "")
        #expect(RouterJSONValue.array([.number(1), .number(2), .number(3)]).displayText == "[3]")
        #expect(RouterJSONValue.object(["b": .number(2), "a": .string("x")]).displayText == "a=x, b=2",
                "object pairs are sorted by key")
    }
}
