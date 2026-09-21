import Testing
import Foundation
@testable import Domain

/// Pins the **email-only** reconciler (decision 2026-09-14): an authorised
/// verified email links the native profile to the matching router account;
/// two router accounts or two native profiles sharing the same email raise
/// `conflict` (never silently merged); no email ⇒ standalone.
@Suite("AccountReconciler")
struct AccountReconcilerTests {

    private func router(_ id: String, _ alias: String, _ email: String?) -> RouterAccountSummary {
        RouterAccountSummary(accountId: id, alias: alias, verifiedEmail: email)
    }

    private func native(_ path: String, _ email: String?) -> NativeProfileCandidate {
        NativeProfileCandidate(canonicalPath: path, verifiedEmail: email)
    }

    @Test("Verified email match → `linkAlias`")
    func verifiedEmailLinks() {
        let r = AccountReconciler()
        let decision = r.decide(
            candidate: native("~/.claude-accounts/studio", "personal@example.com"),
            routerAccounts: [
                router("router-1", "PERSONAL", "personal@example.com"),
                router("router-2", "WORK", "work@example.com")
            ]
        )
        if case let .linkAlias(summary) = decision {
            #expect(summary.accountId == "router-1")
            #expect(summary.alias == "PERSONAL")
        } else {
            Issue.record("expected .linkAlias, got \(decision)")
        }
    }

    @Test("Email matching is case-insensitive (case folded)")
    func caseInsensitiveMatch() {
        let r = AccountReconciler()
        let decision = r.decide(
            candidate: native("~/.claude-accounts/studio", "Personal@example.com"),
            routerAccounts: [router("router-1", "PERSONAL", "personal@example.com")]
        )
        #expect(decision != .addStandalone)
    }

    @Test("Single email matches two router accounts → `conflict`")
    func sameEmailTwoRouterAccounts() {
        let r = AccountReconciler()
        let decision = r.decide(
            candidate: native("~/.claude-accounts/dup", "x@example.com"),
            routerAccounts: [
                router("a", "ALIAS_A", "x@example.com"),
                router("b", "ALIAS_B", "x@example.com")
            ]
        )
        if case let .conflict(routerAccounts, emails) = decision {
            #expect(routerAccounts.count == 2)
            // `conflictingEmails` is the SET of distinct emails in play — one
            // shared identity, multiple accounts. The reconciler dedupes by
            // convention so the caller can group by identity if it wants to.
            #expect(emails == Set(["x@example.com"]))
        } else {
            Issue.record("expected .conflict, got \(decision)")
        }
    }

    @Test("No verified email on the candidate → `addStandalone`")
    func noEmailAddsStandalone() {
        let r = AccountReconciler()
        let decision = r.decide(
            candidate: native("~/.claude-accounts/studio", nil),
            routerAccounts: [router("router-1", "PERSONAL", "personal@example.com")]
        )
        #expect(decision == .addStandalone)
    }

    @Test("Empty verified email → `addStandalone` (never match on empty)")
    func emptyEmailAddsStandalone() {
        let r = AccountReconciler()
        let decision = r.decide(
            candidate: native("~/.claude-accounts/studio", ""),
            routerAccounts: [router("router-1", "PERSONAL", "")]
        )
        #expect(decision == .addStandalone)
    }

    @Test("Email known by router but missing on candidate → `addStandalone`")
    func noMatchOnCandidateEmail() {
        let r = AccountReconciler()
        let decision = r.decide(
            candidate: native("~/.claude-accounts/studio", "elsewhere@example.com"),
            routerAccounts: [router("router-1", "PERSONAL", "personal@example.com")]
        )
        #expect(decision == .addStandalone)
    }

    @Test("Batch reconcile: two candidates sharing the same email → conflict, not link")
    func batchIntraCollisionEscalates() {
        let r = AccountReconciler()
        let decisions = r.reconcileBatch(
            candidates: [
                native("~/.claude-accounts/a", "personal@example.com"),
                native("~/.claude-accounts/b", "personal@example.com")
            ],
            routerAccounts: [router("router-1", "PERSONAL", "personal@example.com")]
        )
        // Both should be `conflict`, because two candidates race the same alias.
        #expect(decisions.allSatisfy { decision in
            if case .conflict = decision { return true } else { return false }
        })
    }

    @Test("Batch reconcile: distinct candidates keep distinct decisions")
    func batchKeepsDistinctDecisions() {
        let r = AccountReconciler()
        let decisions = r.reconcileBatch(
            candidates: [
                native("~/.claude-accounts/studio", "personal@example.com"),
                native("~/.claude-accounts/extra", nil)
            ],
            routerAccounts: [router("router-1", "PERSONAL", "personal@example.com")]
        )
        if decisions.count == 2 {
            #expect(decisions[0] != .addStandalone)
            #expect(decisions[1] == .addStandalone)
        } else {
            Issue.record("expected 2 decisions, got \(decisions.count)")
        }
    }
}
