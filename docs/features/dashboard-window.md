# Dashboard window

Cortex runs as a menu-bar app (`LSUIElement`). The compact `MenuBarExtra` popover
answers "what do I have left right now" in a few lines; the **Dashboard window**
is the larger, always-on-screen surface for the same data. This document covers
how that window is opened and why it is a dedicated root rather than the popover
view reused.

---

## Opening it

The popover footer carries **Open dashboard** (window glyph, `⌘D`, tooltip). One
click, in order:

1. closes the compact menu (`isMenuPresented = false`) so the two surfaces never
   sit on top of each other;
2. opens — or brings forward — the single `Window(id: "dashboard")`;
3. activates the app (`NSApp.activate`), because an `LSUIElement` app does not
   come forward on its own.

The `Window` scene holds one instance per id, so ten clicks never create ten
windows. Closing the Dashboard leaves Cortex running in the menu bar; native
macOS full-screen stays a separate system command.

The action is injected by the app composition (`CortexApp.openDashboardWindow`)
through `MenuContentView.onOpenDashboard`, so the menu does not have to own the
window lifecycle or the popover binding.

## Why a dedicated root

The popover's overview was previously embedded here verbatim. Inside the
popover, scrolling and the background are provided by the surrounding
`MenuContentView`; a standalone window has neither, so the reused view:

- grew the window with its content (the account list's intrinsic height became
  the window's minimum), pushing it off-screen;
- painted on the unthemed system background — a bare white surface in dark mode.

`DashboardWindowView` supplies the missing shell around the SAME data:

| Concern | Provided by |
|---|---|
| Theme background | `theme.backgroundGradient` |
| Vertical scrolling | `ScrollView` around `OverviewDashboardView` |
| Bounded size | `DashboardWindowLayout` (720×520 min, 1040×760 ideal) |
| Title bar | a small themed header strip |

The bounds are constants, never derived from how many accounts exist.

## The account form appears on one surface only

`AccountCatalogModel.isPresented` is a single shared flag. With both the compact
menu and the Dashboard window live, both instances of `OverviewDashboardView`
read it and rendered the same `+` catalogue twice. `OverviewDashboardView` now
takes `rendersAccountCatalog`; the Dashboard window passes `false` so the menu
stays the account surface until the Dashboard grows its own Resources section.
When it is `false`, the `+` and paste controls are hidden too — a button that
mutated a flag no surface renders would be a dead control.

## Where it lives

| File | Role |
|---|---|
| `Sources/App/Views/Overview/DashboardWindowView.swift` | the window root + `DashboardWindowLayout` |
| `Sources/App/CortexApp.swift` | `Window(id: "dashboard")` scene + `openDashboardWindow()` |
| `Sources/App/Views/MenuContentView.swift` | **Open dashboard** button and `onOpenDashboard` injection |
| `Sources/App/Views/Overview/OverviewDashboardView.swift` | `rendersAccountCatalog` gate |
