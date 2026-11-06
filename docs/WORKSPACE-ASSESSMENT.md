# SnapBack as a personal workspace manager

Assessment date: 2026-11-06. Baseline: upstream
[`b18ed73`](https://github.com/jamesagarside/snapback/tree/b18ed73e6effb00af04a2dd485ba92d49c02bea1),
version 0.6.0. Fork: https://github.com/teegin-groves/snapback.

## Suitability

SnapBack is a good foundation for personal, named **window layouts** on known
display setups. It already implements names, active profiles, shortcuts, a menu,
screen-change automation, and URL control. Keep that design. It is not a complete
session manager: it does not reopen apps, documents, browser tabs, or terminal
sessions, and cannot promise restoration of every window across Mission Control
Spaces. Multi-monitor geometry and error reporting need focused fixes before
trusting automatic restoration with valuable layouts.

This assessment is from source inspection and isolated tests. Hammerspoon is not
installed on the development machine; real display/Space behavior requires the
manual acceptance checks below. No macOS-version compatibility claim is inferred
from the unit tests.

## Existing architecture and behavior

| Component | Responsibility at the baseline |
| --- | --- |
| `SnapBack.spoon/init.lua` | Hammerspoon adapters, capture/restore orchestration, screen watcher, menu, global shortcuts, URL handlers, snapping |
| `store.lua` | Injected JSON persistence; lazy settings; profiles grouped by display configuration; old flat layouts normalized on read |
| `matcher.lua` | Pure Lua matching over records, returning pairs and unmatched saved windows |
| `geometry.lua` | Pure snap-frame calculations and repeated-key screen cycling |
| `actions.lua` | Single registry shared by menu, shortcut bindings, and cheat sheet |
| `minimap.lua` | Pure arrangement drawing plan plus Hammerspoon canvas rendering |
| `tests/` | Dependency-free Lua runner and regression tests for the five pure modules |
| `scripts/install.sh`, root `init.lua` | Installation and example Hammerspoon bootstrap |

`start()` creates the menu, binds shortcuts and both `snapback`/legacy
`windowlayout` URL schemes, and starts an `hs.screen.watcher`. Display events
restart a three-second timer. The timer restores the active profile, prompts,
or does nothing according to the persisted auto-restore mode. There is no
application launch/wait stage, startup restore, or dedicated system-wake watcher.
Snapping uses zero animation duration and is independent of profile restoration.

### Window matching

Capture enumerates `hs.window.filter.new():setDefaultFilter({}):getWindows()`,
then keeps standard windows with an owning application. Each saved record has
window ID, app display name, title, absolute frame, screen name and UUID,
Space index, and standard-window status.

The baseline matches each saved window greedily, in saved order:

1. Equal numeric window ID, without checking the owning application.
2. Equal app name and exact title.
3. Same app and normalized substring title similarity above 0.5. Normalization
   lowercases, removes digits/punctuation and selected browser/editor suffixes;
   substring matches score 0.9, other comparisons score zero.
4. Any remaining window of the same app (slot fallback).

Each candidate is used at most once. IDs are ephemeral; reused IDs can target
another app. App display names are weaker than bundle identifiers. Duplicate
titles and slot matches remain ambiguous, and an early fallback can consume a
later exact/ID match. Missing apps are reported only at debug level and never
launched.

### Saved profiles and storage

Data lives in `~/.hammerspoon/snapback/{profiles,settings}.json`. The pre-rename
`window-layouts` directory is migrated if the new directory does not exist.
The profile JSON is:

```text
configId -> { active: profileName, layouts: {
  profileName: {timestamp, display_count, windows: [...]}
}}
```

Names are scoped to a display setup, not global workspaces. Saving activates
the named profile; a name-less save overwrites the active profile (initially
`Default`). The menu can create/switch names. URLs can save or restore by name.
`Ctrl+Alt+Cmd+S` saves; `R` and Delete restore. Base modifiers are configurable.
No profile chooser shortcut, rename/delete UI, or per-profile shortcut exists.
Baseline `setActive` accepts nonexistent names when called directly. JSON write
results are ignored and unreadable data is treated like an empty store, creating
a risk of reporting a failed save as successful or overwriting damaged data.

### Monitor identification and multi-monitor limitations

The baseline config key joins sorted numeric `screen:id()` values. Per-window
targets use UUID first, then display name. These are different identity systems:
a numeric ID change can make the whole layout inaccessible even when its
window UUIDs still identify the attached monitors. Same-model displays can have
identical names; the name map silently keeps the last one.

Frames use global desktop points. Changing the primary monitor, arrangement,
scaling, resolution, Dock, or menu-bar area changes their meaning. Most critically,
the baseline calls `win:move(savedAbsoluteFrame, targetScreen, true)`:
Hammerspoon only honors that screen argument for **unit rectangles**. Merely
resolving the right screen does not translate an absolute frame to it.
See [`hs.window:move`](https://www.hammerspoon.org/docs/hs.window.html#move).
A missing screen falls back to applying old global coordinates. Configuration
keys ignore geometry, so a rearranged set of the same monitors uses the old layout.
Profiles are deliberately unavailable for a different set of connected monitors;
there is no safe universal fallback for undocking to fewer displays.

### Spaces handling and cross-Space limitations

The baseline reads `allSpaces()`, saves the ordinal of the first Space returned
by `windowSpaces(win)`, and defaults to ordinal 1 on lookup failure. Restore
resolves that ordinal on the target monitor and attempts `moveWindowToSpace`
before applying the frame. Exceptions are caught, but returned error details
are discarded; missing target indices are not counted as failures. It never
creates Spaces, changes Space ordering, or restores the focused/visible Space.

Discovery is limited by Hammerspoon's knowledge of windows on other Spaces.
A new filter does not establish a complete inventory of unvisited Spaces;
Hammerspoon documents refresh and discovery limits in
[`forceRefreshOnSpaceChange`](https://www.hammerspoon.org/docs/hs.window.filter.html#forceRefreshOnSpaceChange).
Saving can therefore capture an incomplete layout. Mission Control reordering
(including automatic rearrangement) changes ordinal meaning. Fullscreen/tiled
Spaces are mixed into `allSpaces` indices; sticky windows can belong to multiple
Spaces but only one is saved. With separate-display Spaces disabled, per-display
ordinal assumptions need real-device validation.

`hs.spaces` uses private APIs. Its move API permits ordinary user-Space moves,
but not normal restoration of fullscreen/tiled windows. A successful call also
does not establish that a later geometry operation stayed on the intended Space.
See [Hammerspoon Spaces documentation](https://www.hammerspoon.org/docs/hs.spaces.html#moveWindowToSpace).
Cross-Space restoration must remain best-effort, with explicit diagnostics;
this fork should not promise otherwise.

## Minimal implementation proposal

Retain the existing Spoon, profile schema, action registry, matching cascade,
snapping, minimap, auto-restore settings, URL schemes, and legacy migrations.
Add narrowly scoped behavior:

1. A pure display helper builds sorted UUID config keys (numeric fallback when
   UUID is unavailable), resolves only unambiguous name fallbacks, and exposes
   the legacy numeric key. Copy a legacy config to its new key when first used;
   retain the old entry and never overwrite an existing new-key config. Old
   numeric IDs that have already changed cannot be migrated automatically.
2. Add screen-relative unit frames alongside existing absolute frames. Convert
   to/clamp within the target monitor's current usable frame on restore. Keep
   a clamped absolute-frame path for old profiles. Share the new relative-frame
   geometry with minimap previews. Legacy minimap clipping is retained until
   that profile is saved again. Skip an unresolved monitor rather than guess.
3. Add bundle ID and process ID when available. Require application identity
   for ID matches and prefer stronger matching tiers across the whole layout
   before slot fallback. Preserve same-app fuzzy/slot behavior and report it.
4. Keep unknown Space membership unknown; store the current Space ID as a hint
   alongside the ordinal and a Spoon-instance token. Prefer a still-valid
   user-Space ID only within that instance, then a user-Space
   ordinal, and keep a raw-index path for old profiles. Do not manufacture
   membership or create/switch Spaces. Count unavailable, missing, and failed
   moves; isolate one window failure from the rest of the restore.
5. Write JSON to a sibling temporary file and rename it over the destination
   only on success. Reject unreadable existing files and invalid profile names;
   reject unknown activation. Surface storage errors before claiming success.
6. Add a keyboard profile chooser and a keyboard Save As action through the
   existing registry; retain all existing keys and URL/menu controls.
7. Emit structured capture/restore and per-window results through the existing
   Hammerspoon logger, expose the latest report on the Spoon, and summarize
   moved, unmatched, skipped, frame failures, and Space failures in alerts.
   Omit window titles from default logs. Do not add a logging service.

An empty capture must not replace a populated profile. A partially discoverable
capture cannot be proven complete: users should visit relevant Spaces before
saving and retain backups. Stable display UUIDs still depend on what macOS and
the dock expose; swapped hardware/ports or cloned monitor identities can require
a fresh save. App constraints can reject geometry; verify and report the observed
frame rather than counting every match as restored. Verification samples the
immediate result after the last operation; delayed macOS updates can require
a manual retry. Reloading Hammerspoon invalidates the Space-ID hint, so only
the user-Space ordinal remains and reordering can still change its meaning.

## Validation and acceptance

Run `lua tests/run.lua` and `luac -p` on all Lua files. Add deterministic tests
for UUID keys and legacy migration, duplicate monitor names, moved/resized and
negative-origin displays, global match priority and reused IDs, failed/corrupt
storage, Space target selection, shortcut dispatch, and mixed-success restores
using a Hammerspoon stub. Preserve every upstream regression.

Implementation verification on 2026-11-06: **99 tests passed, zero failures**
(the original 59 plus 40 added regressions), using Lua 5.4.8 built in temporary
storage. All Lua files passed `luac -p`; `git diff --check` passed. `LICENSE`,
the upstream installer, and release workflow are unchanged. Hammerspoon-boundary
tests cover both URL schemes, existing/new shortcuts, auto-restore modes and
debouncing, final-frame observation, corrupt/failed saves, and partial restores.
The hardware checklist below has **not** been executed.

Before enabling automatic restore on the user's Mac:

- Install the fork manually without replacing the user's Hammerspoon config;
  grant Accessibility and back up existing profile JSON.
- Save two names using Save As, switch using the chooser, and restore through
  the menu, shortcuts, and both URL schemes. Confirm failed writes never say saved.
- Dock/undock/redock, reorder displays, change scaling/primary display, and
  use two monitors with the same model name. Confirm frames and previews agree.
- Use two same-app windows with changing and identical titles, then restart
  the app. Inspect Exact/Fuzzy/Slot diagnostics and unmatched windows.
- Visit two ordinary Spaces, save, move windows, and restore. Repeat after
  reordering/deleting a Space, with a fullscreen app, a sticky window, and with
  separate-display Spaces both enabled and disabled. Confirm partial results
  are visible and no guarantee of full cross-Space recovery is implied.
- Test Automatic, Prompt, and Disabled modes through sleep/wake and docking.
  Confirm existing snapping and screen cycling still work.

Apache-2.0 `LICENSE`, upstream author/homepage metadata, existing attribution,
and installer defaults are retained. Modified source files carry change notices.
