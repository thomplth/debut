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
| Workspace isolation (Command-Tab) | On |
| Option-Tab across all desktops | On |
| Faster desktop transitions | On |
| Numbered desktop shortcuts | On |
| Faster Control-arrow switching | On |
| Faster trackpad desktop swipe | On |
| Desktop switch duration | Instant (0 ms); configurable through 400 ms per desktop crossed |
| Desktop switch indicator | On |
| Overlay on main display only | On |
| Adaptive card sizing | On |
| Window size / inactive stage scale | 150% / 70%; 100% is the native Command-Tab switcher plate (102 pt slots, 176 pt one-row plate), up to 400%. The size enlarges only previews or icons; titles, plate margins, card gaps, highlight padding and corners keep native points |
| Card spacing | 14 pt between selection highlights, as native; not adjustable. Wrapped rows in both switchers put each title midway between its previews and the next row's |
| Glass / stage corner radius | Native / 40 pt continuous with previews, 58 pt (native) for icon cards; one slider edits whichever the switcher draws (0–72 pt) |
| Liquid Glass rim / edge refraction | 100% / 100% of the native switcher's fitted look |
| Liquid Glass tint | Follows System Settings; a fixed 0–100% tint is optional on macOS 27, and not offered on macOS 26, whose glass cannot draw one |
| Title halo / size | 100% / 0.5 pt; 0% turns the halo off |
| App icon position / growth | Title (before the title, outside its halo; also Corner, Bottom, Top) / 0.50: the badge grows with the preview size raised to this power (0 fixed, 1 proportional) |
| Preview & selection highlight | Native switcher highlight at 100% strength, 8 pt surrounding space with previews and 9 pt for icon cards; previews rounded at 6 pt, the highlight concentric with them. Icon cards keep the icon's own corner |
| Overlay hold delay / held cycling pace | 100 ms / 60 ms minimum between repeats |
| Preview refresh / cache age | Only windows that may have changed / 60 seconds |
| Numbered / same-app numbered modifiers | Control / Control-Option |
| Overlay card selection | H left, J down, K up, L right (configurable) |
| Launch at login / show in Dock | On / On |
| Send crash reports automatically | Off; shown only in nightly and stable releases |
| Excluded apps | Empty |

The preview switcher and the icon switcher (drawn without previews) keep separate
Appearance values: Liquid Glass material, rim, edge refraction and tint, title halo,
stage corner radius, size, inactive stage scale, and selection highlight strength and
surrounding space. Each mode has its own fresh defaults, the same as listed above except
that icon mode uses a 100% icon size, the native 58 pt stage corner, and 9 pt of
surrounding space, against 150%, 40 pt and 8 pt with previews; editing one mode never
changes the other. Settings saved before the split give both modes the values they drew
then, and a value either mode never saved takes that mode's default.

Cache age is evaluated when a desktop settles into view: only its windows with
previews older than the cache age are recaptured. It is not a recurring refresh
timer, and an overlay open never recaptures a preview for age alone. The code remains authoritative for control ranges, decoding
fallbacks, and [default bindings](../Sources/DebutCore/Models/KeyBinding.swift).

## Feature behavior and permissions

Disabling workspace isolation returns Command-Tab activation to macOS and disables
the fixed focused-window move chords. Command-backtick is always left to macOS,
whose own cycle already stays on the current desktop, which is a stage. Stage browsing and
Option-Tab remain available. Option-Tab has its own enable control; disabling it
passes its configured activation shortcuts through unchanged.
Saved shortcuts are retained when a feature is off.

Disabling previews stops window screenshot capture and clears cached images.
Without previews, whether the toggle is off or Screen Recording is not granted,
both switchers draw each window as a native Command-Tab icon slot with its title,
at a separate icon size (default 100%, the native switcher) that the same size
slider edits while icons are drawn. A window whose capture failed keeps its card with the app's icon at
the badge's size and no halo. The badge sits where App icon position puts it and grows on
the App icon growth curve. Magnify, the former alternative selection style, is retired; a
saved choice of it loads with the highlight.
Every card in both switchers is titled in the native label style at full strength, a
fixed 12.8 pt (the native label, at SF weight 680) at every size, centred between the card's lower edge and the plate's,
with a tight halo in the opposite colour for legibility on clear glass. The desktop
indicator and the display stack indicator text carry the same halo. Screen Recording enables screenshot previews and
can affect title availability. Debut no longer captures or paints desktop
wallpaper. Accessibility is required for global input and window control.

Faster desktop transitions is the parent for numbered shortcuts, Control-arrow,
trackpad interception, and Debut's synthetic transition when selecting a window
on another desktop. Turning it off disables the three child controls without
changing their saved choices, disables the duration control, and lets macOS
perform cross-desktop window activation with its original transition. Turning
the parent back on restores the saved child choices. The duration applies only
while the parent is enabled. A trackpad desktop gesture commits one adjacent native
Space hop, including into or out of a fullscreen app. Fullscreen Spaces remain in
Mission Control order, so accelerated switching neither skips an intervening fullscreen
app nor makes one at the first or last position unreachable.
Other gestures and unclaimed shortcuts keep their native behavior. Enabled
numbered and Control-arrow shortcuts apply regardless of which app is frontmost.
Mission Control, App Exposé, and Show Desktop retain their native navigation;
Debut never takes over a trackpad gesture while one of those overviews is active,
and the complete gesture stream remains native rather than changing ownership mid-swipe.
unsupported synthetic switching is passed through rather than swallowed.

The desktop indicator reports confirmed changes, including native navigation,
on the affected display. Main-display-only overlay placement does not change
which display stack the window switcher navigates.

## Settings pages

Settings opens on **General**. Each sidebar page scrolls independently, and
changes save immediately and update shared onboarding controls and menu checkmarks.

| Page | Contents |
| --- | --- |
| General | Login launch, Dock visibility, automatic crash reports, Reduce Motion guidance, and a running-app picker for applications ignored by window management. The menu-bar item remains available with the Dock icon off. |
| Desktops | Faster switching and its number-key, Control-arrow, and trackpad methods, followed by transition duration and the desktop-change indicator. |
| Switcher | Command-Tab desktop isolation, Option-Tab activation, window previews, display placement, preview freshness, overlay hold delay, and held cycling pace. |
| Appearance | A live preview of the switcher pinned at the top (over a High Contrast, Text or Stripes backdrop), then card layout, adaptive preview sizing, inactive-stage scale, app icon position and growth, Liquid Glass (material, rim, edge refraction, title halo, tint), and the preview and selection highlight. It edits the mode the switchers currently draw: with previews, or as icons when previews are off or Screen Recording is not granted. App icon position, app icon growth, matching previews to windows and the preview corner radius apply only to previews and are shown only in that mode. |
| Shortcuts | Activation and Space Manager session bindings including H/J/K/L selector movement and Space to lock the overlay open, numbered modifier sets with a Disabled choice, a confirmed restore-defaults action, and reference for fixed move chords. Pressing Delete while recording clears a binding. An open session handles its own keys before global shortcuts, and Debut binding conflicts are checked within each context. |
| Support | Bug reporting through a public GitHub issue form (requires a GitHub account), diagnostic export, a confirmed window-cache reset that preserves settings, and a confirmed reset of all settings that preserves window assignments. |
| About | Debut icon and version, update checks, and links to the GitHub repository and creator's Twitter profile. |

Every configurable value has one destination: app-level choices and ignored apps
are in General; desktop navigation and feedback are in Desktops; overlay behavior,
content, placement, freshness, and held-key timing are in Switcher; visual layout and selection are
in Appearance; and all key assignments are in Shortcuts.
Support contains actions rather than preferences. Every page with preferences ends with a
confirmed Restore Defaults action that resets that page only; on Appearance it resets
only the mode shown.

Native glass matches the macOS Command-Tab switcher through DockGlass. Every material follows
the system Liquid Glass tint live unless a fixed tint is chosen; Clear and Regular then draw
what macOS draws at that tint. macOS 26's glass has no fill to tint, so Settings offers no
fixed tint there and a saved one is ignored. Under Reduce Transparency, Increase Contrast, or a macOS version
without a fitted look, Native shows the system's own clear glass and reports why in diagnostics,
and every material follows the system tint.

The menu-bar item provides feature toggles, Settings, Setup, Tutorial, update
checks, and Quit. System Reduce Motion changes overlay animation; it is not a separate
Debut animation switch. See [privacy](../docs/privacy.md) for local data, the
user-initiated diagnostic export boundary, and crash reports.

After a crash, the next launch asks whether to send that report, with a checkbox
that turns on automatic sending. Don’t Send deletes it. The question appears only
in nightly and stable releases.

## Onboarding and tutorial

Setup has five pages and never requires shortcut practice:

1. Welcome retains the icon and Debut name with “Turns the macOS Command-Tab
   switcher into a workspace manager”. Accessibility is required for shortcuts
   and window control; Screen Recording is optional and enables window previews.
   Permission requests happen only when the user clicks the corresponding button.
   The permission guide opens the matching System Settings pane and offers Debut as a
   draggable app. Returning to Debut restores the same setup page. If Screen Recording
   is granted, choose Quit & Reopen in the macOS prompt; setup resumes automatically.
   If you choose Later, the guide offers Restart Debut while Screen Recording is ready
   but unavailable to the current process. Screen Recording never blocks setup.
2. Command-Tab introduces the desktop-grouped switcher with a real screenshot and
   its enable toggle. Only a device with exactly one desktop sees verbal Mission
   Control instructions for adding another; creation is never required.
3. Option-Tab introduces the all-desktops switcher with a real screenshot and its
   independent enable toggle. Both switchers default on.
4. Faster desktop switching shows a looping, real-time comparison of macOS default
   switching and Debut Instant. Its master toggle defaults on, with a transition
   duration slider from Instant to 400 ms per desktop. Changes save immediately;
   disabling the master disables the slider and preserves its value. Gesture and
   shortcut controls remain in Settings.
5. You’re ready offers Start using Debut, Start tutorial, and Open Settings. Every
   action completes setup before opening its destination.

Without Screen Recording, both example screenshots show the icon-based fallback.
No telemetry or crash-report consent is part of setup. Back/Continue never
changes feature preferences. Setup progress survives restarts, and existing users
are not forced through setup again. The menu bar reopens setup at any time,
resuming wherever it was left.

Tutorial is a separate optional flow opened from the final setup page or the menu
bar. It teaches window switching, desktop navigation, moving windows, and Option-Tab
using verified practice targets. Each lesson can be skipped and the tutorial can
be exited at any time; neither action changes setup completion or feature choices.
A disabled switcher offers Settings or Skip lesson instead of enabling itself.
With one desktop, practice omits cross-desktop exercises. Screen Recording is not
required. Tutorial progress resumes independently after exiting or restarting;
finishing clears only tutorial progress. The switcher isolates practice windows
only while the learner is working from the tutorial.
