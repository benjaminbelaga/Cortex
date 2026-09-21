import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

/// Pins the three states of llm-router availability: not installed, installed
/// but registry missing/unreadable, fully available. Also checks the TTL cache.
@Suite("LLMRouterAvailability")
struct LLMRouterAvailabilityTests {

    @Test("Missing binary returns `.binaryNotFound`")
    func binaryMissing() async {
        let availability = LLMRouterAvailability(
            binaryLookup: { nil },
            registryReadable: { _ in true },
            homePath: { "/Users/nobody" }
        )
        let outcome = await availability.checkAvailability()
        #expect(outcome == .binaryNotFound)
    }

    @Test("Binary present but registry missing returns `.registryUnreadable`")
    func registryMissing() async {
        let availability = LLMRouterAvailability(
            binaryLookup: { "/opt/homebrew/bin/llm-router" },
            registryReadable: { _ in false },
            homePath: { "/Users/nobody" }
        )
        let outcome = await availability.checkAvailability()
        if case let .registryUnreadable(path) = outcome {
            #expect(path.contains(".config/llm-router"))
            #expect(path.contains("registry.yaml"))
        } else {
            Issue.record("expected .registryUnreadable, got \(outcome)")
        }
    }

    @Test("Both present returns `.available(binaryPath, registryPath)`")
    func available() async {
        let availability = LLMRouterAvailability(
            binaryLookup: { "/opt/homebrew/bin/llm-router" },
            registryReadable: { $0.contains("registry.yaml") },
            homePath: { "/Users/nobody" }
        )
        let outcome = await availability.checkAvailability()
        if case let .available(binaryPath, registryPath) = outcome {
            #expect(binaryPath == "/opt/homebrew/bin/llm-router")
            #expect(registryPath.contains("/Users/nobody/.config/llm-router/registry.yaml"))
        } else {
            Issue.record("expected .available, got \(outcome)")
        }
    }

    @Test("Empty binary path (binary lookup that returned empty string) is treated as missing")
    func emptyBinaryTreatedAsMissing() async {
        let availability = LLMRouterAvailability(
            binaryLookup: { "" },
            registryReadable: { _ in true },
            homePath: { "/Users/nobody" }
        )
        let outcome = await availability.checkAvailability()
        #expect(outcome == .binaryNotFound)
    }

    @Test("Caches the outcome for `cacheTTL`, then re-probes")
    func ttlCacheHitAndExpiry() async {
        let counter = Counter()
        let availability = LLMRouterAvailability(
            cacheTTL: 60,
            binaryLookup: {
                counter.bump()
                return "/opt/homebrew/bin/llm-router"
            },
            registryReadable: { _ in true },
            homePath: { "/Users/nobody" }
        )
        // First probe — cache miss.
        let first = await availability.checkAvailability(now: Date(timeIntervalSince1970: 1_000))
        #expect(counter.value == 1)
        // Second probe 10 s later — TTL = 60 s, still inside → no extra call.
        let second = await availability.checkAvailability(now: Date(timeIntervalSince1970: 1_010))
        #expect(counter.value == 1)
        #expect(first == second)
        // Third probe 80 s after the first — TTL expired → re-probe.
        let third = await availability.checkAvailability(now: Date(timeIntervalSince1970: 1_080))
        #expect(counter.value == 2)
        #expect(third == second)
    }

    @Test("`invalidate()` forces the next check to re-probe")
    func invalidateForcesReprobe() async {
        let counter = Counter()
        let availability = LLMRouterAvailability(
            cacheTTL: 60,
            binaryLookup: {
                counter.bump()
                return "/opt/homebrew/bin/llm-router"
            },
            registryReadable: { _ in true },
            homePath: { "/Users/nobody" }
        )
        _ = await availability.checkAvailability(now: Date(timeIntervalSince1970: 1_000))
        _ = await availability.checkAvailability(now: Date(timeIntervalSince1970: 1_010))
        #expect(counter.value == 1)
        await availability.invalidate()
        _ = await availability.checkAvailability(now: Date(timeIntervalSince1970: 1_020))
        #expect(counter.value == 2)
    }
}

/// Mutable counter used by the cache tests. `@unchecked Sendable` is justified
/// here because the only mutation happens inside the lookup closure, which runs
/// serially per `await`; Swift's strict concurrency can't statically see this.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func bump() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
