import Foundation

/// Which Cortex bundle may launch at login. `SMAppService.mainApp` records the
/// URL of whichever bundle registered last: a Debug/DerivedData build that
/// registers once keeps a second Cortex in the menu bar after every reboot
/// (two brain icons, 2026-09-25). Only the installed release app may register.
public enum LoginItemPolicy {
    public static func canRegister(bundlePath: String, isDebugBuild: Bool) -> Bool {
        guard !isDebugBuild else { return false }
        let path = (bundlePath as NSString).standardizingPath
        return path.hasPrefix("/Applications/") && path.hasSuffix(".app")
    }
}
