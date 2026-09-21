import Foundation
import Infrastructure

/// Fires Mac Guardian's non-interactive actions (`guardian.py --action <id>`)
/// off the main actor, replacing the SwiftBar `guardian.10s.sh` button row.
/// guardian.py owns its own audit trail (`~/.claude/state/guardian/actions.jsonl`);
/// this seam only launches the subprocess and never parses credentials.
enum GuardianAction: String, CaseIterable, Identifiable {
    case killOrphans = "kill_orphans"
    case purge
    case restartFontd = "restart_fontd"
    case tick

    var id: String { rawValue }

    /// SF Symbol shown on the button.
    var symbol: String {
        switch self {
        case .killOrphans: return "trash"
        case .purge: return "wind"
        case .restartFontd: return "textformat"
        case .tick: return "arrow.clockwise"
        }
    }

    /// Short French label.
    var label: String {
        switch self {
        case .killOrphans: return "Orphelins"
        case .purge: return "Purge"
        case .restartFontd: return "Fontd"
        case .tick: return "Tick"
        }
    }

    /// Arguments passed to guardian.py. `.tick` is a flag, the rest are `--action`.
    var arguments: [String] {
        switch self {
        case .tick: return ["--tick"]
        default: return ["--action", rawValue]
        }
    }
}

enum GuardianActionRunner {
    private static var scriptPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("repos/mac-guardian/guardian.py")
    }

    private static var rulesPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("repos/mac-guardian/rules.yaml")
    }

    /// Runs one Guardian action, resolving `python3` through the login PATH.
    static func run(_ action: GuardianAction) async {
        await launch(["python3", scriptPath] + action.arguments)
    }

    /// Opens `rules.yaml` in the default editor.
    static func editRules() async {
        await launch(["open", "-t", rulesPath])
    }

    private static func launch(_ argv: [String]) async {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let deadline = Date().addingTimeInterval(30)
                while process.isRunning, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                if process.isRunning { process.terminate() }
            } catch {
                AppLog.ui.error("Guardian action failed: \(error.localizedDescription)")
            }
        }.value
    }
}
