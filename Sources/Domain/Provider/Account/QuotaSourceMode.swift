import Foundation

/// Where Cortex should read quota/identity for a provider. Two shapes:
/// - `.autonomous` : native Claude / Codex probes, no llm-router dependency.
/// - `.router`     : llm-router (and its registry) is the authoritative source.
///
/// The mode is a *preference* layered over the live router/cswap availability.
/// A `.router` request is honoured only when the router is actually reachable;
/// otherwise the source degrades to `.autonomous` and the mismatch is signalled
/// to the caller via `QuotaSourceModeResolution.degradedTo`. A `.autonomous`
/// request is honoured regardless — the router does not get in the way.
public enum QuotaSourceMode: String, Sendable, Equatable, Codable, CaseIterable {
    case autonomous
    case router
}

/// A concrete mode decision for a provider, after the resolver has consulted the
/// configured preference AND the live router availability. `degradedTo` is non-nil
/// ONLY when the configured mode was `.router` and the router was unavailable
/// — that is the state the UI shows as "Router unavailable · native probe".
public struct QuotaSourceModeResolution: Sendable, Equatable {
    public let providerId: String
    public let configured: QuotaSourceMode
    public let effective: QuotaSourceMode
    public let degradedTo: QuotaSourceMode?

    public init(
        providerId: String,
        configured: QuotaSourceMode,
        effective: QuotaSourceMode,
        degradedTo: QuotaSourceMode?
    ) {
        self.providerId = providerId
        self.configured = configured
        self.effective = effective
        self.degradedTo = degradedTo
    }
}

/// Source of truth for "which mode should provider X use today". Pure Domain:
/// inputs are `ProviderAccountConfig.probeConfig` (already loaded by the caller)
/// and a router availability probe (caller's responsibility, async). No I/O
/// happens here; the resolver owns the policy only.
///
/// The `integration` probeConfig key (`integration.legacyAliasBinding` etc.) is
/// intentionally not consumed here — the resolver's only knobs are the per-account
/// override and the global default. Anything else belongs in a higher layer.
public struct QuotaSourceResolver: Sendable {

    public init() {}

    /// Resolves the effective mode for `providerId`. `routerAvailable = false` is
    /// the sole condition that demotes a `.router` configuration to `.autonomous`.
    /// Installed fresh: `providerId == "claude"` and `"codex"` default to
    /// `.autonomous`; everything else (`qwen-api`, `bedrock`, `local`, …) keeps
    /// `.autonomous` since the router has nothing authoritative to offer.
    public func resolve(
        providerId: String,
        accounts: [ProviderAccountConfig],
        routerAvailable: Bool,
        globalDefault: QuotaSourceMode = .autonomous
    ) -> QuotaSourceModeResolution {
        let configured = configuredMode(
            providerId: providerId, accounts: accounts, globalDefault: globalDefault
        )
        if configured == .router && !routerAvailable {
            return QuotaSourceModeResolution(
                providerId: providerId,
                configured: .router,
                effective: .autonomous,
                degradedTo: .autonomous
            )
        }
        return QuotaSourceModeResolution(
            providerId: providerId,
            configured: configured,
            effective: configured,
            degradedTo: nil
        )
    }

    /// The configured mode as if the router were reachable. The migration can
    /// replay this on app start to write the right setting (router-present users
    /// get `.router` recorded so a later offline start still has a consistent
    /// configured value).
    public func configuredMode(
        providerId: String,
        accounts: [ProviderAccountConfig],
        globalDefault: QuotaSourceMode = .autonomous
    ) -> QuotaSourceMode {
        let key = "providers.\(providerId).sourceMode"
        for account in accounts {
            if let raw = account.probeConfig[key],
               let mode = QuotaSourceMode(rawValue: raw)
            {
                return mode
            }
        }
        return globalDefault
    }
}
