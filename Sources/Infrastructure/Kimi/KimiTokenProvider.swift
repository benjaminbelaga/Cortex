import Foundation
import Domain

/// Protocol for resolving Kimi authentication tokens.
/// Enables testability by allowing mock implementations.
public protocol KimiTokenProviding: Sendable {
    func resolveToken() throws -> String
}

/// Resolves the legacy direct-Kimi authentication token from the environment.
///
/// Router-backed quota reads are supplied by llm-router. Keeping this bounded
/// fallback supports upstream/manual profiles without requiring a browser-cookie
/// package whose current releases require a newer Swift toolchain than the app.
public struct KimiCookieTokenProvider: KimiTokenProviding {
    public init() {}

    public func resolveToken() throws -> String {
        if let envToken = ProcessInfo.processInfo.environment["KIMI_AUTH_TOKEN"],
           !envToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            AppLog.probes.debug("Kimi: Using token from KIMI_AUTH_TOKEN env var")
            return envToken
        }

        AppLog.probes.error(
            "Kimi: KIMI_AUTH_TOKEN is missing; authenticate the Kimi CLI for llm-router instead."
        )
        throw ProbeError.authenticationRequired
    }
}
