import Foundation

/// The ONE table mapping a Cortex provider id to its llm-router provider id
/// (Contract A `router_provider`), and back (Contract B `route_now.provider`).
///
/// Owned here so the exporter (Cortex → router) and the "Priority" card
/// (router → Cortex icon + display name) can never drift apart (rules/81).
/// A provider absent from the table is not part of the shared roster: the
/// exporter skips it and the card falls back to the raw router id — never a
/// guessed identity (R37, 2026-09-23).
public enum RouterProviderIdMap {
    /// Cortex provider id → llm-router provider id.
    public static let routerByCortex: [String: String] = [
        "opencode-go": "opencode_go",
        "commandcode": "commandcode",
        "ollama": "ollama_cloud",
        "qwen": "bailian_token_plan",
        "minimax": "minimax_max",
        "glm": "glm_pro",
        "kimi": "kimi",
        "claude": "claude",
        "codex": "codex",
        "bedrock": "bedrock",
    ]

    /// llm-router provider id → Cortex provider id (derived, never hand-kept).
    public static let cortexByRouter: [String: String] = Dictionary(
        uniqueKeysWithValues: routerByCortex.map { ($0.value, $0.key) }
    )

    /// The router id a Cortex provider exports as, nil when not routable.
    public static func routerId(forCortex cortexId: String) -> String? {
        routerByCortex[cortexId]
    }

    /// The Cortex id behind a router recommendation, nil when unknown.
    public static func cortexId(forRouter routerId: String) -> String? {
        cortexByRouter[routerId]
    }

    /// True when Cortex publishes this provider's accounts to llm-router
    /// (Contract A) — i.e. a family preference on it reaches the brain.
    public static func isRoutable(_ cortexId: String) -> Bool {
        routerByCortex[cortexId] != nil
    }
}
