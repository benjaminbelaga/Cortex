import Foundation

/// Typed authentication state for an account row (D tranche — honest states).
///
/// Replaces the text heuristics that used to decide whether a row deserves a
/// "Connecter" button (searching the error message for a French sentence).
/// The state is derived from the router's own `present`/`auth_state` fields by
/// `RouterBackedProvider` and consumed by the row presentation; a row with no
/// reporting reads `.unknown`, never fabricated healthy nor alarming.
public enum AccountAuthState: String, Sendable, Equatable, Hashable {
    /// The account is logged in and its credentials are usable.
    case connected
    /// The credential lineage is broken (cswap slot lost its credential,
    /// refresh token dead) — the row offers a guided reconnect.
    case reconnectRequired
    /// An enrolment/reconnect flow is currently running for this account.
    case loginInProgress
    /// No signal yet (fresh install, probe never ran, provider without auth
    /// reporting).
    case unknown
}

/// Providers that report a typed auth state per account expose it here.
/// The dictionary is keyed like `MultiAccountProvider.accounts`'s `accountId`;
/// accounts missing from it read as `.unknown`. Main-actor isolated like the
/// sibling reporting protocols (`MultiAccountProvider`, `GroupErrorReporting`)
/// — the state derives from @MainActor provider internals.
@MainActor
public protocol AccountStateReporting {
    var accountAuthStates: [String: AccountAuthState] { get }
}

/// How live the row's data is — drives the fleet summary and the age badges
/// without ever inventing a 0 % or a 100 %.
public enum RowDataState: Sendable, Equatable {
    /// The provider never produced a reading (fresh install, never probed).
    case neverReceived
    /// At least one window carries a fresh (non-stale) reading.
    case fresh(observedAt: Date?)
    /// Windows exist but every one of them is stale — the last reading is
    /// retained and shown muted with its original age.
    case stale(observedAt: Date?)
    /// The collection failed and no window survived (the reason, if any,
    /// belongs to the tooltip — the row shows a typed action instead).
    case failed(reason: String?)
}

/// Menu-bar synthesis of the whole fleet ("synthèse flotte"). `.unknown` is a
/// first-class answer: no exploitable measurement means a grey dot and an
/// honest label, never a borrowed green or red.
public enum FleetAvailabilitySummary: Sendable, Equatable {
    case unknown
    /// `status` is the worst FRESH window status (stale readings never color
    /// the fleet glyph); `usable` counts rows with a non-depleted fresh
    /// window, `needsAction` counts reconnect/failed rows, `unknownCount`
    /// counts rows that never produced a reading.
    case known(status: QuotaStatus, usable: Int, needsAction: Int, unknownCount: Int)
}

/// Masks an email for the catalogue, tooltips and diagnostics exports:
/// `sam@example.com` → `s***@e***.com`. Non-email strings (paths, labels)
/// surface as-is — masking must never corrupt a non-identity.
public enum IdentityMasking {
    public static func mask(_ email: String?) -> String? {
        guard let email,
              let at = email.firstIndex(of: "@"),
              at != email.startIndex,
              at != email.index(before: email.endIndex) else {
            return email
        }
        let local = email[email.startIndex..<at]
        let domain = email[email.index(after: at)...]
        // Keep the first character of the first domain label plus everything
        // from the last dot (the TLD, possibly multi-part like .co.uk).
        let firstLabel = domain.prefix { $0 != "." }
        let tld: Substring = domain.lastIndex(of: ".").map { domain[$0...] } ?? ""
        return "\(local.prefix(1))***@\(firstLabel.prefix(1))***\(tld)"
    }
}

extension ProviderSnapshot {

    /// Data liveness derived from the windows + error, never from a heuristic
    /// on the provider name.
    public var dataState: RowDataState {
        if let error = errorMessage, windows.isEmpty {
            return .failed(reason: error)
        }
        guard !windows.isEmpty else { return .neverReceived }
        let observed = capturedAt
        if windows.allSatisfy(\.isStale) {
            return .stale(observedAt: observed)
        }
        return .fresh(observedAt: observed)
    }

    /// The row shows its guided reconnect affordance only for a typed
    /// `reconnectRequired` state — never because an error string looked
    /// reconnect-ish.
    public var needsReconnect: Bool {
        authState == .reconnectRequired
    }
}
