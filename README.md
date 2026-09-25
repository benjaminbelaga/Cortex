# Cortex

> **Project identity.** Cortex is Benjamin Belaga's open-source macOS quota monitor,
> built on an upstream open-source codebase (MIT — see [`NOTICE.md`](NOTICE.md) for
> attribution and the reconciliation reference). The application bundle ships as
> **Cortex.app** on disk and the menu-bar item shows the **Cortex** label, while the
> underlying codebase keeps the upstream internal target name (`Cortex`) and class
> names for mergeability with `upstream/main`. The bundle ID is `fr.yoyaku.cortex`
> (migrated from upstream's in E4, with non-destructive Keychain/UserDefaults
> migration). The source never ships provider credentials; local accounts remain in
> macOS Keychain.
>
> **Coming from the upstream app.** E4 renamed the bundle id from
> `com.tddworks.claudebar` to `fr.yoyaku.cortex`. On first launch Cortex copies
> the Keychain items and UserDefaults keys it needs into the new namespace and
> leaves the old ones untouched (an explicit new value always wins). macOS
> treats the renamed bundle as a different app, so permission prompts
> (Accessibility, Automation, Notifications, Login Items) come back once, and
> Sparkle cannot auto-update across bundle ids — the first Cortex build after
> the rename needs a manual install.

[![Build](https://github.com/benjaminbelaga/Cortex/actions/workflows/build.yml/badge.svg)](https://github.com/benjaminbelaga/Cortex/actions/workflows/build.yml)
[![Tests](https://github.com/benjaminbelaga/Cortex/actions/workflows/tests.yml/badge.svg)](https://github.com/benjaminbelaga/Cortex/actions/workflows/tests.yml)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2015-blue.svg)](https://developer.apple.com)

A macOS menu bar application that monitors AI coding assistant usage quotas in real time. Keep track of your Claude, OpenAI Codex, Google Gemini, GitHub Copilot, Google Antigravity, Cursor, AWS Bedrock, AWS Kiro, Kimi, DeepSeek, Mistral, MiniMax, Alibaba Coding Plan, Z.ai, Amp Code, OpenCode Go, Oh My Pi, Grok Build, Command Code, and Vercel at a glance.

Featuring full **MacBook Touch Bar integration** with persistent, centered multi-provider quota gauges, **MacBook Notch Live Activity**, **Multi-Account Switching**, and Raycast-style **User Extensions**.

> **Screenshots** — the application UI and icon are Cortex-branded. Release
> screenshots are generated from the same build and contain no local account data.

### Multi-Account Switching & Multi-Window Quotas

Cortex supports seamless **Multi-Account Switching** for providers that support multiple logins (e.g. personal, work, client accounts). Configure multiple accounts in **Settings > Providers**, and switch between them from the account catalogue or provider row menu.

Each provider displays separate progress bars for multiple quota windows—for example, tracking your **5-hour session quota** and **7-day weekly quota** simultaneously with dedicated countdown timers.

---

## Quota Thresholds & Color Coding

Every quota is tracked in real time and color-coded based on remaining capacity:

| Remaining | Status | Color | Description |
|-----------|--------|-------|-------------|
| > 50% | Healthy | Blue / Green | Ample quota available |
| 20-50% | Warning | Yellow / Amber | Approaching usage threshold or accelerated burn rate |
| < 20% | Critical | Red | Low quota remaining; alerts triggered |
| 0% | Depleted | Gray | Quota exhausted |

## Features

- **Multi-Provider Support** - Monitor Claude, Codex, Gemini, GitHub Copilot, Antigravity, Z.ai, Kimi, Kiro, Amp, OpenCode Go, Oh My Pi, Grok, and Command Code quotas in one place
- **Provider Enable/Disable** - Toggle individual providers on/off from Settings to customize your monitoring
- **Real-Time Quota Tracking** - View Session, Weekly, and Model-specific usage percentages
- **Multiple Themes** - Light, Dark, CLI, Christmas, and [imported terminal themes](#import-terminal-theme) (.itermcolors)
- **Automatic Adaptation** - System theme follows your macOS appearance; Christmas auto-enables during the holiday season
- **Visual Status Indicators** - Color-coded progress bars (green/yellow/red) show quota health
- **System Notifications** - Get alerted when quota status changes to warning or critical
- **Touch Bar Integration** - Persistent MacBook Touch Bar widget with real-time multi-provider gauges, progress bars, and an interactive pixel mascot ([learn more](#touch-bar-integration))
- **Notify! iPhone Publishing** - Push quota state to your iPhone via [Notify!](https://getnotifyapp.com) on three surfaces: a Lock Screen Live Activity showing up to six quota windows, a Home Screen widget carrying that same content but staying put, and a Lock Screen widget gauge for one chosen quota (off by default, see below)
- **Auto-Refresh** - Automatically updates quotas at configurable intervals
- **Keyboard Shortcuts** - Quick access with `⌘D` (Dashboard) and `⌘R` (Refresh)

> [!TIP]
> You can also enable **Burn Rate Warnings** in **Settings > General** to trigger alerts based on your real-time consumption velocity against remaining time rather than fixed percentage cutoffs.

## Touch Bar Integration

Cortex features native, system-wide Touch Bar integration for MacBook Pro models equipped with an Apple Touch Bar (including M1/M2 and Intel). This runs 100% natively inside Cortex—requiring **zero third-party apps** (no BetterTouchTool or MTMR required) and **no special accessibility permissions**.

### Key Touch Bar Features

- **Always Visible System-Wide (`placement: 0`)**: Uses macOS system-modal function bar presentation. The widget remains persistently visible across all full-screen windows and apps, automatically re-asserting on app switching and system unlock while keeping your system Escape key and Control Strip media/volume controls intact.
- **Centered, Clean Multi-Provider Quota Gauges**:
  - Balanced, centered layout across the Touch Bar for single or multi-provider views.
  - Displays authentic provider logos (Claude, Gemini, Antigravity, GitHub Copilot, Codex, etc.).
  - Multi-segment provider views matching your menu bar configuration (e.g. `[Logo] Gemini 40% | [Logo] Claude 0%`).
  - High-precision bold monospaced percentage readout with warning indicator (`!`) when quota is critical (≥ 90%).
  - Sleek rounded progress bars with 100% track reference and adaptive color coding (healthy blue, warning amber, critical red).
  - Reset countdown timer (e.g., `2:15`, `35m`, `3d`).
- **Battery-Friendly & Ultra Lightweight**: Redraws only when quota state updates; consumes 0% idle CPU and zero background animation overhead.
- **One-Tap Access**: Tap anywhere on the quota gauges on the Touch Bar to instantly summon the full Cortex dropdown popover (`cortex://open`).

> [!TIP]
> For detailed architecture, Touch Bar configuration, and customization details, see the [Full Touch Bar Guide](docs/touchbar/TOUCHBAR_GUIDE.md).


## MacBook Notch Live Activity

Cortex can render Claude Code's session and quota state directly in your MacBook notch (Settings > General > Notch Live Activity):

- **Idle Mode**: Displays your selected provider's most depleted quota at a glance.
- **Active Session Mode**: Displays repository name, elapsed time, and the number of active subagents fanned out.
- **Permission Alert**: Prominently highlights when Claude Code is waiting for permission in terminal.
- **Hover Popover**: Hovering expands the notch into a full status view with active session list, quota cards, and quick action buttons.
- **Virtual Notch**: Displays without a physical notch (or external monitors) automatically receive an elegant virtual notch sized to the menu bar.

> [!NOTE]
> Read the complete documentation at [docs/features/notch-live-activity.md](docs/features/notch-live-activity.md).

## Requirements

- macOS 15+
- Swift 6.2+
- Providers and CLI tools you wish to monitor:
  - [Claude](https://claude.ai/code) - CLI mode (`claude`) or direct OAuth API mode
  - [Codex](https://github.com/openai/codex) - CLI RPC mode (`codex`) or ChatGPT backend API mode
  - [Gemini](https://github.com/google-gemini/gemini-cli) - `gemini` CLI
  - [GitHub Copilot](https://github.com/features/copilot) - Billing API or Internal Copilot API mode
  - [Antigravity](https://antigravity.google) - Auto-detected when running locally
  - [Cursor](https://cursor.com) - Auto-detected via local SQLite DB and usage API
  - [AWS Bedrock](https://aws.amazon.com/bedrock/) - AWS SSO profile or IAM credentials
  - [AWS Kiro](https://kiro.dev) - `kiro-cli` via `uv tool install kiro-cli`
  - [Kimi](https://www.kimi.com/code/console) - `kimi` CLI mode (recommended) or API cookie mode
  - [DeepSeek](https://www.deepseek.com) - API key configured in Settings
  - [Mistral](https://mistral.ai) - Backed by Vibe session logs
  - [MiniMax](https://www.minimax.io) - Coding Plan API key (International / China)
  - [Alibaba Coding Plan](https://bailian.console.aliyun.com) - Model Studio API key or browser cookie
  - [Z.ai](https://z.ai/subscribe) - Configure Claude Code with GLM Coding Plan endpoint
  - [Amp Code](https://ampcode.com) - Auto-detected when `amp` CLI is installed
  - [OpenCode Go](https://opencode.ai/go) - Local SQLite DB or Zen API key
  - [Oh My Pi](https://omp.sh) - Aggregates account usage via `omp usage --json`
  - [Grok Build](https://docs.x.ai) - Tracks xAI credits using CLI OAuth credentials
  - [Command Code](https://commandcode.ai) - Tracks 5-hour, weekly, and monthly credit windows from the same API the `cmd` CLI uses
  - [Vercel](https://vercel.com) - Token-based quota tracking
  - [Custom Extensions](docs/features/extensions.md) - Drop custom scripts into `~/.claudebar/extensions/`

### Provider Setup Guides

<details>
<summary><strong>Kimi Setup</strong></summary>

Kimi supports two probe modes, configurable in **Settings > Kimi Configuration**:
- **CLI Mode (Recommended)**: Launches interactive `kimi` and executes `/usage`. Requires `uv tool install kimi-cli` or `pip install kimi-cli`. No Full Disk Access required.
- **API Mode**: Calls Kimi Connect-RPC directly using browser cookie auth. Requires **Full Disk Access** for Cortex in **System Settings > Privacy & Security > Full Disk Access** (or set `KIMI_AUTH_TOKEN`).
</details>

<details>
<summary><strong>AWS Kiro Setup</strong></summary>

Kiro monitors AWS Kiro (formerly CodeWhisperer) usage via `kiro-cli`.
- **Install**: `uv tool install kiro-cli` or `pip install kiro-cli`
- **Authenticate**: Run `kiro-cli` and complete the login prompt (or use Kiro IDE).
</details>

<details>
<summary><strong>AWS Bedrock Setup</strong></summary>

Monitors daily spend, token counts, and per-model breakdowns via CloudWatch.
- Configure AWS SSO profile or environment variables in **Settings > Bedrock**.
- Select target inference regions (e.g. `us-east-1`, `us-west-2`).
</details>

<details>
<summary><strong>Alibaba Coding Plan Setup</strong></summary>

Monitors 5-hour session, weekly, and monthly quotas on Alibaba Model Studio / Bailian.
- Choose region: International (`modelstudio.console.alibabacloud.com`) or China Mainland (`bailian.console.aliyun.com`).
- Authenticate via API key or browser cookie extraction.
</details>

<details>
<summary><strong>Cursor Setup</strong></summary>

Automatically detects your active Cursor IDE installation and reads authentication tokens from Cursor's local SQLite database. Displays included requests and on-demand spend.
</details>

## URL Schemes

Cortex supports the `cortex://` URL scheme for quick actions from Raycast, Alfred, Touch Bar widgets, or terminal. The legacy `claudebar://` scheme remains registered for migrated installations:

| URL Scheme | Action | CLI Example |
|---|---|---|
| `cortex://open` | Toggles the Cortex dropdown popover | `open cortex://open` |
| `cortex://refresh` | Triggers immediate quota refresh for all providers | `open cortex://refresh` |
| `cortex://settings` | Opens the Cortex Settings window | `open cortex://settings` |

### Notify! Setup

Publishing quota state to your iPhone is optional and off by default. It is configured in **Settings > Notify!**.

1. Get [Notify!](https://getnotifyapp.com). It runs on Mac, on iOS, and on any device through web push.
2. **For the Live Activity, open Notify! once on the iPhone or iPad you are publishing to.** One cannot be started until that device has registered a push-to-start credential, and only opening the app produces one. Skip this step if you only want the widgets, which are polled rather than pushed, and skip it for a Mac or browser ID, which cannot show a Live Activity at all.
3. In Notify!, copy your device ID and device token.
4. Put them in the **Device ID** and **Token** fields in Cortex's Notify! settings pane and press **Save Link**. Pasting a whole notification URL into the Device ID field works too, Cortex splits it across both. **Verify Device** confirms the pair against Notify! and names the phone it belongs to. Then turn **Publish to Notify!** on.

The Live Activity needs an iPhone or iPad ID. Notify! also issues IDs for Macs and browsers, and those keep both widgets perfectly well, but Notify! cannot start a Live Activity on one, so Cortex disables just that switch and says why. A group ID receives notifications but owns no Lock Screen or Home Screen of its own, so it gets none of the three.

All three surfaces can be turned off separately, and you can choose which quota the gauge shows. The Home Screen widget shows the same thing as the Live Activity, and the difference is that it stays: a Live Activity appears while something is happening and then goes away, while the Home Screen widget sits where you put it and always shows the latest state. It needs a recent Notify! app, where you turn it on under **Settings > Home Screen Widgets**, and you place it yourself through iOS's own widget picker. Notify! can also switch the surface off at its own end while it is still rolling out; Cortex treats that as "not yet", pauses just that widget, and carries on publishing the other two.

Note that this sends provider names, quota window labels and remaining percentages to a third-party service. The device token is stored in the Keychain, not in `~/.claudebar/settings.json`. A build you compile yourself is ad-hoc signed and the Keychain refuses it, so on those the token falls back to Cortex's app credentials and the pane says so.

Full details: [docs/features/notify.md](docs/features/notify.md).

## Installation

### Build from Source (recommended until the first signed release)

```bash
git clone https://github.com/benjaminbelaga/Cortex.git
cd cortex

# Install Tuist (if not installed)
brew install tuist

# Install dependencies and build
tuist install
tuist build Cortex -C Release
```

> [!NOTE]
> No Homebrew cask and no signed release exist yet — see
> [docs/release/RELEASE_SETUP.md](docs/release/RELEASE_SETUP.md) for the
> release checklist. A self-compiled build is ad-hoc signed.

## Usage

After building, open the generated Xcode workspace and run the app:

```bash
tuist generate
open Cortex.xcworkspace
```

Then press `Cmd+R` in Xcode to run. The app will appear in your menu bar. Click to view quota details for each provider.

### Built for a YOYAKU machine — and usable without one

Cortex is developed on a machine with `llm-router` serving shared quota
snapshots. Two behaviors reflect that origin and stay inert elsewhere:

- **Curated defaults**: niche native providers and pay-as-you-go connectors
  are hidden until explicitly enabled from the `+` catalogue. Nothing is
  ever deleted — re-enabling is one click.
- **Legacy alias binding** (`default`/`webmaster`/`tech` → router aliases):
  runs only when the precise pre-migration signature is detected
  (`integration.legacyAliasBinding`, default off for fresh installs).

A fresh install without llm-router gets native Claude/Codex rows via the
autonomous probes (see `RouterSourceModeMigration` for the exact
fresh-install defaults).

## Development

The project uses [Tuist](https://tuist.io) for dependency management and Xcode project generation.

### Quick Start

```bash
# Install Tuist (if not installed)
brew install tuist

# Install dependencies
tuist install

# Generate Xcode project and open
tuist generate
open Cortex.xcworkspace
```

### Build & Test

```bash
# Build the project
tuist build

# Run all tests
tuist test

# Run tests with coverage
tuist test --result-bundle-path TestResults.xcresult -- -enableCodeCoverage YES

# Build release configuration
tuist build Cortex -C Release
```

### SwiftUI Previews

After opening in Xcode, SwiftUI previews will work with `Cmd+Option+Return`. The project is configured with `ENABLE_DEBUG_DYLIB` for preview support.

## Architecture

> **Full documentation:** [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md)

Cortex uses a **layered architecture** with `QuotaMonitor` as the single source of truth:

| Layer | Purpose |
|-------|---------|
| **App** | SwiftUI views consuming domain directly (no ViewModel) |
| **Domain** | Rich models, `QuotaMonitor`, repository protocols |
| **Infrastructure** | Probes, storage implementations, adapters, drivers |

### Key Design Decisions

- **Single Source of Truth** - `QuotaMonitor` owns all provider state
- **Repository Pattern** - Settings and credentials abstracted behind injectable protocols (`JSONSettingsRepository`)
- **Protocol-Based DI** - `@Mockable` protocols enable testability
- **Chicago School TDD** - Tests verify state changes, not method calls
- **No ViewModel/AppState** - Views consume domain directly

## Import Terminal Theme

Match Cortex's appearance to your terminal. Import any `.itermcolors` file:

1. Open **Settings** (gear icon)
2. Click **Import .itermcolors**
3. Select your file (export from iTerm2: Preferences > Profiles > Colors > Color Presets > Export)

450+ pre-made schemes available at [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes/tree/master/schemes).

Imported themes are saved in `~/.claudebar/themes/` and persist across restarts.

## User Extensions

Create your own provider monitoring modules by dropping a manifest and script into `~/.claudebar/extensions/`. Extensions can define quota grids, daily usage cards, and automated HTTP health checks.

See [docs/features/extensions.md](docs/features/extensions.md) for full specification and example implementations.

## Contributing

### Adding a New AI Provider

Use the **add-provider** skill to guide you through adding new providers with TDD:

```
Tell Claude Code: "I want to add a new provider for [ProviderName]"
```

The skill guides you through: Parsing Tests → Probe Tests → Implementation → Registration.

See `.claude/skills/add-provider/SKILL.md` for details and `AntigravityUsageProbe` as a reference implementation.

## Dependencies

- [Sparkle](https://sparkle-project.org/) - Auto-update framework
- [Mockable](https://github.com/Kolos65/Mockable) - Protocol mocking for tests
- [Tuist](https://tuist.io) - Xcode project generation (for SwiftUI previews)

## Releasing

Releases are automated on the zero-cost YOYAKU macOS runner and are bound to an
exact `main` commit through `gha-safe`.

**For detailed setup instructions, see [docs/release/RELEASE_SETUP.md](docs/release/RELEASE_SETUP.md).**

### Release Workflow

The workflow uses Tuist to generate the Xcode project:

```
gha-safe + exact SHA → tuist generate → xcodebuild → Sign & Notarize → Provenance → GitHub Release
```

Version is set in `Sources/App/Info.plist` and flows through to Sparkle auto-updates.

### Quick Start

1. **Configure the release authority** (see [full guide](docs/release/RELEASE_SETUP.md)):

   - GitHub secret `SPARKLE_EDDSA_PRIVATE_KEY`
   - Developer ID identity in the trusted runner's login Keychain
   - notarytool Keychain profile `YOYAKU-NOTARY`

2. **Verify your certificate**:
   ```bash
   ./scripts/verify-p12.sh /path/to/certificate.p12
   ```

3. **Create a release from the exact checked-in version on `main`**:
   ```bash
   RELEASE_SHA="$(git rev-parse main)"
   gha-safe dispatch --repo yoyaku-group/Cortex --workflow release.yml \
     --ref main --expected-sha "$RELEASE_SHA" --apply
   ```

The workflow will automatically build, sign, notarize, and publish to GitHub Releases.

## Contributors

Thanks goes to these wonderful people ([emoji key](https://allcontributors.org/docs/en/emoji-key)):

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="16.66%"><a href="https://tddworks.com/"><img src="https://avatars.githubusercontent.com/u/1201118?v=4?s=80" width="80px;" alt="itshan"/><br /><sub><b>itshan</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=hanrw" title="Code">💻</a> <a href="https://github.com/tddworks/claudebar/commits?author=hanrw" title="Documentation">📖</a> <a href="#maintenance-hanrw" title="Maintenance">🚧</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/avishj"><img src="https://avatars.githubusercontent.com/u/58023328?v=4?s=80" width="80px;" alt="Avish Jha"/><br /><sub><b>Avish Jha</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=avishj" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/ramarivera"><img src="https://avatars.githubusercontent.com/u/7547875?v=4?s=80" width="80px;" alt="Ramiro"/><br /><sub><b>Ramiro</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=ramarivera" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/LunarECL"><img src="https://avatars.githubusercontent.com/u/38317983?v=4?s=80" width="80px;" alt="LunarECL"/><br /><sub><b>LunarECL</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=LunarECL" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/zenibako"><img src="https://avatars.githubusercontent.com/u/18584424?v=4?s=80" width="80px;" alt="Chandler Anderson"/><br /><sub><b>Chandler Anderson</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=zenibako" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://frmr.me"><img src="https://avatars.githubusercontent.com/u/620189?v=4?s=80" width="80px;" alt="Matt Farmer"/><br /><sub><b>Matt Farmer</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=farmdawgnation" title="Code">💻</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="16.66%"><a href="https://willner.ws"><img src="https://avatars.githubusercontent.com/u/307605?v=4?s=80" width="80px;" alt="Alex"/><br /><sub><b>Alex</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=AlexanderWillner" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/sailesh"><img src="https://avatars.githubusercontent.com/u/493129?v=4?s=80" width="80px;" alt="sailesh"/><br /><sub><b>sailesh</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=sailesh" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/billyjack2"><img src="https://avatars.githubusercontent.com/u/28798344?v=4?s=80" width="80px;" alt="Billy Smith"/><br /><sub><b>Billy Smith</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=billyjack2" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/nero-sensei"><img src="https://avatars.githubusercontent.com/u/77715088?v=4?s=80" width="80px;" alt="nero"/><br /><sub><b>nero</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=nero-sensei" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/BryanQQYue"><img src="https://avatars.githubusercontent.com/u/169884865?v=4?s=80" width="80px;" alt="BryanYue"/><br /><sub><b>BryanYue</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=BryanQQYue" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://blog.d0zingcat.dev/"><img src="https://avatars.githubusercontent.com/u/8235790?v=4?s=80" width="80px;" alt="Tony Tang"/><br /><sub><b>Tony Tang</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=d0zingcat" title="Code">💻</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="16.66%"><a href="https://initialize.nl/"><img src="https://avatars.githubusercontent.com/u/7355878?v=4?s=80" width="80px;" alt="Frank Hommers"/><br /><sub><b>Frank Hommers</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=frankhommers" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://www.marcusquinn.com"><img src="https://avatars.githubusercontent.com/u/6428977?v=4?s=80" width="80px;" alt="Marcus Quinn"/><br /><sub><b>Marcus Quinn</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=marcusquinn" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/hagiwaratakayuki"><img src="https://avatars.githubusercontent.com/u/141513?v=4?s=80" width="80px;" alt="hagiwara takayuki"/><br /><sub><b>hagiwara takayuki</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=hagiwaratakayuki" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/jeffscottmtl"><img src="https://avatars.githubusercontent.com/u/33327731?v=4?s=80" width="80px;" alt="jeffscottmtl"/><br /><sub><b>jeffscottmtl</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=jeffscottmtl" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/tomstetson"><img src="https://avatars.githubusercontent.com/u/11658911?v=4?s=80" width="80px;" alt="Tom"/><br /><sub><b>Tom</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=tomstetson" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/jeffWelling"><img src="https://avatars.githubusercontent.com/u/105077?v=4?s=80" width="80px;" alt="Jeff Welling"/><br /><sub><b>Jeff Welling</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=jeffWelling" title="Code">💻</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/Zada5"><img src="https://avatars.githubusercontent.com/u/91982194?v=4?s=80" width="80px;" alt="Zada5"/><br /><sub><b>Zada5</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=Zada5" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/fredericoricco-debug"><img src="https://avatars.githubusercontent.com/u/75469834?v=4?s=80" width="80px;" alt="fredericoricco-debug"/><br /><sub><b>fredericoricco-debug</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=fredericoricco-debug" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://lystic.dev"><img src="https://avatars.githubusercontent.com/u/15372623?v=4?s=80" width="80px;" alt="Kegan Hollern"/><br /><sub><b>Kegan Hollern</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=KeganHollern" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/jsg333"><img src="https://avatars.githubusercontent.com/u/954990?v=4?s=80" width="80px;" alt="Jeff Green"/><br /><sub><b>Jeff Green</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=jsg333" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/benjaminbelaga"><img src="https://avatars.githubusercontent.com/u/33546317?v=4?s=80" width="80px;" alt="Benjamin Belaga"/><br /><sub><b>Benjamin Belaga</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=benjaminbelaga" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/romanvalent"><img src="https://avatars.githubusercontent.com/u/14106124?v=4?s=80" width="80px;" alt="romanvalent"/><br /><sub><b>romanvalent</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=romanvalent" title="Code">💻</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="16.66%"><a href="http://aakshintala.com"><img src="https://avatars.githubusercontent.com/u/748697?v=4?s=80" width="80px;" alt="Amogh Akshintala"/><br /><sub><b>Amogh Akshintala</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=aakshintala" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://www.portfolio.isnakolah.me"><img src="https://avatars.githubusercontent.com/u/47239024?v=4?s=80" width="80px;" alt="Daniel Nakolah"/><br /><sub><b>Daniel Nakolah</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=isnakolah" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/Mitsi-ag"><img src="https://avatars.githubusercontent.com/u/141203898?v=4?s=80" width="80px;" alt="Mitsi-ag"/><br /><sub><b>Mitsi-ag</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=Mitsi-ag" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://www.josecancinolinares.com/en/portfolio"><img src="https://avatars.githubusercontent.com/u/65030646?v=4?s=80" width="80px;" alt="José Cancino Linares"/><br /><sub><b>José Cancino Linares</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=josecancino" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="https://github.com/logancox"><img src="https://avatars.githubusercontent.com/u/28828028?v=4?s=80" width="80px;" alt="logancox"/><br /><sub><b>logancox</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=logancox" title="Code">💻</a></td>
      <td align="center" valign="top" width="16.66%"><a href="http://ywmei.ca/index.php"><img src="https://avatars.githubusercontent.com/u/5897309?v=4?s=80" width="80px;" alt="y5mei"/><br /><sub><b>y5mei</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=y5mei" title="Code">💻</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="16.66%"><a href="https://hansonkim.github.io"><img src="https://avatars.githubusercontent.com/u/1308073?v=4?s=80" width="80px;" alt="Hanson Kim"/><br /><sub><b>Hanson Kim</b></sub></a><br /><a href="https://github.com/tddworks/claudebar/commits?author=hansonkim" title="Code">💻</a></td>
    </tr>
  </tbody>
  <tfoot>
    <tr>
      <td align="center" size="13px" colspan="6">
        <img src="https://raw.githubusercontent.com/all-contributors/all-contributors-cli/1b8533af435da9854653492b1327a23a4dbd0a10/assets/logo-small.svg">
          <a href="https://all-contributors.js.org/docs/en/bot/usage">Add your contributions</a>
        </img>
      </td>
    </tr>
  </tfoot>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

This project follows the [all-contributors](https://github.com/all-contributors/all-contributors) specification. Contributions of any kind welcome!

To credit someone, comment on any issue or pull request:

```
@all-contributors please add @username for code, doc
```

## Multiple Providers in the Menu Bar

In **Settings → Menu Bar**, enable percentage or duration display and select up
to three providers. Each selected provider has its own card for choosing a quota,
an optional secondary quota, and stacked text size. Their existing logos identify
the readouts, while tooltips retain provider names. All displayed providers refresh
in the background. Choices are preserved when a provider is removed and added again,
and existing single-provider settings are retained. Providers awaiting data show `—`.

## License

MIT
