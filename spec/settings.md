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
| Excluded apps / quick-switch exclusions | Empty |
| Share anonymous usage and performance data | On, delivery gated until onboarding completion |

Cache age is evaluated when capture work is requested; it is not a recurring
refresh timer. The code remains authoritative for control ranges and decoding
fallbacks. See [switcher shortcuts](space-manager.md#shipped-shortcuts) for bindings.

## Feature behavior and permissions

Disabling workspace isolation returns Command-Tab and Command-backtick activation
to macOS and disables the fixed focused-window move chords. Stage browsing and
Option-Tab remain available. Saved shortcuts are retained when a feature is off.

Disabling previews stops window screenshot capture and clears cached images;
cards show icons and titles. Screen Recording enables screenshot previews and
can affect title availability. Debut no longer captures or paints desktop
wallpaper. Accessibility is required for global input and window control.

Numbered shortcuts, Control-arrow, and trackpad interception are independent.
The duration applies to desktop changes requested through Debut's shared switching
path. A trackpad desktop gesture commits one adjacent hop. Other gestures and
unclaimed shortcuts keep their native behavior. Quick-switch exclusions apply
to numbered and Control-arrow inputs while a configured app is frontmost.
Mission Control, App Exposé, and Show Desktop retain their native navigation;
unsupported synthetic switching is passed through rather than swallowed.

The desktop indicator reports confirmed changes, including native navigation,
on the affected display. Main-display-only overlay placement does not change
which display stack the window switcher navigates.

## Settings pages

Settings opens on **Features**. Each sidebar page scrolls independently, and
changes save immediately and update shared onboarding controls and menu checkmarks.

| Page | Contents |
| --- | --- |
| Features | Preview and workspace switches, three desktop-navigation switches, duration, and desktop indicator. |
| Excluded Apps | Running-app picker for applications omitted from window management. |
| App | Login launch and Dock visibility. The menu-bar item remains available with the Dock icon off. |
| Privacy | Sharing switch and preview of the exact allowlisted session-summary payload. |
| Keyboard Shortcuts | Activation/session bindings, numbered modifier sets, hold delay, repeat pace, shortcut exclusions, and reference for fixed move chords. |
| Advanced | Main-display overlay placement, glass, stage/card geometry, adaptive sizing, selector appearance, and preview refresh/cache policy. |
| Troubleshooting | Export local diagnostics or reset window assignments against the real desktop list while preserving settings. |
| About | Version and update check. |

The menu-bar item provides feature toggles, Settings, Tutorial, update checks,
and Quit. System Reduce Motion changes overlay animation; it is not a separate
Debut animation switch. See [privacy](../docs/privacy.md) for local and remote data.

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
duration choices are shared with Settings, and the Ready page presents the
anonymous-sharing choice before delivery is enabled.
