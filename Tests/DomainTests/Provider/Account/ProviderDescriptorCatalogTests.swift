import Testing
import Foundation
@testable import Domain

/// Pins the canonical provider catalog: ids, categories, capabilities and the
/// .autonomous vs .router support matrix.
///
/// C4 (2026-09-16) restored the four router-backed rows (kimi/qwen/glm/minimax)
/// that had silently vanished between B3-Startup and B3-final. The 2026-09-20
/// « Cortex modulaire » tranche extended the catalog to EVERY provider the
/// composition can build — the native probes used to live in a second, parallel
/// list inside `ProviderComposition`, which is exactly the drift this suite
/// exists to make impossible. It now pins the full 22: shrink or drift fails.
@Suite("ProviderDescriptor catalog")
struct ProviderDescriptorCatalogTests {

    /// Every id the composition can build, in catalog (= display) order.
    private static let shipped = [
        "claude", "codex", "kimi", "qwen", "glm", "minimax",
        "gemini", "antigravity", "copilot", "opencode-go", "commandcode", "ollama",
        "bedrock", "local", "ampcode", "kiro", "cursor",
        "deepseek", "vercel-gateway", "mistral", "omp", "grok",
    ]

    private static let routerOnly = ["kimi", "glm", "minimax", "bedrock", "local"]

    private static let optional = [
        "bedrock", "local", "ampcode", "kiro",
        "cursor", "deepseek", "vercel-gateway", "mistral", "omp", "grok",
    ]

    @Test("All shipped provider ids are present in the catalog, in display order")
    func allIdsPresent() {
        let actual = Set(ProviderCatalog.all.map(\.id))
        #expect(actual == Set(Self.shipped))
        #expect(ProviderCatalog.all.count == Self.shipped.count,
                "catalog must not contain duplicate ids")
        #expect(ProviderCatalog.all.map(\.id) == Self.shipped,
                "catalog order is the display order — reordering is a product decision")
    }

    @Test("Claude, Codex and Qwen support both modes; router rows support .router; native rows .autonomous")
    func supportedModesMatrix() {
        #expect(ProviderCatalog.descriptor(forId: "claude")?.supportedModes
                == [.autonomous, .router])
        #expect(ProviderCatalog.descriptor(forId: "codex")?.supportedModes
                == [.autonomous, .router])

        #expect(ProviderCatalog.descriptor(forId: "qwen")?.supportedModes == [.autonomous, .router])

        for id in Self.routerOnly {
            #expect(ProviderCatalog.descriptor(forId: id)?.supportedModes == [.router],
                    "router-backed provider \(id) must support .router only")
        }
        for id in ["gemini", "antigravity", "copilot", "opencode-go", "commandcode",
                   "ampcode", "kiro", "cursor", "deepseek", "vercel-gateway",
                   "mistral", "omp", "grok"] {
            #expect(ProviderCatalog.descriptor(forId: id)?.supportedModes == [.autonomous],
                    "native provider \(id) must support .autonomous only")
        }
    }

    @Test("Runtime and supported modes agree — a declaration can never contradict its builder")
    func runtimeMatchesModes() {
        for descriptor in ProviderCatalog.all {
            switch descriptor.runtime {
            case .router:
                #expect(descriptor.supportedModes == [.router],
                        "\(descriptor.id): a router runtime needs exactly [.router]")
            case .native:
                #expect(descriptor.supportedModes.contains(.autonomous),
                        "\(descriptor.id): a native runtime must support .autonomous")
            case .routerOrNative:
                #expect(descriptor.supportedModes == [.autonomous, .router],
                        "\(descriptor.id): a dual runtime must support both modes")
            }
        }
    }

    @Test("Every shipped provider declares its capabilities, including quota support")
    func capabilitiesDeclared() {
        for descriptor in ProviderCatalog.all {
            #expect(!descriptor.capabilities.isEmpty,
                    "\(descriptor.id): an empty capability set hides the module from the settings")
            #expect(descriptor.capabilities.contains(.quota),
                    "\(descriptor.id): every catalog row collects usage — .quota must hold")
        }
    }

    @Test("Account providers are not optional; optional connectors are exactly the opt-in roster")
    func optionalityMatrix() {
        for descriptor in ProviderCatalog.all {
            let mustBeOptional = Self.optional.contains(descriptor.id)
            #expect(descriptor.isOptional == mustBeOptional,
                    "\(descriptor.id): isOptional=\(descriptor.isOptional), expected \(mustBeOptional)")
        }
    }

    @Test("Account providers belong to `.account` category; the rest to `.integration`")
    func categories() {
        for id in ["claude", "codex", "kimi", "qwen", "glm", "minimax"] {
            #expect(ProviderCatalog.descriptor(forId: id)?.category == .account)
        }
        for descriptor in ProviderCatalog.all where descriptor.category == .account {
            #expect(["claude", "codex", "kimi", "qwen", "glm", "minimax"].contains(descriptor.id),
                    "\(descriptor.id): unexpected account-category row")
        }
    }

    @Test("Router-only ids are exactly the ones the fresh-install default unfollows")
    func routerOnlyIdsMatchTheFreshInstallDefault() {
        #expect(Set(ProviderCatalog.routerOnlyIDs) == Set(Self.routerOnly))
    }

    @Test("Unknown provider id returns nil (defensive composition)")
    func unknownIdReturnsNil() {
        #expect(ProviderCatalog.descriptor(forId: "mystery") == nil)
    }
}

@Suite("API-key account capability")
struct APIKeyAccountCapabilityTests {
    @Test func `api key providers are derived from the catalog`() {
        #expect(ProviderCatalog.apiKeyAccountIDs == ["opencode-go", "commandcode", "ollama"])
        #expect(ProviderCatalog.addableAccountIDs == ["claude", "codex", "opencode-go", "commandcode", "ollama"])
    }
}
