import Foundation

/// A model family the user prefers to run on a subscription (Ben 2026-09-23:
/// "je vais choisir DeepSeek, avec le petit logo à gauche"). Families, not
/// exact model ids: the served model behind an alias is unknown (bible §6),
/// so this is a display preference and never a routing guarantee.
public enum ModelFamily: String, CaseIterable, Sendable, Hashable, Identifiable {
    case deepseek, qwen, glm, kimi, minimax, mimo, claude, gpt

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .qwen: "Qwen"
        case .glm: "GLM"
        case .kimi: "Kimi"
        case .minimax: "MiniMax"
        case .mimo: "MiMo"
        case .claude: "Claude"
        case .gpt: "GPT"
        }
    }

    /// Family of a concrete model id ("deepseek-v4-pro", "qwen3.8-max", "glm-5.3").
    public init?(modelId: String) {
        let id = modelId.lowercased()
        let prefixes: [(String, ModelFamily)] = [
            ("deepseek", .deepseek), ("qwen", .qwen), ("glm", .glm), ("kimi", .kimi), ("k2", .kimi), ("k3", .kimi),
            ("minimax", .minimax), ("mimo", .mimo), ("claude", .claude), ("gpt", .gpt), ("o3", .gpt), ("o4", .gpt),
        ]
        guard let family = prefixes.first(where: { id.hasPrefix($0.0) })?.1 else { return nil }
        self = family
    }

    /// Family of a catalog provider family (`providers.yaml` `family:` key),
    /// e.g. "zai" → .glm, "moonshot" → .kimi. Returns nil for families Cortex
    /// has no logo/preference for (anthropic, openai, local, bedrock, …).
    /// This is the router-driven path: new families arrive via the Contract B
    /// snapshot, not via a Cortex release.
    public init?(catalogFamily: String) {
        switch catalogFamily.lowercased() {
        case "deepseek": self = .deepseek
        case "qwen", "alibaba_qwen": self = .qwen
        case "glm", "zai": self = .glm
        case "kimi", "moonshot": self = .kimi
        case "minimax": self = .minimax
        case "mimo": self = .mimo
        case "claude", "anthropic": self = .claude
        case "gpt", "openai": self = .gpt
        default: return nil
        }
    }

    /// Stored ids → families, unknown ids dropped, catalog order kept.
    public static func families(from ids: [String]) -> [ModelFamily] {
        let set = Set(ids)
        return allCases.filter { set.contains($0.rawValue) }
    }

    /// Families offered for a provider, resolved from the router's catalog
    /// families first (live), falling back to the static set when the router
    /// has not reported any (offline / older snapshot). Deduped, catalog order.
    public static func offered(catalogFamilies: [String]) -> [ModelFamily] {
        let resolved = catalogFamilies.compactMap(ModelFamily.init(catalogFamily:))
        let unique = resolved.reduce(into: [ModelFamily]()) { acc, f in
            if !acc.contains(f) { acc.append(f) }
        }
        return unique.isEmpty ? allCases : unique
    }
}

/// Pure toggle for a row's preferred-model list, shared by the context menu and
/// the icon popover so both mutate settings identically. Returns nil when the
/// list empties, so the caller clears the key rather than storing an empty list.
public enum PreferredModelsToggle {
    public static func toggled(_ family: ModelFamily, in current: [String]?) -> [String]? {
        var ids = current ?? []
        if let index = ids.firstIndex(of: family.rawValue) {
            ids.remove(at: index)
        } else {
            ids.append(family.rawValue)
        }
        return ids.isEmpty ? nil : ids
    }
}
