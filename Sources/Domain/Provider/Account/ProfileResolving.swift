import Foundation

/// A profile location found on disk (or explicitly chosen), before any identity
/// validation. `canonicalPath` is the realpath used for de-duplication, so two
/// symlinked candidates collapse to one account.
public struct DiscoveredProfile: Sendable, Equatable {
    public let providerId: String
    public let profile: ProfileReference
    public let canonicalPath: String

    public init(providerId: String, profile: ProfileReference, canonicalPath: String) {
        self.providerId = providerId
        self.profile = profile
        self.canonicalPath = canonicalPath
    }
}

/// Why a new profile path could not be proposed.
public enum ProfileResolutionError: Error, Sendable, Equatable {
    /// The slugged directory already exists and belongs to another account.
    case profileCollision(path: String)
    /// The provider is not one this resolver knows how to place.
    case unsupportedProvider(String)
}

/// The single seam that discovery, enrolment and collection all use to locate
/// account profiles, so the format written by enrolment is always the format
/// read back by discovery. Implementations only enumerate and propose paths;
/// they never authenticate or read a credential.
public protocol ProfileResolving: Sendable {
    /// Every candidate profile for a provider: the default location, the flat
    /// `~/.<tool>-<x>` dirs, the nested `~/.<tool>-accounts/<x>` dirs, and any
    /// explicitly configured user paths. De-duplicated by canonical path.
    func candidateProfiles(
        forProvider providerId: String,
        homeDirectory: String,
        userPaths: [String]
    ) -> [DiscoveredProfile]

    /// A fresh, collision-checked profile path for a new account with `label`.
    /// Fails if the slugged directory exists and is not among `ownedPaths`.
    func proposePath(
        forProvider providerId: String,
        label: String,
        homeDirectory: String,
        ownedPaths: [String]
    ) -> Result<ProfileReference, ProfileResolutionError>
}
