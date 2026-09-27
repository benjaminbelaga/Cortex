import AppKit
import Foundation
import Infrastructure

/// Opens a non-secret command in a terminal. A successful AppleScript launch
/// means only that the terminal opened; the command itself remains responsible
/// for writing its authentication or mission receipt.
///
/// Up to 2026-09-27 this ran `osascript` with a `Pipe` and called
/// `waitUntilExit()` before reading it (audit V2-06/T12). Three failures hid
/// behind that shape: a child that filled the ~64 KiB pipe buffer while the
/// parent waited deadlocked to its own timeout; the read happened after the
/// process exited, so early bytes could be lost; and a timeout mid-launch left
/// "did the terminal open?" unknowable. `BoundedProcessRunner` already solves
/// this class — it drains both streams from launch, caps them, and escalates
/// TERM → grace → SIGKILL — so the launcher delegates to it and keeps the one
/// question it actually owns: binary gone, or AppleScript invocation failed.
enum TerminalCommandLauncher {
    struct Result: Sendable {
        let launched: Bool
        let message: String
    }

    static func open(_ command: String, successMessage: String) async -> Result {
        let script = "tell application \"iTerm2\" to create window with default profile command \""
            + escapeForAppleScript(command) + "\""
        var options = BoundedProcessRunner.Options()
        // A launch is "open a window and return", not a build: it must not hang
        // the UI. On timeout the terminal *may* have opened, so the message
        // never claims it did not.
        options.timeout = 15

        do {
            let result = try await BoundedProcessRunner().run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                options: options
            )
            guard result.exitStatus == 0 else {
                let detail = result.stderrTail()
                AppLog.ui.error("terminal launcher failed rc=\(result.exitStatus): \(detail)")
                copyToClipboard(command)
                return Result(launched: false, message: "Terminal unavailable — command copied")
            }
            AppLog.ui.info("terminal command launched; completion is receipt-driven")
            return Result(launched: true, message: successMessage)
        } catch let error as ProcessRunError {
            // Distinguish "no /usr/bin/osascript" from "it ran but did not
            // finish": only the first is a missing binary.
            let missing = if case let .launchFailed(detail) = error {
                detail
            } else {
                ""
            }
            AppLog.ui.error("terminal launcher failed: \(error)")
            copyToClipboard(command)
            let message = missing.isEmpty
                ? "Terminal launch timed out — command copied"
                : "Terminal unavailable — command copied"
            return Result(launched: false, message: message)
        } catch {
            AppLog.ui.error("terminal launcher failed: \(error.localizedDescription)")
            copyToClipboard(command)
            return Result(launched: false, message: "Terminal unavailable — command copied")
        }
    }

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
