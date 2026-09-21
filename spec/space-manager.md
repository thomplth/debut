# Stage and window switchers

Debut complements Mission Control with a visual, window-based way to work with
real macOS desktops. A **stage** represents one desktop. macOS creates, removes,
orders, and displays desktops; Debut reflects them and can switch to an existing
desktop or move a window to one. See [system behaviors](behaviors.md) for the
membership and persistence rules.

The stage overlay groups windows by desktop. Ordinary Command-Tab cycling stays
within the selected stage, while explicit stage navigation and the all-windows
switcher let the user cross desktop boundaries. An app with windows on several
desktops appears through its individual windows in each corresponding stage.
An app with no tracked window on the current desktop contributes no card to that
stage's cycle. Other stages can still be visible around the selected stage.

## Shipped shortcuts

Activation and session shortcuts are editable. These are the defaults in
[KeyBinding.swift](../Sources/DebutCore/Models/KeyBinding.swift); the fixed
focused-window move chords are handled by
[EventTapKeyboardService](../Sources/DebutCore/Services/EventTapKeyboardService.swift).

| Shortcut | Behavior |
| --- | --- |
| Command-Tab / Command-Shift-Tab | Open the stage overlay and cycle that stage's windows forward / backward. |
| Command-backtick / Command-Shift-backtick | Immediately cycle the current app's windows within the current stage. |
| Command-Option-Tab / Command-Option-Shift-Tab | Open the stage overlay and browse stages forward / backward. Command-Option-backtick is another backward binding. |
| Option-Tab / Option-Shift-Tab | Open the flat all-windows switcher and cycle tracked windows across desktops and displays. |
| Control-1–9 | Switch directly to desktop 1–9 in the current display stack and focus its most recently used window. |
| Control-Option-1–9 | Switch to that desktop, preferring a window from the current app, then falling back to the desktop's most recently used window. |
| Control-Left / Control-Right | Switch to the previous / next desktop when faster Control-arrow switching is enabled. |
| Command-Option-Left or Up / Command-Option-Right or Down | Move the focused window to the previous / next desktop and follow it. Requires workspace isolation. |

The numbered chords have independently configurable modifier sets. Digit 0 has
no binding. Out-of-range direct destinations and moves beyond the first or last
desktop do nothing; they do not create desktops or wrap around.

With the stage overlay open, keep the activation modifier held:

| Session key | Behavior |
| --- | --- |
| Tab / Shift-Tab or backtick | Next / previous window in the selected stage. |
| Option-Tab / Option-Shift-Tab | Next / previous stage, selecting its first window. |
| 1–8 / 9 | Select stage 1–8 / the **last** stage in the selected display stack. This differs from global Control-9, which means desktop 9. |
| Return | Select the next connected display stack. |
| Up / Down | Preview moving the selected window to the adjacent stage; selection follows it. |
| Left / Right | Preview reordering the selected window within its stage. |
| Q / W | Request that the selected window's app quit / that the selected window close. |
| Escape | Dismiss the overlay and discard pending moves. |
| Release activation modifier | Commit pending moves and focus the selected window, switching desktop if necessary. |

Fresh window-cycle presses wrap. Held window cycling, same-app cycling, and
all-windows cycling stop at the end of the list and obey the configured repeat
pace. Stage and display-stack cycling wrap.

## Sessions and selection

A quick Command-Tab press selects the previous window without showing the
overlay. Holding past the presentation delay (100 ms by default) shows previews.
Forward activation normally preselects the second most recently used window;
when the frontmost app is excluded, stage switching starts with the first eligible
window instead. Reverse activation starts at the last window.

The held-modifier session and the visible overlay are separate. Escape cancels
the current selection and pending edits but leaves the held session alive; a
navigation shortcut can reopen the overlay before the modifier is released.
Session bindings are interpreted relative to the held activation modifier.

Hover highlights a provisional pointer target. A subsequent navigation or action,
including modifier release, uses that target. Leaving the preview before acting
restores the keyboard target; Escape discards the hover. Clicking a window
commits it immediately. Clicking the desktop outside the stage
cards dismisses the overlay, discards pending moves, and exposes Finder's real
desktop through the app's desktop-reveal action.

Close and quit are requests, not evidence of completion. The overlay updates when
the window is destroyed or the process exits. If an app opens a save or other
confirmation dialog, Debut yields input and presentation to it. Escape cannot
undo a close or quit request already delivered to another app.

## Layout and previews

Stages form a vertical stack with the selected stage centered and inactive
stages scaled down. Each window card carries a screenshot when available, its
app icon, and a title (falling back to the app name). Cards use each window's
proportions by default, wrap into rows, and scale down to fit large stages.
Stages themselves have no editable names or visible title labels.

The overlay uses glass stage backgrounds over the existing desktop. Debut does
not draw a wallpaper or a full-screen surface to hide other windows. The filled
selector is the default; magnification is an alternative. Stage focus animates
with a spring, and Reduce Motion substitutes a fade. Appearance controls live in
[Settings](settings.md).

Navigation recenters the selected stage. Vertical scrolling browses stages, and
pointer/drag interaction can reveal stages near the viewport edges. The old
limitation that off-screen stages cannot be reached no longer applies. Window
cards do not show Dock-style notification badge counts.

Screenshots are cached in memory, prewarmed after launch reconciliation, and
refreshed after the overlay is presented. The default policy refreshes windows
that may have changed or whose capture is stale; it does not continuously stream
every window. Missing captures fall back to an app icon. Disabling previews
stops window captures and clears the cache.

## Moving windows

Drag a card within a stage to change its order, or onto another stage to prepare
a desktop move. Keyboard Up/Down moves use the same preview transaction and animate
the selected card directly into the adjacent stage's MRU slot; this guided flight is
keyboard-only and does not replace the pointer drag preview or its drop handoff.
The source card stays invisibly retained for the flight so its ordinary removal transition
cannot leave an afterimage, and the proxy hands off at the measured destination-card center.
Keyboard Left/Right reorders within the selected stage. These edits affect the
displayed preview until the user commits by releasing the modifier or choosing a
window. Escape discards them without moving real windows.

On commit, Debut sends desktop relocations through the bridged window-server
operation. Dragging a card is an overlay interaction; Debut does not synthesize a
drag of the real window. Cross-desktop moves are unavailable if the bridge is
unavailable. A failed delivery is reported and later reconciliation follows the
window's actual desktop. Empty source stages remain because their desktops still
exist. The immediate Command-Option-arrow command is separate: it moves and
follows the focused window without an overlay preview transaction.

Stages cannot be created, deleted, renamed, or reordered through Debut. Users
manage the desktop list in Mission Control, and Debut adopts its new order.

## All-windows switcher

Option-Tab presents a flat list in global activation order. It includes tracked
live windows across stages and display stacks, excluding dormant assignments and
excluded apps. Selecting one uses the same desktop-switch and focus path as the
stage overlay. A window belonging to an app already present on the current
desktop remains individually selectable on its own desktop.

Tab, backward cycling, pointer selection, close, quit, Escape, and modifier-release
commit work in this mode. Stage navigation, display-stack navigation, stage jumps,
and window-reordering/movement actions are ignored because this view has no stage
layout to edit.

## Displays and fullscreen

With macOS's **Displays have separate Spaces** enabled, each display has its own
stage stack and current desktop. Otherwise Debut uses one shared stack. Return
in the stage session cycles connected stacks; Option-Tab spans them.

Both overlays appear on the main display by default. Turning off **Show overlay
only on main display** places them on the focused window's display, using the
largest overlap for a window spanning screens. Overlay placement is separate
from navigation scope: the initial stage stack follows the focused display even
when the panel is pinned to the main display.

The nonactivating overlay panel can appear over a fullscreen app's Space.
Fullscreen Spaces are not additional desktop stages, and the all-windows list
is not an inventory of every fullscreen surface. A newly discovered window that
macOS places on no normal desktop is not invented as a card in stage 1. Existing
assignments with no single desktop answer are handled conservatively as described
in [system behaviors](behaviors.md).
