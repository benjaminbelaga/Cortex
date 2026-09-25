import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// Contract B (v7.2) decode: `route_now`, `error_class`, and recorded-cost
/// fields decode additively — a router without them still parses (nil), and the
/// "Priorité" card falls back to "indisponible".
@Suite("LLMRouterSnapshotClient route_now / error_class")
struct LLMRouterRouteNowDecodeTests {

    @Test("route_now decodes all three profiles and the full recommendation")
    func decodesRouteNow() throws {
        let snapshot = try LLMRouterSnapshotClient.parse(Self.payload(includeRouteNow: true))
        let routeNow = try #require(snapshot.routeNow)

        #expect(routeNow.profiles.count == 3)
        let plan = try #require(routeNow.recommendation(for: .plan))
        #expect(plan.provider == "opencode_go")
        #expect(plan.account == "Ben")
        #expect(plan.model == "deepseek-v4.1-flash")
        #expect(plan.score == 88.8)
        #expect(plan.bindingWindow?.kind == "weekly")
        #expect(plan.bindingWindow?.remainingPct == 96)
        #expect(plan.timeMultiplier == 1.0)
        #expect(plan.timeState == "normal")
        #expect(plan.nextBetterSlot != nil)
        #expect(plan.promoExpiry == "2026-09-27")
        #expect(plan.liveSessions == 3)
        #expect(plan.reasons == ["fenêtre hebdo pleine"])
        #expect(plan.excluded.first?.provider == "commandcode")
        #expect(plan.alternatives.count == 2)
        #expect(plan.alternatives.first?.provider == "kimi")
        #expect(plan.alternatives.first?.account == nil)
        // Quota mesuré (0…1) vs inconnu (nil) — l'UI flague ce dernier (R41).
        #expect(plan.alternatives.first?.quotaHeadroomPct == 0.42)
        #expect(plan.alternatives.last?.quotaHeadroomPct == nil)
    }

    @Test("a snapshot without route_now decodes with routeNow == nil (graceful)")
    func decodesWithoutRouteNow() throws {
        let snapshot = try LLMRouterSnapshotClient.parse(Self.payload(includeRouteNow: false))
        #expect(snapshot.routeNow == nil)
        // The rest still decodes.
        #expect(snapshot.providers["minimax_max"] != nil)
    }

    @Test("error_class decodes on both provider and account")
    func decodesErrorClass() throws {
        let snapshot = try LLMRouterSnapshotClient.parse(Self.payload(includeRouteNow: false))
        #expect(snapshot.providers["minimax_max"]?.errorClass == "subscription_inactive")
        #expect(snapshot.providers["minimax_max"]?.accounts.first?.errorClass == "auth_expired")
    }

    @Test("recorded cost fields decode when present, default empty when absent")
    func decodesRecordedCost() throws {
        let withRecorded = try LLMRouterSnapshotClient.parse(Self.payload(includeRouteNow: true))
        #expect(withRecorded.costEstimate?.last24h?.recordedUsd == 4.2)
        #expect(withRecorded.costEstimate?.last24h?.byBackendRecordedUsd["opencode_go"] == 1.5)

        let withoutRecorded = try LLMRouterSnapshotClient.parse(Self.payload(includeRouteNow: false))
        #expect(withoutRecorded.costEstimate?.last24h?.recordedUsd == nil)
        #expect(withoutRecorded.costEstimate?.last24h?.byBackendRecordedUsd.isEmpty == true)
    }

    @Test("v7.4 spend fields decode; estimated_backends flags benchmark figures")
    func decodesBackendSpend() throws {
        let withSpend = try LLMRouterSnapshotClient.parse(Self.payload(includeRouteNow: true))
        #expect(withSpend.costEstimate?.last24h?.spendUsd == 92.2)
        #expect(withSpend.costEstimate?.last24h?.byBackendSpendUsd["claude_natif"] == 88.0)
        #expect(withSpend.costEstimate?.last24h?.estimatedBackends == ["claude_natif"])

        // Absent payload (pre-v7.4 router) decodes with no spend, no crash.
        let withoutSpend = try LLMRouterSnapshotClient.parse(Self.payload(includeRouteNow: false))
        #expect(withoutSpend.costEstimate?.last24h?.spendUsd == nil)
        #expect(withoutSpend.costEstimate?.last24h?.byBackendSpendUsd.isEmpty == true)
        #expect(withoutSpend.costEstimate?.last24h?.estimatedBackends.isEmpty == true)
    }

    private static func payload(includeRouteNow: Bool) -> Data {
        let routeNow = includeRouteNow ? """
          ,"route_now": {
            "generated_at": "2026-09-23T09:11:00Z",
            "profiles": {
              "plan": {
                "decision_id": "d1",
                "provider": "opencode_go",
                "account": "Ben",
                "model": "deepseek-v4.1-flash",
                "score": 88.8,
                "binding_window": {"kind": "weekly", "remaining_pct": 96, "resets_at": "2026-09-28T00:00:00Z"},
                "time_multiplier": 1.0,
                "time_state": "normal",
                "next_better_slot": "2026-09-23T16:00:00Z",
                "promo_expiry": "2026-09-27",
                "live_sessions": 3,
                "reasons": ["fenêtre hebdo pleine"],
                "excluded": [{"provider": "commandcode", "account": "Tech", "reason": "fenêtre hebdo épuisée"}],
                "alternatives": [
                  {"provider": "kimi", "account": null, "model": "k3-256k", "score": 87.0, "quota_headroom_pct": 0.42},
                  {"provider": "claude", "account": "Tech", "model": "claude-sonnet", "score": 83.9, "quota_headroom_pct": null}
                ]
              },
              "execute": {"decision_id": "d2", "provider": "opencode_go", "model": "deepseek-v4.1-flash", "score": 90.0},
              "flexible": {"decision_id": "d3", "provider": "minimax_max", "model": "minimax-m3", "score": 70.0}
            }
          }
        """ : ""

        let recorded = includeRouteNow ? """
          ,"recorded_usd": 4.2,
          "by_backend_recorded": {"opencode_go": 1.5, "kimi": 2.7},
          "by_backend_spend": {"opencode_go": 1.5, "kimi": 2.7, "claude_natif": 88.0},
          "spend_usd": 92.2,
          "estimated_backends": ["claude_natif"]
        """ : ""

        return Data(
            """
            {
              "schema_version": 2,
              "generated_at": "2026-09-23T00:00:00+00:00",
              "providers": {
                "minimax_max": {
                  "provider_id": "minimax_max",
                  "windows": [],
                  "error": "subscription inactive",
                  "error_class": "subscription_inactive",
                  "source": "broker",
                  "grade": "B",
                  "captured_at": 1790000000,
                  "manual": false,
                  "accounts": [{
                    "alias": "MAX",
                    "windows": [],
                    "present": false,
                    "error": "session expired",
                    "error_class": "auth_expired",
                    "source": null,
                    "active": false,
                    "stale": false
                  }],
                  "warnings": [],
                  "effective_headroom": null,
                  "confidence": "unknown",
                  "age_seconds": 2
                }
              },
              "cost_estimate": {
                "verified": true,
                "reporting_currency": "USD",
                "24h": {
                  "by_model_usd": {},
                  "total_usd": 5.0,
                  "usd_per_mtok": null,
                  "usd_per_session": null,
                  "coverage_pct": 100,
                  "unpriced_models": []\(recorded)
                },
                "7d": null
              }\(routeNow)
            }
            """.utf8
        )
    }
}
