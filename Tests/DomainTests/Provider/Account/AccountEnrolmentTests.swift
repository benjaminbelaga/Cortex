import Foundation
import Testing
@testable import Domain

@Suite("AccountEnrolment")
struct AccountEnrolmentTests {

    // MARK: - Capabilities

    @Test("AccountCapabilities flag arithmetic — full set")
    func capabilitiesFullSet() {
        let all: AccountCapabilities = [
            .discover, .add, .reconnect, .readQuota, .readCost, .checkAvailability, .listObservations,
        ]
        for cap: AccountCapabilities in [
            .discover, .add, .reconnect, .readQuota, .readCost, .checkAvailability, .listObservations,
        ] {
            #expect(all.contains(cap))
        }
        // 7 bits set ⇒ (1<<7) - 1 = 0x7F
        #expect(all.rawValue == (1 << 7) - 1)
    }

    @Test("AccountCapabilities compose via union/intersect")
    func capabilitiesCompose() {
        let readOnly: AccountCapabilities = [.discover, .readQuota]
        #expect(readOnly.contains(.discover))
        #expect(!readOnly.contains(.add))
        let combined: AccountCapabilities = [.add, .reconnect]
        let joined = readOnly.union(combined)
        #expect(joined.contains(.add))
        #expect(joined.contains(.readQuota))
    }

    @Test("AccountCapabilities empty case")
    func capabilitiesEmpty() {
        let empty = AccountCapabilities()
        #expect(!empty.contains(.add))
        #expect(empty.rawValue == 0)
    }

    // MARK: - Auth reason + Login stage coverage

    @Test("AuthReason exhaustive coverage")
    func authReasonAll() {
        let cases: [AuthReason] = [
            .neverAuthenticated, .refreshTokenExpired, .credentialsRevoked, .explicitReconnect,
        ]
        #expect(cases.count == 4)
        #expect(cases.contains(.explicitReconnect))
    }

    @Test("LoginStage stable raw values")
    func loginStages() {
        let stages: [LoginStage] = [.launching, .waitingForUser, .pollingIdentity]
        #expect(stages.map { $0.rawValue } == ["launching", "waitingForUser", "pollingIdentity"])
    }

    // MARK: - EnrolmentError classification

    @Test("EnrolmentError recoverable classification")
    func enrolmentErrorRecoverability() {
        // Recoverable — transient or external cause
        #expect(EnrolmentError.timeout(afterSeconds: 5).isRecoverable)
        #expect(EnrolmentError.loginFailed(exitCode: 1, stderrTail: "boom").isRecoverable)
        #expect(EnrolmentError.dependencyMissing(tool: "claude").isRecoverable)
        #expect(EnrolmentError.registryRejected(reason: "alias collision").isRecoverable)
        #expect(EnrolmentError.underlying("oops").isRecoverable)
        // Not recoverable — hard contradictions or explicit cancel
        #expect(!EnrolmentError.cancelled.isRecoverable)
        #expect(!EnrolmentError.profileCollision(path: "/x").isRecoverable)
        #expect(!EnrolmentError.identityMismatch(expected: "a@b.c", actual: "x@y.z").isRecoverable)
    }

    @Test("EnrolmentError structural equality on payload")
    func enrolmentErrorEquality() {
        #expect(EnrolmentError.timeout(afterSeconds: 5) == EnrolmentError.timeout(afterSeconds: 5))
        #expect(EnrolmentError.timeout(afterSeconds: 5) != EnrolmentError.timeout(afterSeconds: 6))
        #expect(
            EnrolmentError.loginFailed(exitCode: 1, stderrTail: "x")
                == EnrolmentError.loginFailed(exitCode: 1, stderrTail: "x")
        )
        #expect(
            EnrolmentError.identityMismatch(expected: "a@b.c", actual: "x@y.z")
                != EnrolmentError.identityMismatch(expected: "a@b.c", actual: "w@y.z")
        )
    }

    // MARK: - EnrolmentState shapes & equality

    private static let sampleDescriptor = AccountDescriptor(
        uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        providerId: "claude", label: "Personal",
        profile: .claudeConfigDir("/home/u/.claude-personal"),
        source: .router
    )

    @Test("EnrolmentState equality carries observedAt timestamp")
    func stateQuotaReceivedEquality() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let s1: EnrolmentState = .quotaReceived(Self.sampleDescriptor, observedAt: now)
        let s2: EnrolmentState = .quotaReceived(Self.sampleDescriptor, observedAt: now)
        let s3: EnrolmentState = .quotaReceived(Self.sampleDescriptor, observedAt: now.addingTimeInterval(1))
        #expect(s1 == s2)
        #expect(s1 != s3)
    }

    @Test("EnrolmentState.failed carries descriptor + typed error")
    func stateFailed() {
        let desc = AccountDescriptor(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            providerId: "codex", label: "k",
            profile: .codexHome("/home/u/.codex-k"),
            source: .native
        )
        let s: EnrolmentState = .failed(desc, error: .timeout(afterSeconds: 300))
        guard case let .failed(d, e) = s else {
            Issue.record("expected .failed, got \(s)"); return
        }
        #expect(d.uuid == desc.uuid)
        #expect(e == .timeout(afterSeconds: 300))
    }

    @Test("EnrolmentState.cancelled may carry nil descriptor")
    func stateCancelledNoDescriptor() {
        let s: EnrolmentState = .cancelled(nil)
        guard case let .cancelled(d) = s else {
            Issue.record("expected .cancelled"); return
        }
        #expect(d == nil)
    }

    @Test("EnrolmentState.authRequired carries reason")
    func stateAuthRequired() {
        let s: EnrolmentState = .authRequired(Self.sampleDescriptor, reason: .refreshTokenExpired)
        guard case let .authRequired(d, reason) = s else {
            Issue.record("expected .authRequired"); return
        }
        #expect(d.uuid == Self.sampleDescriptor.uuid)
        #expect(reason == .refreshTokenExpired)
    }

    @Test("EnrolmentState.loginInProgress carries stage")
    func stateLoginInProgress() {
        let s: EnrolmentState = .loginInProgress(Self.sampleDescriptor, stage: .pollingIdentity)
        guard case let .loginInProgress(d, stage) = s else {
            Issue.record("expected .loginInProgress"); return
        }
        #expect(d.uuid == Self.sampleDescriptor.uuid)
        #expect(stage == .pollingIdentity)
    }

    // MARK: - EnrolmentIntent

    @Test("EnrolmentIntent carries optional expected email")
    func intentBuilder() {
        let desc = AccountDescriptor(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            providerId: "claude", label: "work",
            profile: .claudeConfigDir("/home/u/.claude-work"),
            source: .router
        )
        let a = EnrolmentIntent(descriptor: desc, expectedIdentityEmail: "b@y.fr", targetSource: .router)
        let b = EnrolmentIntent(descriptor: desc, expectedIdentityEmail: "b@y.fr", targetSource: .router)
        let c = EnrolmentIntent(descriptor: desc, expectedIdentityEmail: nil, targetSource: .router)
        let d = EnrolmentIntent(descriptor: desc, expectedIdentityEmail: "b@y.fr", targetSource: .native)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a.expectedIdentityEmail == "b@y.fr")
    }

    // MARK: - State coverage cross-check

    @Test("All EnrolmentState cases are constructable from a sample descriptor")
    func allStatesConstructable() {
        let d = Self.sampleDescriptor
        let v = VerifiedIdentity(
            email: "b@y.fr", orgId: nil, orgName: nil,
            verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            method: .claudeAuthStatus
        )
        let states: [EnrolmentState] = [
            .profileDetected(d),
            .authRequired(d, reason: .neverAuthenticated),
            .loginInProgress(d, stage: .launching),
            .identityConfirmed(d, identity: v),
            .quotaPending(d),
            .quotaReceived(d, observedAt: v.verifiedAt),
            .failed(d, error: .cancelled),
            .cancelled(d),
        ]
        #expect(states.count == 8)
    }
}
