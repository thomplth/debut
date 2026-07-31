# Stage Manager

The Stage Manager is a system-wide overlay that replaces the native macOS app switcher. It displays all stages as vertically stacked plates showing **window previews** (not app icons) and supports full keyboard interaction for navigating, managing, and reorganizing stages and their windows.

---

## Visual Design

### Layout

```
┌─────────────────────────────────────────────────┐
│                                                 │
│  ┌─ Email ────────────────────────────────────┐ │  ← 0.8x scale, inactive
│  │  [🪟 Mail]  [🪟 Slack]  [🪟 Calendar]     │ │
│  └────────────────────────────────────────────┘ │
│                                                 │
│  ┌─ Coding ───────────────────────────────────┐ │  ← 1.0x scale, active
│  │  [🪟 VSCode]  [🪟 Terminal]  [🪟 Safari]  │ │
│  └────────────────────────────────────────────┘ │
│                                                 │
│  ┌─ Review ───────────────────────────────────┐ │  ← 0.8x scale, inactive
│  │  [🪟 GitHub]  [🪟 VSCode]                  │ │
│  └────────────────────────────────────────────┘ │
│                                                 │
└─────────────────────────────────────────────────┘
```

Each window item shows:
- Window screenshot preview (thumbnail, aspect-fit)
- App icon badge (top-left corner, 40pt)
- Window title (always visible below preview)

### Implementation Checklist

- [x] Plates stacked vertically, each plate is a horizontal row of window previews
- [x] Plate styled with liquid glass (.clear or .regular, configurable in Settings)
- [x] Active plate vertically centered on screen at 1.0x scale
- [x] Inactive plates at configurable scale (default 0.8x)
- [x] Stage position number (1-based) displayed in top-left corner of each plate
- [x] Selection highlight wraps thumbnail + title with configurable opacity
- [x] Window previews captured on overlay open, cached for hidden windows
- [x] Icon size adaptive to screen width
- [ ] Overflow: plates beyond screen edges scroll when navigating to off-screen stage
- [ ] Badge counts preserved on app icons (matching Dock badges)
- [x] No full-screen overlay — plates float directly on desktop (no backdrop blur)

---

## Activation and Dismissal

- [x] Cmd+Tab quick tap: switch to last-used window within active stage (Stage Manager NOT shown)
- [x] Cmd+Tab hold Cmd: show Stage Manager overlay with active stage centered, second MRU window pre-selected
- [x] Cmd+Shift+Tab hold: show overlay with last window pre-selected
- [x] Cmd+Option+Tab hold: show overlay with next stage pre-selected
- [x] Cmd+Shift+Option+Tab hold: show overlay with previous stage pre-selected
- [x] Release Cmd: commit current selection and hide Stage Manager
- [x] Esc: close overlay but keep session alive (Cmd still held = can reopen with Tab/Option+Tab)
- [x] Overlay not shown in fullscreen mode (AXFullScreen detection)

---

## Navigation (while Cmd is held)

All navigation wraps cyclically. Session persists until Cmd is released. Esc closes overlay but Tab/Option+Tab can reopen it.

### Within a plate (horizontal — window selection)

- [x] Tab: select next window (move right), wraps to first after last
- [x] Shift+Tab: select previous window (move left), wraps to last after first
- [x] ` (backtick): acts as previous window (Shift+Tab) while overlay is open

### Across plates (vertical — stage selection)

- [x] Option+Tab: select next stage (move down), wraps to first after last
- [x] Shift+Option+Tab: select previous stage (move up), wraps to last after first
- [x] 1-9: jump directly to stage at that index position (selection only, within open overlay)
- [x] When changing stages, selection defaults to first (most recently used) window in that stage

### After Esc (overlay closed, Cmd still held)

- [x] Tab / Option+Tab: reopens overlay
- [x] ` (backtick): passes through to system (Cmd+` native window cycling)

### Quick switch (global, no overlay)

- [x] Ctrl+0-9: immediately switch to the stage at that position without opening the overlay; 0 targets stage 10 and a matching app window is preferred
- [x] Works without a Cmd session; dismisses the overlay first if it happens to be open
- [x] Requires Ctrl without Command, Option, or Shift, so it never collides with other shortcuts
- [x] Defers only to user-configured frontmost app exclusions

---

## Stage Management (while Cmd is held)

### Create

- [x] N: create new empty stage below currently selected stage
- [x] Shift+N: create new empty stage above currently selected stage
- [x] New stages are immediately selected; their label is their position number

### Delete

- [x] Delete key: delete currently selected stage
- [x] Windows overflow to adjacent stage (first stage -> below, otherwise -> above)
- [x] Active stage moves to stage that received overflow
- [x] If only stage, create new empty default stage

### Naming

- [x] Stages are not nameable — each plate's label is hardcoded to its 1-based position
- [x] Labels update automatically when stages are created, deleted, or reordered

### Save as Template

- [x] Space: save currently selected stage's app list as a new template
- [ ] Opens naming prompt — currently saves silently with the stage's position label

---

## Reordering

### Move a window between stages

- [x] Arrow Up: move selected window to stage above
- [x] Arrow Down: move selected window to stage below
- [x] Selection follows the moved window to the target stage
- [x] Source stage remains even if it becomes empty

### Swap stage position

- [x] Option+Arrow Up: swap selected stage's position with stage above
- [x] Option+Arrow Down: swap selected stage's position with stage below

### Mouse drag and drop

- [ ] Drag window preview -> drop onto another stage's plate to move window
- [ ] Drag stage plate -> reorder within vertical stack

---

## Summary: All Keyboard Shortcuts

| Shortcut | Context | Action | Status |
|---|---|---|---|
| Cmd+Tab (tap) | Global | Switch to last-used window in active stage | [x] |
| Cmd+Tab (hold) | Global | Open Stage Manager (next window selected) | [x] |
| Cmd+Shift+Tab (hold) | Global | Open Stage Manager (last window selected) | [x] |
| Cmd+Option+Tab (hold) | Global | Open Stage Manager (next stage selected) | [x] |
| Cmd+Shift+Option+Tab (hold) | Global | Open Stage Manager (previous stage selected) | [x] |
| Ctrl+0-9 | Global | Quick switch to stage at that position (0 targets stage 10; no overlay) | [x] |
| Tab | Stage Manager | Next window (right) | [x] |
| Shift+Tab | Stage Manager | Previous window (left) | [x] |
| ` (backtick) | Stage Manager | Previous window (same as Shift+Tab) | [x] |
| Option+Tab | Stage Manager | Next stage (down) | [x] |
| Shift+Option+Tab | Stage Manager | Previous stage (up) | [x] |
| 1-9 | Stage Manager | Jump to stage by index (selection within overlay) | [x] |
| N | Stage Manager | New stage below | [x] |
| Shift+N | Stage Manager | New stage above | [x] |
| Delete | Stage Manager | Delete selected stage | [x] |
| Space | Stage Manager | Save stage as template | [x] |
| Arrow Up/Down | Stage Manager | Move selected window to stage above/below | [x] |
| Option+Arrow Up/Down | Stage Manager | Swap stage position with neighbor | [x] |
| Esc | Stage Manager | Close overlay (session continues) | [x] |
| Release Cmd | Stage Manager | Commit selection, close overlay | [x] |
