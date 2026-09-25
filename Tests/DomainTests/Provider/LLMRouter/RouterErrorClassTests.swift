import Testing
@testable import Domain

/// error_class → French line label mapping (v7.2, task 7).
@Suite("RouterErrorClass")
struct RouterErrorClassTests {

    @Test("known classes map to their French label")
    func knownClasses() {
        #expect(RouterErrorClass.label("subscription_inactive") == "MiniMax subscription inactive")
        #expect(RouterErrorClass.label("manual_quota_missing") == "Manual quota not synced")
        #expect(RouterErrorClass.label("auth_expired") == "Alibaba console session expired")
    }

    @Test("unknown, empty and nil classes fall back to nil (caller keeps the raw string)")
    func fallsBack() {
        #expect(RouterErrorClass.label("something_else") == nil)
        #expect(RouterErrorClass.label("") == nil)
        #expect(RouterErrorClass.label(nil) == nil)
    }
}
