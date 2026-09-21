import Foundation
import Mockable

/// Protocol for resolving Alibaba browser cookies.
/// Enables testability by allowing mock implementations.
@Mockable
public protocol AlibabaCookieProviding: Sendable {
    /// Attempts to extract Alibaba Cloud cookies from browser cookie stores.
    /// Returns the cookie string if found, nil otherwise.
    func extractBrowserCookies() -> String?
}
