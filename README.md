<!-- Modified 2026-11-06: personal workspace fork documentation and limitations. -->
<p align="center">
  <img src="assets/logo.svg" alt="SnapBack — macOS window layout manager" width="120">
</p>

<h1 align="center">SnapBack</h1>

<p align="center"><strong>Your windows, back where they belong.</strong></p>

<p align="center">
  <a href="https://github.com/jamesagarside/snapback/releases"><img src="https://img.shields.io/github/v/release/jamesagarside/snapback" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="Platform: macOS">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/jamesagarside/snapback" alt="License: Apache-2.0"></a>
  <img src="https://img.shields.io/badge/built%20on-Hammerspoon-8b5cf6" alt="Built on Hammerspoon">
</p>

You unplug your MacBook from your monitors and every window piles onto the laptop screen. You plug back in — or your displays simply wake from sleep — and macOS has shuffled everything. SnapBack fixes that: it remembers a window layout for **every display setup** you use (desk, office, laptop-only) and puts everything back automatically when your screens change.

<p align="center">
  <img src="assets/snapback-story.png" alt="1: docked at your desk, the layout is saved as a profile. 2: unplug and macOS piles every window onto the laptop screen. 3: plug back in and SnapBack restores the matching profile automatically." width="880">
</p>

Built on [Hammerspoon](https://www.hammerspoon.org/). Free and open source.

## Personal workspace fork

This fork preserves James Garside's SnapBack and Apache-2.0 notices. The
[source assessment and implementation proposal](docs/WORKSPACE-ASSESSMENT.md)
document the upstream architecture, matching, profiles, display identity, and
Spaces limitations. The changes on `feat/workspace-profiles` extend existing
named profiles with:

* UUID-based display setup keys with non-destructive migration of recognizable
  numeric-ID profiles; screen-relative frames that adapt to monitor rearrangement
  and scaling. Profiles remain scoped to a connected set of displays.
* Bundle/process-aware ID matching, with strong matches reserved before fuzzy
  and same-app slot fallbacks. Ambiguous/missing monitor targets are skipped.
* Checked, atomic JSON replacement; failed reads/writes cannot claim a successful
  save. Empty captures and blank/control-character profile names are rejected.
* **Ctrl+Alt+Cmd+N** for Save As and **Ctrl+Alt+Cmd+P** to choose a profile and
  restore it. Existing shortcuts, snapping, menu, auto-restore modes, and both
  URL schemes remain available.
* Per-window restore results and a summary in Hammerspoon's Console. Inspect the
  latest structured report with `hs.inspect(spoon.SnapBack.lastReport)`.

The existing one-line installer and release links below still install the
**upstream** version. To try this fork, check out `feat/workspace-profiles`, back
up your existing Spoon and `~/.hammerspoon/snapback/`, then copy this checkout's
`SnapBack.spoon` directory into `~/.hammerspoon/Spoons/`. Use the same `loadSpoon`
and `start()` configuration shown under Manual install. No Hammerspoon config or
live window layout was changed during development.

Run `lua tests/run.lua` for the regression suite (Lua 5.4; no Hammerspoon needed).
Hardware acceptance checks are in the assessment. Automated tests use fake macOS
objects and do not prove private Spaces API compatibility on your Mac.

## Why SnapBack

* **Layout profiles per display setup**: Each monitor configuration gets its own saved layouts. Multiple named profiles per setup (e.g. "Coding", "Meeting").
* **Auto-restore on dock, undock, and wake**: When your display configuration changes, SnapBack restores the matching layout — automatically, after a prompt, or never (your choice, in the menubar).
* **Smart window matching**: Finds your windows even when titles change (Chrome tabs, editors), falling back from exact ID → title → fuzzy → same-app matching.
* **Snapping included**: Halves, thirds, two-thirds, quarters, center, maximize — with hotkeys and a menubar menu. Press Left/Right twice to throw a window to the previous/next screen. Zero animation delay.
* **Automation-friendly**: Trigger everything from a Stream Deck, Shortcuts, or scripts via `hammerspoon://` URLs.
* **Spaces support (best-effort)**: Attempts to remember which Space a window belongs to. macOS APIs for Spaces are private and can be unreliable on recent macOS versions.

Everything lives in the menubar. The map at the top of the menu is your actual display arrangement, drawn to scale, with the active profile's saved windows in place — so you can see what will snap back before it does:

<p align="center">
  <img src="assets/menubar-dropdown.png" alt="The SnapBack menubar dropdown: a to-scale map of the current three-display arrangement with saved windows drawn in, snapping actions with their hotkeys, and profile switching with a Default and a Desk profile." width="450">
</p>

## Installation

### One-line install

```sh
curl -fsSL https://raw.githubusercontent.com/jamesagarside/snapback/main/scripts/install.sh | bash
```

This installs Hammerspoon (via Homebrew) if you don't have it, installs SnapBack, and wires it into your Hammerspoon config. It's idempotent — re-run it any time to upgrade. On first install, grant Hammerspoon Accessibility permission when macOS prompts (System Settings → Privacy & Security → Accessibility).

### Manual install

1. Install [Hammerspoon](https://www.hammerspoon.org/) and grant it Accessibility permission (System Settings → Privacy & Security → Accessibility).
2. Download **SnapBack.spoon.zip** from the [latest release](https://github.com/jamesagarside/snapback/releases) and unzip it.
3. Double-click `SnapBack.spoon` (Hammerspoon installs it), or move it to `~/.hammerspoon/Spoons/` manually.
4. Add this to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("SnapBack")
spoon.SnapBack:start()
```

5. Reload Hammerspoon.

## Quick start (the travel workflow)

1. At your desk with everything plugged in, arrange your windows how you like them.
2. Press `⌃⌥⌘ S` (or menubar **SB** → *Save Current Layout*).
3. That's it. Unplug, work from the sofa, plug back in — SnapBack notices the displays returned and puts every window back. Do the same once for your laptop-only layout and it restores that when you undock, too.

Auto-restore behaviour is configurable under **SB → Auto-Restore Mode**: *Automatic*, *Prompt* (ask first), or *Disabled* (restore manually with `⌃⌥⌘ ⌫`).

## Hotkeys

Default base modifiers: **⌃⌥⌘** (Ctrl + Alt + Cmd) — customizable via **SB → Set Base Modifiers...**.

| Action | Key | Description |
| :--- | :--- | :--- |
| **Save Layout** | `S` | Save current window positions to the active profile |
| **Restore Layout** | `R` or `⌫` | Restore the active profile |
| **Save As** | `N` | Save the current layout under a new profile name |
| **Choose Profile** | `P` | Search named profiles for this display setup and restore one |
| **Left / Right Half** | `←` / `→` | Snap to half; keep pressing to walk across screens half-by-half |
| **Top / Bottom Half** | `↑` / `↓` | Snap to top/bottom half (matches the menu; use macOS `⌘M` to minimize) |
| **Corners** | `U` `I` `J` `K` | Top-left / top-right / bottom-left / bottom-right quarter |
| **Thirds** | `D` `F` `G` | Left / center / right third |
| **Two-Thirds** | `E` `T` | Left / right two-thirds |
| **Center** | `C` | Center window at 70% size |
| **Maximize** | `⏎` | Full screen frame |

## Automation / Stream Deck

| Action | URL |
| :--- | :--- |
| Restore active profile | `hammerspoon://snapback?action=restore` |
| Switch to profile and restore | `hammerspoon://snapback?action=restore&profile=Name` |
| Save active profile | `hammerspoon://snapback?action=save` |
| Save to a named profile | `hammerspoon://snapback?action=save&profile=Name` |
| List profiles | `hammerspoon://snapback?action=list` |

(The legacy `hammerspoon://windowlayout` scheme still works.)

## Data & privacy

Layouts and settings are stored as plain JSON in `~/.hammerspoon/snapback/` (menubar → *Open Data Folder...*). Nothing leaves your machine.

## Supported platforms

| Platform | Status |
| :--- | :--- |
| macOS 14 Sonoma | Developed and tested |
| macOS 13 Ventura / macOS 15 Sequoia | Expected to work (anything recent Hammerspoon supports) — not regularly tested, reports welcome |

Requires [Hammerspoon](https://www.hammerspoon.org/) (free) and Accessibility permission — that's how any macOS window manager moves windows.

## Known limitations

* **Spaces**: Moving windows between Spaces relies on private macOS APIs and may fail silently on some macOS versions; windows on non-visible Spaces may not be capturable.
  This fork reports missing targets, returned errors, and unverified membership.
  It retains a persistent window filter, but cannot discover every unvisited
  Space. Visit relevant Spaces before saving; even a nonempty capture may be
  incomplete. Fullscreen/tiled and sticky multi-Space windows remain unsupported
  as reliable workspace state. Unknown membership is preserved as unknown.
* **Space ordering**: New profiles prefer a Space ID only in the same Spoon
  instance, then fall back to the ordinal among ordinary user Spaces. Reordering
  Spaces after Hammerspoon reload/restart can change that ordinal's meaning.
  No Spaces are created, reordered, or made active.
* **Display identity**: UUIDs depend on the monitor/dock identities exposed by
  macOS. If an old numeric-ID profile's IDs already changed, it cannot migrate
  automatically; its original entry is retained. Identical display names cannot
  safely disambiguate a missing UUID. A different connected set needs its own
  saved profile; there is no automatic mapping to fewer/different monitors.
* **Restore scope**: Closed apps/documents are not reopened. Duplicate titles and
  fuzzy/slot matches can select a different same-app window. App size constraints
  and delayed macOS updates can prevent an exact frame; results reflect immediate
  observations after the move. Inspect diagnostics and retry when necessary.

## Alternatives

Looking for a free, open-source alternative to Magnet? For snapping alone, [Rectangle](https://rectangleapp.com/) is excellent and simpler to install. SnapBack is for people whose window arrangement gets destroyed by docking, undocking, or display sleep and who want it to come back on its own — plus Stream Deck/URL automation, per-display-setup layout profiles, and the hackability of Hammerspoon underneath.

## Changelog

Release history lives in [CHANGELOG.md](CHANGELOG.md). Every release must have an entry — the release workflow refuses to tag a version whose changelog entry or `obj.version` is missing, so the docs can't fall behind the releases.

## License

Apache-2.0 — see [LICENSE](LICENSE).
