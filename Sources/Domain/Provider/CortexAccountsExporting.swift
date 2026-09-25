import Foundation

/// Seam for exporting the credential-free account roster (Contract A, v7.2) that
/// llm-router reads back. `QuotaMonitor` calls this after each refresh cycle; the
/// concrete writer lives in Infrastructure. Domain never learns the file format.
@MainActor
public protocol CortexAccountsExporting: Sendable {
    /// Projects the enabled providers to `~/.claude/state/llm-router/cortex-accounts.json`.
    /// Must never emit any secret — it consumes the overview projection, which
    /// carries quota windows and identity labels, never a `probeConfig` value.
    func exportAfterRefresh(providers: [any AIProvider])
}
