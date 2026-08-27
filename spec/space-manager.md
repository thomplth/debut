# Space Manager

A system-wide overlay that replaces the native macOS app switcher. It shows every
space as a vertically stacked stage of window previews and supports keyboard and
pointer interaction for navigating and reorganizing spaces and their windows.

## Layout

```
┌─────────────────────────────────────────────────┐
│                                                 │
│    ┌─────────────────────────────────────┐      │  inactive, scaled down
│    │ ┌───────┐ ┌───────┐ ┌───────┐       │      │
│    │ │preview│ │preview│ │preview│       │      │
│    │ └───────┘ └───────┘ └───────┘       │      │
│    └─────────────────────────────────────┘      │
│                                                 │
│   ┌───────────────────────────────────────┐     │  active, full scale
│   │  ┌───────┐ ┌───────┐ ┌───────┐        │     │
│   │  │preview│ │preview│ │preview│        │     │
│   │  └───────┘ └───────┘ └───────┘        │     │
│   └───────────────────────────────────────┘     │
│                                                 │
│    ┌─────────────────────────────────────┐      │  inactive, scaled down
│    │ ┌───────┐ ┌───────┐                 │      │
│    │ │preview│ │preview│                 │      │
│    │ └───────┘ └───────┘                 │      │
│    └─────────────────────────────────────┘      │
│                                                 │
└─────────────────────────────────────────────────┘
```

Each item is a window screenshot, aspect-fit, badged with its app icon in the
top-left and captioned with its window title. Stages carry no title. The active
stage is vertically centered at full scale; inactive stages render at a smaller
configurable scale.

Stages float directly on the desktop — there is no full-screen backdrop or
backdrop blur. Previews are captured when the overlay opens and cached for
windows that are hidden. Icon size adapts to screen width, and preview content
uses equal top and bottom padding. The selection highlight wraps both thumbnail
and title.

Space focus changes animate as a low-bounce vertical spring with a subtle lift on
the active stage. Reduce Motion substitutes a short fade.

Appearance values (scale, corner radius, selection fill and border) are
user-configurable; see `AppSettings`.

## Shortcuts

Every shortcut is user-configurable, so this document deliberately does not list
key bindings. The authoritative set of actions is the `KeyAction` enum in
`Sources/DebutCore/Models/KeyBinding.swift`; shipped defaults live in
`KeyBindings`. What follows is the behavior behind each action group, which the
enum cannot express.

Global activation shortcuts define the modifier held for the session. Space
Manager shortcuts are recorded relative to that held modifier.

### Session model

Tapping the activation shortcut — releasing before the configurable presentation
delay — switches to the most recently used window in the active space without
showing the overlay. Holding past that delay presents the overlay.

The held-modifier session and overlay visibility are separate states.
`dismissOverlay` closes the overlay but leaves the session alive, so a further
navigation keypress reopens it. Releasing the modifier commits the current
selection and ends the session.

The overlay opens on the display holding the focused window, not on the main
display. Accessibility reports that window in Quartz coordinates, so displays
are matched in that space and only the winning display is translated back into
Cocoa's. A window straddling two displays resolves to the one it overlaps most.

The overlay is also presented inside a fullscreen app's Space.

### Navigation

All navigation wraps cyclically.

- `nextWindow`, `previousWindow`, and `previousWindowAlternate` move the
  selection horizontally within the active stage.
- `nextSpace` and `previousSpace` move vertically across stages. Changing space
  resets the selection to that space's most recently used window.
- `jumpToSpace1`–`jumpToSpace9` select a space by position within the open
  overlay. The ninth targets the *last* space rather than literally space 9.
- `nextAppWindow` and `previousAppWindow` cycle the windows of the current app.
- The overlay opens with the second most recently used window preselected, so a
  single activation lands on the previous window.

### Quick switch

`quickSwitchSpace1`–`quickSwitchSpace9` switch space immediately without opening
the overlay and work with no active session, dismissing the overlay first if it
happens to be open. The direct-space modifier focuses the destination space's MRU
head. The separately configured same-app modifier prefers the destination space's
most recent window belonging to the app that was active before the switch, falling
back to that space's MRU head. Digit 0 has no quick-switch binding.

Quick switch defers only to user-configured frontmost app exclusions. AGENTS.md
records why its modifier combination must be tested before Cmd-state tracking and
why the frontmost bundle ID has to be read from cache.

### Space management

- `newSpaceBelow` and `newSpaceAbove` create an empty space relative to the
  selected one and select it immediately. Its label is its new position.
- `deleteSpace` and `deleteSpaceForward` delete the selected space. Its windows
  overflow into an adjacent space — below for the first space, otherwise above —
  and the active space follows the overflow. Deleting the only space creates a
  fresh empty one.
- `moveWindowUp` and `moveWindowDown` move the selected window to the adjacent
  space; the selection follows it, and the source space remains even if it
  empties.
Spaces cannot be renamed. Position numbers drive shortcuts but are not displayed
on stages.

Spaces cannot be reordered either. A space *is* the desktop at its index, so
reordering spaces means reordering desktops, and the Dock — not the window server —
owns that order: `SLSMoveManagedSpaceToDisplayIndex` moves a desktop instantly and
invisibly, but the Dock keeps navigating by its own stale copy, which breaks the
forged swipe that switches a space, and the new order is reverted at the next
reboot. A reorder that cannot be made either transparent or durable is worse than
no reorder at all.

## Pointer

A window preview can be dragged onto another stage to move that window between
spaces. Stages themselves are not draggable. The move emits a diagnostic event —
`window_moved_by_drag` — which the E2E suite asserts against. Virtualized and
GitHub-hosted macOS do not deliver synthetic drags; see docs/local-e2e.md.

## Not yet implemented

- Stages beyond the screen edges do not scroll into view when navigating to an
  off-screen space.
- Window previews carry no Dock-style notification badge counts.
