import Foundation
import Domain

/// Compatibility placeholder for upstream's optional automatic cookie import.
/// Router-backed builds avoid browser credential scraping and use llm-router
/// for quota state. Manual Alibaba cookie/API-key configuration remains available.
public struct AlibabaBrowserCookieProvider: AlibabaCookieProviding {
    public init() {}

    public func extractBrowserCookies() -> String? {
        AppLog.probes.debug("Alibaba: Automatic browser-cookie import is disabled in router-backed builds")
        return nil
    }
}
