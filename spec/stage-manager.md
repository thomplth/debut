# Stage Manager

A system-wide overlay that replaces the native macOS app switcher. It shows every
stage as a vertically stacked plate of window previews and supports keyboard and
pointer interaction for navigating and reorganizing stages and their windows.

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
top-left and captioned with its window title. Plates carry no title. The active
plate is vertically centered at full scale; inactive plates render at a smaller
configurable scale.

Plates float directly on the desktop — there is no full-screen backdrop or
backdrop blur. Previews are captured when the overlay opens and cached for
windows that are hidden. Icon size adapts to screen width, and preview content
uses equal top and bottom padding. The selection highlight wraps both thumbnail
and title.

Stage focus changes animate as a low-bounce vertical spring with a subtle lift on
the active plate. Reduce Motion substitutes a short fade.

Appearance values (scale, corner radius, selection fill and border) are
user-configurable; see `AppSettings`.

## Shortcuts

Every shortcut is user-configurable, so this document deliberately does not list
key bindings. The authoritative set of actions is the `KeyAction` enum in
`Sources/DebutCore/Models/KeyBinding.swift`; shipped defaults live in
`KeyBindings`. What follows is the behavior behind each action group, which the
enum cannot express.

Global activation shortcuts define the modifier held for the session. Stage
Manager shortcuts are recorded relative to that held modifier.

### Session model

Tapping the activation shortcut — releasing before the configurable presentation
delay — switches to the most recently used window in the active stage without
showing the overlay. Holding past that delay presents the overlay.

The held-modifier session and overlay visibility are separate states.
`dismissOverlay` closes the overlay but leaves the session alive, so a further
navigation keypress reopens it. Releasing the modifier commits the current
selection and ends the session.

The overlay is suppressed entirely while the frontmost app is fullscreen.

### Navigation

All navigation wraps cyclically.

- `nextWindow`, `previousWindow`, and `previousWindowAlternate` move the
  selection horizontally within the active plate.
- `nextStage` and `previousStage` move vertically across plates. Changing stage
  resets the selection to that stage's most recently used window.
- `jumpToStage1`–`jumpToStage9` select a stage by position within the open
  overlay. The ninth targets the *last* stage rather than literally stage 9.
- `nextAppWindow` and `previousAppWindow` cycle the windows of the current app.
- The overlay opens with the second most recently used window preselected, so a
  single activation lands on the previous window.

### Quick switch

`quickSwitchStage1`–`quickSwitchStage9` switch stage immediately without opening
the overlay and work with no active session, dismissing the overlay first if it
happens to be open. The direct-stage modifier focuses the destination stage's MRU
head. The separately configured same-app modifier prefers the destination stage's
most recent window belonging to the app that was active before the switch, falling
back to that stage's MRU head. Digit 0 has no quick-switch binding.

Quick switch defers only to user-configured frontmost app exclusions. AGENTS.md
records why its modifier combination must be tested before Cmd-state tracking and
why the frontmost bundle ID has to be read from cache.

### Stage management

- `newStageBelow` and `newStageAbove` create an empty stage relative to the
  selected one and select it immediately. Its label is its new position.
- `deleteStage` and `deleteStageForward` delete the selected stage. Its windows
  overflow into an adjacent stage — below for the first stage, otherwise above —
  and the active stage follows the overflow. Deleting the only stage creates a
  fresh empty one.
- `moveWindowUp` and `moveWindowDown` move the selected window to the adjacent
  stage; the selection follows it, and the source stage remains even if it
  empties.
- `swapStageUp` and `swapStageDown` exchange the selected stage's position with
  its neighbor.

Stages cannot be renamed. Position numbers drive shortcuts but are not displayed
on plates.

## Pointer

A window preview can be dragged onto another plate to move that window between
stages, and a plate's handle can be dragged to reorder stages within the stack.
Both paths emit diagnostic events — `window_moved_by_drag` and
`stage_reordered_by_drag` — which the E2E suite asserts against. Virtualized and
GitHub-hosted macOS do not deliver synthetic drags; see docs/local-e2e.md.

## Not yet implemented

- Plates beyond the screen edges do not scroll into view when navigating to an
  off-screen stage.
- Window previews carry no Dock-style notification badge counts.
