# ClaudeBar Architecture

This document is the **single source of truth** for ClaudeBar's architecture. All other documentation should reference this file.

## Overview

ClaudeBar follows a **layered architecture** with clear separation of concerns:

- **Domain Layer** - Pure business logic, no external dependencies
- **Infrastructure Layer** - Technical implementations (CLI, network, storage)
- **App Layer** - SwiftUI views that consume domain directly

The key UI principle is **QuotaMonitor as the in-process state owner**. In the
YOYAKU distribution, `llm-router` is the upstream quota/catalog/routing SSOT for
Claude, Codex, Kimi, Qwen, GLM, MiniMax, Bedrock, and Local.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                           APP LAYER                                  │
│                                                                      │
│  ClaudeBarApp                                                       │
│  └── @State var monitor: QuotaMonitor  (injected to views)          │
│                                                                      │
│  Views (consume domain directly - NO AppState/ViewModel)            │
│  ├── MenuContentView(monitor: QuotaMonitor)                         │
│  ├── SettingsView(monitor: QuotaMonitor)                            │
│  └── ProviderPill, QuotaBar, StatusBarIcon, etc.                    │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              │ Views consume directly
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         DOMAIN LAYER                                 │
│                                                                      │
│  QuotaMonitor (@Observable) - Single Source of Truth                │
│  ├── providers: AIProviders (private repository)                    │
│  ├── Delegation: allProviders, enabledProviders, provider(for:)     │
│  ├── Selection: selectedProviderId, selectedProvider                │
│  └── Operations: refreshAll(), addProvider(), removeProvider()      │
│                                                                      │
│  AIProviders (@Observable) - Provider Collection Repository          │
│  ├── all: [AIProvider]                                              │
│  ├── enabled: [AIProvider] (filters by isEnabled)                   │
│  └── add(), remove(), provider(id:)                                 │
│                                                                      │
│  AIProvider (@Observable) - Rich Domain Model                        │
│  ├── isEnabled: Bool (via ProviderSettingsRepository)               │
│  ├── snapshot: UsageSnapshot?                                       │
│  ├── isSyncing: Bool                                                │
│  └── refresh() async throws -> UsageSnapshot                        │
│                                                                      │
│  RouterBackedProvider - first-class YOYAKU quota provider           │
│  ├── one instance per stable ClaudeBar provider ID                  │
│  ├── MultiAccountProvider roster from llm-router aliases            │
│  └── account warnings do not erase healthy account capacity         │
│                                                                      │
│  Repository Protocols (ISP - Interface Segregation Principle)        │
│  ├── ProviderSettingsRepository - base: isEnabled state             │
│  ├── ZaiSettingsRepository: ProviderSettingsRepository              │
│  │   └── Z.ai specific: configPath, glmAuthEnvVar                   │
│  └── CopilotSettingsRepository: ProviderSettingsRepository          │
│      └── Copilot specific: authEnvVar + credentials (token/user)    │
│                                                                      │
│  Domain Models                                                       │
│  ├── UsageSnapshot - point-in-time quota data                       │
│  ├── UsageQuota - single quota with percentage, type, reset time    │
│  ├── QuotaStatus - healthy/warning/critical/depleted                │
│  └── QuotaType - session/weekly/modelSpecific/timeLimit             │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              │ Implements protocols
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     INFRASTRUCTURE LAYER                             │
│                                                                      │
│  YOYAKU quota snapshot adapter                                      │
│  ├── LLMRouterSnapshotClient - `status --format json-v2`            │
│  ├── validates schema version + normalized 0...1 fractions          │
│  ├── coalesces concurrent consumers into one subprocess             │
│  └── returns last-good data with explicit stale metadata            │
│                                                                      │
│  Native probes for providers outside the router catalog            │
│  ├── GeminiUsageProbe - probes Gemini CLI + API                     │
│  ├── CopilotUsageProbe - probes GitHub API with token               │
│  ├── AntigravityUsageProbe - probes local Antigravity server        │
│  ├── AmpCodeUsageProbe - probes Amp Code CLI                        │
│  └── extension/native probes for non-routing providers              │
│                                                                      │
│  Storage (Sources/Infrastructure/Storage/)                          │
│  ├── AIProviders - implements AIProviderRepository                  │
│  ├── JSONSettingsStore - thread-safe JSON file I/O                  │
│  └── JSONSettingsRepository                                         │
│      └── Implements all settings protocols (ISP single impl)        │
│                                                                      │
│  Adapters (Sources/Infrastructure/Adapters/) - excluded from coverage│
│  ├── PTYCommandRunner - runs CLI with PTY                           │
│  ├── ProcessRPCTransport - JSON-RPC over stdin/stdout               │
│  ├── DefaultCLIExecutor - real CLI execution                        │
│  ├── InsecureLocalhostNetworkClient - self-signed cert handling     │
│  └── SystemAlertSender - system notifications                       │
│                                                                      │
│  Network (Sources/Infrastructure/Network/)                          │
│  └── NetworkClient protocol + URLSession extension                  │
│                                                                      │
│  Logging (Sources/Infrastructure/Logging/)                          │
│  ├── AppLog - dual-output logging (OSLog + file)                    │
│  └── FileLogger - persistent logs with rotation                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Key Design Principles

### 1. Rich Domain Models

Domain models encapsulate behavior, not just data. Business logic lives in the domain layer.

```swift
// Rich domain model with computed behavior
public struct UsageQuota: Sendable, Equatable {
    public let percentRemaining: Double

    // Domain behavior - computed from state
    public var status: QuotaStatus {
        QuotaStatus.from(percentRemaining: percentRemaining)
    }

    public var isDepleted: Bool { percentRemaining <= 0 }
    public var needsAttention: Bool { status.needsAttention }
}
```

**Domain-Driven Terminology** - Use domain language, not technical terms:

| Domain Term | Instead Of |
|-------------|------------|
| `UsageQuota` | `UsageData` |
| `QuotaStatus` | `HealthStatus` |
| `AIProvider` | `ServiceProvider` |
| `UsageSnapshot` | `UsageDataResponse` |
| `QuotaMonitor` | `UsageDataFetcher` |

### 2. Single Source of Truth

`QuotaMonitor` owns all live UI state. Views read from it, never modify state
directly. It does not become a second quota authority.

```swift
// QuotaMonitor is the single source of truth
@MainActor
@Observable
public final class QuotaMonitor {
    private let providers: AIProviders  // Hidden - use delegation methods

    // Main-actor delegation consumed directly by SwiftUI
    public var allProviders: [any AIProvider]
    public var enabledProviders: [any AIProvider]
    public func provider(for id: String) -> (any AIProvider)?
}
```

For the YOYAKU routing catalog, the authority boundary is:

```
provider APIs / credential CLIs
        │
        ▼
llm-router normalized snapshot v2 (remaining_pct = 0...1)
        │ one shared, validated read
        ▼
RouterBackedProvider (converts once to UsageQuota = 0...100)
        │
        ▼
QuotaMonitor → SwiftUI
```

Aliases are shared by `llm-router`; emails and local labels remain in
`~/.claudebar/settings.json` and join only through explicit `routerAlias`
metadata. ClaudeBar never mutates the upstream credential roster.

### 3. Repository Pattern with ISP (Interface Segregation Principle)

Settings are abstracted behind **provider-specific sub-protocols** following ISP:

```swift
// Base protocol - shared by all providers
@Mockable
public protocol ProviderSettingsRepository: Sendable {
    func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool
    func setEnabled(_ enabled: Bool, forProvider id: String)
}

// Z.ai-specific protocol - extends base with Z.ai config
public protocol ZaiSettingsRepository: ProviderSettingsRepository {
    func zaiConfigPath() -> String
    func setZaiConfigPath(_ path: String)
    func glmAuthEnvVar() -> String
    func setGlmAuthEnvVar(_ envVar: String)
}

// Copilot-specific protocol - extends base with config + credentials
public protocol CopilotSettingsRepository: ProviderSettingsRepository {
    func copilotAuthEnvVar() -> String
    func setCopilotAuthEnvVar(_ envVar: String)
    // Credentials (merged per SRP - Copilot owns its credentials)
    func saveGithubToken(_ token: String)
    func getGithubToken() -> String?
    func hasGithubToken() -> Bool
    func saveGithubUsername(_ username: String)
    func getGithubUsername() -> String?
}

// Single infrastructure implementation for all protocols
public final class JSONSettingsRepository:
    AppSettingsRepository,
    ZaiSettingsRepository,
    CopilotSettingsRepository,
    // ... all other sub-protocols
{
    // Persists to ~/.claudebar/settings.json via JSONSettingsStore
    // Credentials (tokens, API keys) use UserDefaults (Keychain migration planned)
}
```

**Why ISP?**
- Each provider depends **only** on its specific interface
- Simple providers (Claude, Codex, Gemini) use base `ProviderSettingsRepository`
- Z.ai uses `ZaiSettingsRepository` (config path + env var)
- Copilot uses `CopilotSettingsRepository` (env var + credentials)
- No provider sees methods it doesn't need

### 4. Protocol-Based Dependency Injection

All external dependencies are injected via protocols with `@Mockable` for testing.

```swift
@Mockable
public protocol UsageProbe: Sendable {
    func probe() async throws -> UsageSnapshot
    func isAvailable() async -> Bool
}

// Simple providers receive base settingsRepository
public init(probe: any UsageProbe, settingsRepository: any ProviderSettingsRepository) {
    self.probe = probe
    self.settingsRepository = settingsRepository
}

// Specialized providers receive their specific repository
public init(probe: any UsageProbe, settingsRepository: any ZaiSettingsRepository) { ... }
public init(probe: any UsageProbe, settingsRepository: any CopilotSettingsRepository) { ... }
```

### 5. No ViewModel/AppState Layer

SwiftUI views consume `QuotaMonitor` directly. No intermediate layers.

```swift
// Views consume domain directly
struct MenuContentView: View {
    let monitor: QuotaMonitor  // Injected from app

    var body: some View {
        ForEach(monitor.enabledProviders, id: \.id) { provider in
            ProviderPill(provider: provider)
        }
    }
}
```

### 6. Chicago School TDD

Tests focus on **state changes and return values**, not method call verification.

```swift
// Good: Test state/outcome
@Test func `provider stores snapshot after refresh`() async throws {
    let provider = makeProvider(probe: mockProbe)
    #expect(provider.snapshot == nil)

    _ = try await provider.refresh()

    #expect(provider.snapshot != nil)  // Verify state change
}

// Avoid: Verifying method calls (London school)
// verify(mock).someMethod().called(1)  // Don't do this
```

### 7. Adapters Folder

Pure 3rd-party wrappers in `Adapters/` are excluded from code coverage since they only wrap system APIs.

## Data Flow

### Refresh Flow

```
User clicks Refresh
        │
        ▼
QuotaMonitor.refreshAll()
        │
        ▼
For each enabled provider
        │
        ├─ RouterBackedProvider ─→ refreshAllAccounts(kind)
        │                              │
        │                              ▼
        │                         shared snapshot client
        │
        └─ other provider ──────→ native provider.refresh(kind)
        │
        ▼
Router path: one coalesced `llm-router status --format json-v2`
        │
        ▼
    validate + map provider/accounts → UsageSnapshot(s)
        │
        ▼
SwiftUI observes change → UI updates
```

### Provider Enable/Disable Flow

```
User toggles provider in Settings
        │
        ▼
provider.isEnabled = false
        │
        ▼
didSet → settingsRepository.setEnabled(false, forProvider: id)
        │
        ▼
JSON settings file persists the change
        │
        ▼
AIProviders.enabled recomputes (filters by isEnabled)
        │
        ▼
SwiftUI observes change → provider hidden from menu
```

## File Organization

```
Sources/
├── Domain/                          # Pure business logic
│   ├── Provider/
│   │   ├── AIProvider.swift         # Protocol
│   │   ├── AIProviders.swift        # Repository protocol
│   │   ├── LLMRouter/               # Snapshot contract + router providers
│   │   ├── ClaudeProvider.swift     # Rich domain model
│   │   ├── CopilotProvider.swift    # Uses CopilotSettingsRepository
│   │   ├── ZaiProvider.swift        # Uses ZaiSettingsRepository
│   │   ├── ProviderSettingsRepository.swift  # ISP protocols hierarchy
│   │   ├── UsageProbe.swift
│   │   ├── UsageQuota.swift
│   │   ├── UsageSnapshot.swift
│   │   └── QuotaStatus.swift
│   └── Monitor/
│       ├── QuotaMonitor.swift       # Single source of truth
│       └── QuotaAlerter.swift       # Domain protocol for alerts
│
├── Infrastructure/                  # Technical implementations
│   ├── CLI/                         # Probe implementations
│   ├── LLMRouter/                   # Versioned snapshot client
│   ├── Storage/                     # Repository implementations
│   ├── Adapters/                    # 3rd-party wrappers (no coverage)
│   ├── Network/                     # HTTP abstraction
│   ├── Logging/                     # Dual-output logging
│   └── Notifications/               # NotificationAlerter (implements QuotaAlerter)
│
└── App/                             # SwiftUI application
    ├── ClaudeBarApp.swift           # Entry point, wires dependencies
    ├── Views/                       # SwiftUI views
    ├── Settings/                    # AppSettings (theme, etc.)
    └── Resources/                   # Assets, Info.plist
```

## Business Rules

### Quota Status Thresholds

| Remaining | Status | Needs Attention |
|-----------|--------|-----------------|
| > 50% | `.healthy` | No |
| 20-50% | `.warning` | Yes |
| < 20% | `.critical` | Yes |
| 0% | `.depleted` | Yes |

### Snapshot Freshness

- **Fresh**: < 5 minutes old
- **Stale**: >= 5 minutes old (triggers refresh)

## Adding New Features

For implementation guidance, see:
- [implement-feature skill](../.claude/skills/implement-feature/SKILL.md) - TDD workflow
- [add-provider skill](../.claude/skills/add-provider/SKILL.md) - Adding AI providers

## Testing Strategy

- **Domain Tests** - Test state changes and computed properties
- **Infrastructure Tests** - Test parsing logic and probe behavior with mocks
- **No Integration Tests** - Adapters folder excluded from coverage
- **Chicago School** - Mocks stub data, don't verify calls
