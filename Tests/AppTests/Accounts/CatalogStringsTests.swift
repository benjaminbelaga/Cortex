import Testing
import Foundation
import Domain
@testable import Cortex

/// D tranche — every typed enrolment state and error renders a non-empty
/// French label (a new enum case must fail here, never silently render an
/// empty row), and identity-bearing details are masked.
@Suite("CatalogStrings — labels per typed state")
struct CatalogStringsTests {

    private func descriptor() -> AccountDescriptor {
        AccountDescriptor(
            providerId: "claude",
            label: "STUDIO",
            profile: .claudeConfigDir("/tmp/x/.claude-studio"),
            source: .native
        )
    }

    private func identity() -> VerifiedIdentity {
        VerifiedIdentity(
            email: "studio@example.com",
            verifiedAt: Date(),
            method: .claudeAuthStatus
        )
    }

    private var allStates: [EnrolmentState] {
        let d = descriptor()
        return [
            .profileDetected(d),
            .authRequired(d, reason: .neverAuthenticated),
            .authRequired(d, reason: .refreshTokenExpired),
            .authRequired(d, reason: .credentialsRevoked),
            .authRequired(d, reason: .explicitReconnect),
            .loginInProgress(d, stage: .launching),
            .loginInProgress(d, stage: .waitingForUser),
            .loginInProgress(d, stage: .pollingIdentity),
            .identityConfirmed(d, identity: identity()),
            .quotaPending(d),
            .quotaReceived(d, observedAt: Date()),
            .failed(d, error: .dependencyMissing(tool: "claude")),
            .failed(d, error: .loginFailed(exitCode: 1, stderrTail: "boom")),
            .failed(d, error: .identityMismatch(expected: "a@example.com", actual: "b@example.com")),
            .failed(d, error: .profileCollision(path: "/tmp/x")),
            .failed(d, error: .registryRejected(reason: "rejected")),
            .failed(d, error: .timeout(afterSeconds: 300)),
            .failed(d, error: .underlying("kaboom")),
            .cancelled(d),
        ]
    }

    @Test("every state has a non-empty title")
    func titlesNonEmpty() {
        for state in allStates {
            #expect(!CatalogStrings.title(for: state).isEmpty,
                    "empty title for \(String(describing: state))")
        }
    }

    @Test("identity confirmation detail carries the MASKED email, never the raw one")
    func identityMaskedInDetail() {
        let state = EnrolmentState.identityConfirmed(descriptor(), identity: identity())
        let detail = CatalogStrings.detail(for: state) ?? ""
        #expect(detail.contains("s***@e***.com"))
        #expect(!detail.contains("studio@example.com"))
    }

    @Test("identityMismatch detail masks both sides and states nothing was persisted")
    func mismatchDetailMasks() {
        let detail = CatalogStrings.detail(
            for: EnrolmentError.identityMismatch(expected: "a@example.com", actual: "b@example.com")
        ) ?? ""
        #expect(detail.contains("b***@e***.com"))
        #expect(!detail.contains("b@example.com"))
        #expect(detail.contains("Nothing was saved"))
    }

    @Test("quotaPending reads as a valid state, not an error")
    func quotaPendingIsNotAnError() {
        let title = CatalogStrings.title(for: .quotaPending(descriptor()))
        #expect(title.contains("Connected"))
        #expect(title.contains("pending"))
        #expect(!title.lowercased().contains("échec"))
    }

    @Test("cancelled states that nothing was registered")
    func cancelledSaysNothingPersisted() {
        let detail = CatalogStrings.detail(for: .cancelled(descriptor())) ?? ""
        #expect(detail.contains("Nothing was saved"))
    }

    @Test("terminal states are distinct — success never reuses a failure label")
    func distinctTerminalLabels() {
        let success = CatalogStrings.title(for: .quotaReceived(descriptor(), observedAt: Date()))
        let pending = CatalogStrings.title(for: .quotaPending(descriptor()))
        let failed = CatalogStrings.title(for: .failed(descriptor(), error: .timeout(afterSeconds: 1)))
        #expect(success != failed)
        #expect(pending != failed)
        #expect(success != pending)
    }
}
