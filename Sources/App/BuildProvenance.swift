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
        gitSHA = infoDictionary["CortexGitSHA"] as? String ?? "unknown"
        builtAtUTC = infoDictionary["CortexBuildUTC"] as? String ?? "unknown"
        isDirty = (infoDictionary["CortexGitDirty"] as? NSNumber)?.boolValue
            ?? (infoDictionary["CortexGitDirty"] as? Bool)
            ?? (infoDictionary["CortexGitDirty"] as? String).map { $0 != "false" }
            ?? true
    }

    var shortSHA: String {
        guard gitSHA != "unknown" else { return gitSHA }
        return String(gitSHA.prefix(12))
    }
}
