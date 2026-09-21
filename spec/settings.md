# Settings and onboarding

The feature controls describe three capabilities: screenshot previews, switching
within the current desktop, and faster desktop navigation. **Stage** is the
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
Option-Tab remain available. Saved shortcuts are retained when a feature is off.

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
| Switcher | Command-Tab desktop isolation, window previews, display placement, and preview freshness. |
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

## Onboarding

The tutorial progresses through Welcome, Workspace, Previews, Speed, and Ready.
It requests Accessibility for interaction and Screen Recording for enabled
previews. Workspace practice uses real windows to teach within-stage switching,
desktop switching, and window movement; the previews page teaches Option-Tab.
Exercises verify the intended window and destination instead of passing merely
because an overlay opened. Practice constrains the switcher to tutorial targets
and disables unrelated destructive actions.

With only one desktop, the tutorial can teach local window switching and
Option-Tab without pretending to cross desktops. It offers Mission Control for
adding another desktop; Debut itself does not create one. Progress checkpoints
allow resuming, and Tutorial can be reopened from the menu bar. Feature and
duration choices are shared with Settings.
