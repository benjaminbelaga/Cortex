import Foundation

/// Claude-only local features that remain outside the llm-router quota SSOT.
///
/// The menu UI depends on this narrow capability instead of the concrete
/// `ClaudeProvider`, allowing a router-backed quota implementation to coexist
/// with local daily reports and guest-pass actions.
@MainActor
public protocol ClaudeSupplementProviding: AnyObject {
    var guestPass: ClaudePass? { get }
    var isFetchingPasses: Bool { get }
    var passError: Error? { get }
    var supportsGuestPasses: Bool { get }

    @discardableResult
    func fetchPasses() async throws -> ClaudePass
    func clearPassError()
}
