import AppKit
import Foundation
import Infrastructure

/// Opens a non-secret command in a terminal. A successful AppleScript launch
/// means only that the terminal opened; the command itself remains responsible
/// for writing its authentication or mission receipt.
enum TerminalCommandLauncher {
    struct Result: Sendable {
        let launched: Bool
        let message: String
    }

    static func open(_ command: String, successMessage: String) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let script = "tell application \"iTerm2\" to create window with default profile command \""
                + escapeForAppleScript(command) + "\""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stderr = Pipe()
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let detail = String(
                        data: stderr.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    AppLog.ui.error("terminal launcher failed rc=\(process.terminationStatus): \(detail)")
                    copyToClipboard(command)
                    return Result(launched: false, message: "Terminal indisponible — commande copiée")
                }
                AppLog.ui.info("terminal command launched; completion is receipt-driven")
                return Result(launched: true, message: successMessage)
            } catch {
                AppLog.ui.error("terminal launcher failed: \(error.localizedDescription)")
                copyToClipboard(command)
                return Result(launched: false, message: "Terminal indisponible — commande copiée")
            }
        }.value
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
