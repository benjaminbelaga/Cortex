import Foundation
import Domain

/// Where llm-router stores its user config. Public for tests and migration.
public enum LLMRouterPaths {
    public static let registryPath: String = "~/.config/llm-router/registry.yaml"
}

/// What "available" means for llm-router, in the order the resolver checks it.
/// - `.binaryNotFound`       : the executable is not on PATH (and not in common paths).
/// - `.registryUnreadable`  : the binary is there but `~/.config/llm-router/registry.yaml`
///                            is missing or unreadable. The router can technically run
///                            without accounts — but in practice every Cortex user
///                            cares about the registry, and asking for "router mode" with
///                            no registered account always degrades to a confusing state.
///                            So this is treated as "not available" for source-mode purposes.
/// - `.available(binaryPath)` : both checks passed; the router is ready to be the
///                              authoritative source.
public enum LLMRouterAvailabilityOutcome: Sendable, Equatable {
    case available(binaryPath: String, registryPath: String)
    case binaryNotFound
    case registryUnreadable(path: String)
}

/// Narrow seam that asks the OS whether llm-router is reachable today. Lives in
/// Infrastructure (I/O) but exposes a pure-Domain-friendly protocol so the
/// QuotaSourceResolver composition can be tested without a real binary.
public protocol LLMRouterAvailabilityChecking: Sendable {
    func checkAvailability(now: Date) async -> LLMRouterAvailabilityOutcome
}

/// Caches the last outcome for `cacheTTL` seconds. The reset is automatic on
/// expiry; the cache also exposes `invalidate()` so a freshly enrolled user
/// account or a router-mode toggle can clear it without waiting for TTL.
///
/// The cache is intentionally conservative: a binary that disappeared between
/// `available` and the next check is the user's system, and we want to see the
/// demoted line in the UI — better than a stale green.
public actor LLMRouterAvailability: LLMRouterAvailabilityChecking {

    public typealias BinaryLookup = @Sendable () -> String?
    public typealias RegistryReadable = @Sendable (_ path: String) -> Bool
    public typealias HomePath = @Sendable () -> String

    private let binaryLookup: BinaryLookup
    private let registryReadable: RegistryReadable
    private let homePath: HomePath
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    private struct Entry {
        let outcome: LLMRouterAvailabilityOutcome
        let observedAt: Date
    }
    private var cached: Entry?

    public init(
        cacheTTL: TimeInterval = 60,
        binaryLookup: @escaping BinaryLookup = { BinaryLocator.which("llm-router") },
        registryReadable: @escaping RegistryReadable = { path in
            FileManager.default.isReadableFile(atPath: path)
        },
        homePath: @escaping HomePath = {
            FileManager.default.homeDirectoryForCurrentUser.path
        },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.binaryLookup = binaryLookup
        self.registryReadable = registryReadable
        self.homePath = homePath
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    public func checkAvailability(now: Date) async -> LLMRouterAvailabilityOutcome {
        let at = now
        if let entry = cached, at.timeIntervalSince(entry.observedAt) < cacheTTL {
            return entry.outcome
        }
        let resolved = Self.resolve(binary: binaryLookup(), homePath: homePath(),
                                    registryReadable: registryReadable)
        cached = Entry(outcome: resolved, observedAt: at)
        return resolved
    }

    /// Convenience: probe the system right now (no caller-supplied clock).
    public func checkAvailability() async -> LLMRouterAvailabilityOutcome {
        await checkAvailability(now: clock())
    }

    /// Drops the cache so the next `checkAvailability` re-probes the system.
    /// Called when the user toggles router mode in settings, or after a
    /// successful enrollment changes the registry.
    public func invalidate() {
        cached = nil
    }

    // MARK: - Pure resolver (testable, no actor isolation needed)

    private static func resolve(
        binary: String?,
        homePath: String,
        registryReadable: (String) -> Bool
    ) -> LLMRouterAvailabilityOutcome {
        guard let binaryPath = binary, !binaryPath.isEmpty else {
            return .binaryNotFound
        }
        // Expand `~` the user's home and resolve symlinks so a moved config dir
        // is recognised as the same path the resolver will see next time.
        let expanded = registryPathExpanded(homePath: homePath)
        let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        if registryReadable(canonical) {
            return .available(binaryPath: binaryPath, registryPath: canonical)
        }
        return .registryUnreadable(path: canonical)
    }

    /// `~`-expansion into `$HOME`, falling back to a system tmp inspection if the
    /// home path is empty (it should never be on macOS, but defensive coding
    /// here keeps this pure function trivially testable).
    private static func registryPathExpanded(homePath: String) -> String {
        let home = homePath.isEmpty ? "/tmp" : homePath
        let trimmed = LLMRouterPaths.registryPath.hasPrefix("~/")
            ? LLMRouterPaths.registryPath.dropFirst(2)
            : LLMRouterPaths.registryPath[...]
        return home + "/" + String(trimmed)
    }
}
