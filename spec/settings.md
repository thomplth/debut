# Settings and onboarding

The feature controls cover screenshot previews, switching within the current
desktop, switching across all desktops, and faster desktop navigation. **Stage** is the
product term for a desktop's window group. Existing UI labels such as “workspace,”
“space,” and “Space Manager session” refer to these desktop-backed stages and
their switcher; they do not denote independent virtual workspaces.

## Defaults

These are fresh-install defaults from
[FeatureSettings](../Sources/DebutCore/Models/FeatureSettings.swift) and
[AppSettings](../Sources/DebutCore/Models/AppSettings.swift). Saved choices remain
authoritative; changed defaults do not overwrite existing explicit preferences.

| Setting | Default |
| --- | --- |
| Window previews | On |
| Workspace isolation (Command-Tab and same-app cycling) | On |
| Option-Tab across all desktops | On |
| Faster desktop transitions | On |
| Numbered desktop shortcuts | On |
| Faster Control-arrow switching | On |
| Faster trackpad desktop swipe | On |
| Desktop switch duration | Instant (0 ms); configurable through 400 ms per desktop crossed |
| Desktop switch indicator | On |
| Overlay on main display only | On |
| Adaptive card sizing | On |
| Window size / inactive stage scale | 150% / 70% |
| Glass / stage corner radius | Clear / 30 pt |
| Selection appearance | Filled; 6 pt outset, 12 pt radius |
| Alternative magnify appearance | 106% size, 100% shadow strength |
| Overlay hold delay / held cycling pace | 100 ms / 60 ms minimum between repeats |
| Preview refresh / cache age | Only windows that may have changed / 60 seconds |
| Numbered / same-app numbered modifiers | Control / Control-Option |
| Launch at login / show in Dock | On / On |
| Excluded apps | Empty |

Cache age is evaluated when capture work is requested; it is not a recurring
refresh timer. The code remains authoritative for control ranges, decoding
fallbacks, and [default bindings](../Sources/DebutCore/Models/KeyBinding.swift).

## Feature behavior and permissions

Disabling workspace isolation returns Command-Tab and Command-backtick activation
to macOS and disables the fixed focused-window move chords. Stage browsing and
Option-Tab remain available. Option-Tab has its own enable control; disabling it
passes its configured activation shortcuts through unchanged.
Saved shortcuts are retained when a feature is off.

Disabling previews stops window screenshot capture and clears cached images;
cards show icons and titles. Screen Recording enables screenshot previews and
can affect title availability. Debut no longer captures or paints desktop
wallpaper. Accessibility is required for global input and window control.

Faster desktop transitions is the parent for numbered shortcuts, Control-arrow,
trackpad interception, and Debut's synthetic transition when selecting a window
on another desktop. Turning it off disables the three child controls without
changing their saved choices, disables the duration control, and lets macOS
perform cross-desktop window activation with its original transition. Turning
the parent back on restores the saved child choices. The duration applies only
while the parent is enabled. A trackpad desktop gesture commits one adjacent hop.
Other gestures and unclaimed shortcuts keep their native behavior. Enabled
numbered and Control-arrow shortcuts apply regardless of which app is frontmost.
Mission Control, App Exposé, and Show Desktop retain their native navigation;
unsupported synthetic switching is passed through rather than swallowed.

The desktop indicator reports confirmed changes, including native navigation,
on the affected display. Main-display-only overlay placement does not change
which display stack the window switcher navigates.

## Settings pages

Settings opens on **General**. Each sidebar page scrolls independently, and
changes save immediately and update shared onboarding controls and menu checkmarks.

| Page | Contents |
| --- | --- |
| General | Login launch, Dock visibility, Reduce Motion guidance, and a running-app picker for applications ignored by window management. The menu-bar item remains available with the Dock icon off. |
| Desktops | Faster switching and its number-key, Control-arrow, and trackpad methods, followed by transition duration and the desktop-change indicator. |
| Switcher | Command-Tab desktop isolation, Option-Tab activation, window previews, display placement, and preview freshness. |
| Appearance | Glass and card layout, adaptive preview sizing, inactive-stage scale, and selected-window treatment. |
| Shortcuts | Activation/session bindings, numbered modifier sets, hold delay, repeat pace, a confirmed restore-defaults action, and reference for fixed move chords. |
| Support | Version and update checks, diagnostic export, and a confirmed window-cache reset that preserves settings. |

Every configurable value has one destination: app-level choices and ignored apps
are in General; desktop navigation and feedback are in Desktops; overlay behavior,
content, placement, and freshness are in Switcher; visual layout and selection are
in Appearance; and all key assignments and held-key timing are in Shortcuts.
Support contains actions rather than preferences.

The menu-bar item provides feature toggles, Settings, Tutorial, update checks,
and Quit. System Reduce Motion changes overlay animation; it is not a separate
Debut animation switch. See [privacy](../docs/privacy.md) for local data and the
user-initiated diagnostic export boundary.

## Onboarding and tutorial

Setup has five pages and never requires shortcut practice:

1. Welcome retains the icon and Debut name with “Turns the macOS Command-Tab
   switcher into a workspace manager”. Accessibility is required for shortcuts
   and window control; Screen Recording is optional and enables window previews.
   Permission requests happen only when the user clicks the corresponding button.
2. Command-Tab introduces the desktop-grouped switcher with a real screenshot and
   its enable toggle. Only a device with exactly one desktop sees verbal Mission
   Control instructions for adding another; creation is never required.
3. Option-Tab introduces the all-desktops switcher with a real screenshot and its
   independent enable toggle. Both switchers default on.
4. Faster desktop switching exposes only its master toggle (default on). Duration,
   gestures and shortcut controls remain in Settings; toggling the master preserves
   those saved choices.
5. You’re ready offers Start using Debut, Start tutorial, and Open Settings. Every
   action completes setup before opening its destination.

Without Screen Recording, both example screenshots show the icon-based fallback.
No remote telemetry or sharing consent is part of setup. Back/Continue never
changes feature preferences. Setup progress survives restarts, and existing users
are not forced through setup again.

Tutorial is a separate optional flow opened from the final setup page or the menu
bar. It teaches window switching, desktop navigation, moving windows, and Option-Tab
using verified practice targets. Each lesson can be skipped and the tutorial can
be exited at any time; neither action changes setup completion or feature choices.
A disabled switcher offers Settings or Skip lesson instead of enabling itself.
With one desktop, practice omits cross-desktop exercises. Screen Recording is not
required. Tutorial progress resumes independently after exiting or restarting;
finishing clears only tutorial progress. The switcher isolates practice windows
only while the learner is working from the tutorial.
