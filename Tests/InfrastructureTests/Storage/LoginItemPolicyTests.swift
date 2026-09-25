import Testing
@testable import Infrastructure

struct LoginItemPolicyTests {
    @Test
    func `installed release app may register at login`() {
        #expect(LoginItemPolicy.canRegister(bundlePath: "/Applications/Cortex.app", isDebugBuild: false))
    }

    @Test
    func `a debug build never registers, even from Applications`() {
        #expect(!LoginItemPolicy.canRegister(bundlePath: "/Applications/Cortex.app", isDebugBuild: true))
    }

    @Test
    func `a DerivedData or backup bundle never registers`() {
        #expect(!LoginItemPolicy.canRegister(
            bundlePath: "/Users/me/Library/Developer/Xcode/DerivedData/Cortex-x/Build/Products/Debug/Cortex.app",
            isDebugBuild: false))
        #expect(!LoginItemPolicy.canRegister(bundlePath: "/tmp/Cortex-rolledback.app", isDebugBuild: false))
        #expect(!LoginItemPolicy.canRegister(bundlePath: "/Applications/../tmp/Cortex.app", isDebugBuild: false))
    }
}
