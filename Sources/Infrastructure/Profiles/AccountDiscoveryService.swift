import Foundation
import Domain

/// A validated, authenticated profile Cortex could start tracking. Identity is
/// shown masked in the UI; the raw email is here so an accepted proposal can be
/// recorded as a verified identity.
public struct AccountProposal: Sendable, Equatable {
    public let providerId: String
    public let profile: ProfileReference
    public let canonicalPath: String
    public let email: String?

    public init(providerId: String, profile: ProfileReference, canonicalPath: String, email: String?) {
        self.providerId = providerId
        self.profile = profile
        self.canonicalPath = canonicalPath
        self.email = email
    }
}

/// Confirms whether a profile directory is actually authenticated, returning the
/// email it reads back (nil = not authenticated). A detected directory is never
/// proof of a connection, so discovery proposes only what this validates.
public protocol ProfileIdentityValidating: Sendable {
    func authenticatedEmail(forProvider providerId: String, profilePath: String) async -> String?
}

/// Reconciles resolver candidates against the accounts already tracked and
/// proposes the authenticated newcomers. Runs off the main thread, bounds each
/// validation and the whole sweep, honours cancellation, and never re-proposes a
/// profile the user already tracks or explicitly rejected. It is deliberately
/// not run at app init — a first render must not wait on N CLI probes.
public actor AccountDiscoveryService {
    private let resolver: any ProfileResolving
    private let validator: any ProfileIdentityValidating

    public init(resolver: any ProfileResolving, validator: any ProfileIdentityValidating) {
        self.resolver = resolver
        self.validator = validator
    }

    public func discover(
        forProvider providerId: String,
        homeDirectory: String,
        userPaths: [String] = [],
        existing: [AccountDescriptor],
        perCandidateTimeout: TimeInterval = 5,
        totalBudget: TimeInterval = 15
    ) async -> [AccountProposal] {
        let candidates = resolver.candidateProfiles(
            forProvider: providerId, homeDirectory: homeDirectory, userPaths: userPaths
        )

        let owned = Set(existing.compactMap { $0.profile.localPath.map(Self.canonical) })
        let rejected = Set(existing
            .filter { $0.visibility == .rejected }
            .compactMap { $0.profile.localPath.map(Self.canonical) })
        let todo = candidates.filter {
            !owned.contains($0.canonicalPath) && !rejected.contains($0.canonicalPath)
        }
        guard !todo.isEmpty else { return [] }

        let validator = self.validator
        return await withTaskGroup(of: AccountProposal?.self) { group in
            for candidate in todo {
                group.addTask {
                    if Task.isCancelled { return nil }
                    let outcome = await Self.withTimeout(perCandidateTimeout) {
                        await validator.authenticatedEmail(
                            forProvider: candidate.providerId,
                            profilePath: candidate.canonicalPath
                        )
                    }
                    // outer nil = timed out; inner nil = not authenticated.
                    // Propose only authenticated candidates (an email read back).
                    guard let inner = outcome, let address = inner else { return nil }
                    return AccountProposal(
                        providerId: candidate.providerId,
                        profile: candidate.profile,
                        canonicalPath: candidate.canonicalPath,
                        email: address
                    )
                }
            }

            var results: [AccountProposal] = []
            let deadline = Date().addingTimeInterval(totalBudget)
            for await proposal in group {
                if let proposal { results.append(proposal) }
                if Date() > deadline { group.cancelAll(); break }
            }
            return results
        }
    }

    // MARK: - Helpers

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Races `op` against a sleep; returns nil on timeout. The outer optional is
    /// the timeout, the inner is `op`'s own "not authenticated" result.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ op: @Sendable @escaping () async -> T?
    ) async -> T?? {
        await withTaskGroup(of: T??.self) { group in
            group.addTask { .some(await op()) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return Optional<T?>.none
            }
            let first = await group.next() ?? .none
            group.cancelAll()
            return first
        }
    }
}
