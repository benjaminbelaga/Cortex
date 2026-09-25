import Testing
@testable import Domain

/// R37 (v7.3): one table for Cortex ⇄ llm-router provider ids, both directions
/// derived from the same source so the exporter and the "Priorité" card agree.
@Suite("RouterProviderIdMap")
struct RouterProviderIdMapTests {

    @Test("every Cortex id round-trips through its router id")
    func roundTrip() {
        for (cortex, router) in RouterProviderIdMap.routerByCortex {
            #expect(RouterProviderIdMap.routerId(forCortex: cortex) == router)
            #expect(RouterProviderIdMap.cortexId(forRouter: router) == cortex)
        }
        #expect(RouterProviderIdMap.routerByCortex.count == RouterProviderIdMap.cortexByRouter.count,
                "router ids must be unique or the inverse table silently loses a provider")
    }

    @Test("route_now ids that differ from Cortex ids resolve to the icon owner")
    func routerSpecificIds() {
        #expect(RouterProviderIdMap.cortexId(forRouter: "opencode_go") == "opencode-go")
        #expect(RouterProviderIdMap.cortexId(forRouter: "glm_pro") == "glm")
        #expect(RouterProviderIdMap.cortexId(forRouter: "ollama_cloud") == "ollama")
        #expect(RouterProviderIdMap.cortexId(forRouter: "bailian_token_plan") == "qwen")
        #expect(RouterProviderIdMap.cortexId(forRouter: "minimax_max") == "minimax")
    }

    @Test("unknown ids are nil in both directions, never guessed")
    func unknown() {
        #expect(RouterProviderIdMap.cortexId(forRouter: "qwen_cloud_payg") == nil)
        #expect(RouterProviderIdMap.routerId(forCortex: "gemini") == nil)
        #expect(!RouterProviderIdMap.isRoutable("copilot"))
        #expect(RouterProviderIdMap.isRoutable("commandcode"))
    }
}
