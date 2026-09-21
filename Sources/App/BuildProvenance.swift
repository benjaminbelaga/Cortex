import Foundation

/// Immutable source/build identity embedded by the exact-SHA CI workflow.
struct BuildProvenance: Equatable {
    let gitSHA: String
    let builtAtUTC: String
    let isDirty: Bool

    static var current: BuildProvenance {
        BuildProvenance(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        gitSHA = infoDictionary["ClaudeBarGitSHA"] as? String ?? "unknown"
        builtAtUTC = infoDictionary["ClaudeBarBuildUTC"] as? String ?? "unknown"
        isDirty = (infoDictionary["ClaudeBarGitDirty"] as? NSNumber)?.boolValue
            ?? (infoDictionary["ClaudeBarGitDirty"] as? Bool)
            ?? (infoDictionary["ClaudeBarGitDirty"] as? String).map { $0 != "false" }
            ?? true
    }

    var shortSHA: String {
        guard gitSHA != "unknown" else { return gitSHA }
        return String(gitSHA.prefix(12))
    }
}
