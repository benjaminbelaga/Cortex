import Foundation
import Domain

/// Probe seam for Codex account identity via `codex app-server`. Tests inject
/// a stub that returns canned `CodexAuthStatus`; production wraps
/// `ProcessRPCTransport` with `CODEX_HOME` env injected.
///
/// The wire schema for `account/read` lives outside Cortex (Codex's own app-
/// server protocol). The probe is a thin adapter; if Codex adds/changes
/// fields, only the probe and `CodexAuthStatus` change. Callers consume the
/// typed `CodexAuthStatus` returned here.
public protocol CodexAuthStatusProbing: Sendable {
    func authStatus(codexHome: String) async -> CodexAuthStatus?
}

// The production probe lives in `CodexAuthStatusRPCProbe.swift` (C4-5):
// app-server JSON-RPC `account/read` over `ProcessRPCTransport` with
// CODEX_HOME injected per transport. The earlier `CodexAuthStatusShellProbe`
// placeholder was deleted — one probe, not two (plan C4-5 decision).

/// Terminal-launcher seam for the Codex interactive login flow. Same shape as
/// the Claude variant; the production App-layer implementation lives in
/// `Sources/App/Accounts/AppleScriptTerminalLoginLauncher.swift` (shared
/// between Claude and Codex — the shell command differs, the launch plumbing
/// is identical).
public protocol CodexTerminalLoginLaunching: Sendable {
    func launchLoginShell(codexHome: String) async -> Bool
    func launchReconnectShell(codexHome: String) async -> Bool
}
