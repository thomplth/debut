# Stage Manager

The Stage Manager is a system-wide overlay that replaces the native macOS app switcher. It displays all stages as vertically stacked plates and supports full keyboard and mouse interaction for navigating, managing, and reorganizing stages and their windows.

---

## Visual Design

### Layout

```
┌─────────────────────────────────────────────────┐
│                                                 │
│  ┌─ Email ────────────────────────────────────┐ │
│  │  [Mail]  [Slack]  [Calendar]               │ │
│  └────────────────────────────────────────────┘ │
│                                                 │
│  ┌─ Coding ──────────────────────────── ● ────┐ │
│  │  [VS Code]  [Terminal]  [Safari]  [Notion] │ │
│  └────────────────────────────────────────────┘ │
│                                                 │
│  ┌─ Code Review ──────────────────────────────┐ │
│  │  [GitHub]  [VS Code]  [Slack]              │ │
│  └────────────────────────────────────────────┘ │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Implementation Checklist

- [ ] Plates stacked vertically, each plate is a horizontal row of app icons
- [ ] Plate styled like native macOS Cmd+Tab switcher (rounded-rect translucent background, large app icons)
- [ ] Active plate vertically centered on screen
- [ ] Other plates positioned above/below active plate in stage order
- [ ] Stage name displayed in top-left corner of each plate
- [ ] Selection indicator highlights the currently selected app icon
- [ ] Overflow: plates beyond screen edges scroll when navigating to off-screen stage
- [ ] Full-screen dimmed/blurred backdrop behind plate stack
- [ ] Badge counts preserved on app icons (matching Dock badges)

### Plate Anatomy

```
┌─ Stage Name ──────────────────────────────────┐
│                                               │
│  [ icon ]  [ icon ]  [ icon ]  [ icon ]       │
│            ────────                            │
│            selected                            │
└───────────────────────────────────────────────┘
```

---

## Activation and Dismissal

- [ ] Cmd+Tab quick tap: switch to last-used app within active stage (Stage Manager NOT shown)
- [ ] Cmd+Tab hold Cmd: show Stage Manager overlay with active stage centered, last-used app pre-selected
- [ ] Release Cmd: commit current selection and hide Stage Manager (apply stage switch and/or app focus)
- [ ] Esc: discard selection, hide Stage Manager with no changes

---

## Navigation (while Cmd is held)

All navigation wraps cyclically — reaching the end loops back to the start.

### Within a plate (horizontal — app selection)

- [ ] Tab: select next app (move right), wraps to first after last
- [ ] Shift+Tab: select previous app (move left), wraps to last after first

### Across plates (vertical — stage selection)

- [ ] Option+Tab: select next stage (move down), wraps to first after last
- [ ] Shift+Option+Tab: select previous stage (move up), wraps to last after first
- [ ] 1–9: jump directly to stage at that index position
- [ ] When changing stages, selection defaults to first (most recently used) app in that stage

---

## Stage Management (while Cmd is held)

### Create

- [ ] N: create new empty stage below currently selected stage
- [ ] Shift+N: create new empty stage above currently selected stage
- [ ] New stages receive a default name (e.g., "Stage 4") and are immediately selected

### Delete

- [ ] Delete key: delete currently selected stage
- [ ] Attempt to close all windows belonging to the stage
- [ ] Unclosable windows overflow to adjacent stage (first stage → below, otherwise → above)
- [ ] Active stage moves to stage that received overflow windows
- [ ] If only stage, create new empty default stage

### Rename

- [ ] R: enter inline rename mode for currently selected stage
- [ ] Stage name label becomes editable text field, pre-filled with current name (text fully selected)
- [ ] Enter: commit new name and exit rename mode
- [ ] Esc: discard changes and exit rename mode
- [ ] All keypresses captured by text field — no propagation to Stage Manager shortcuts

### Save as Template

- [ ] Space: save currently selected stage's app list as a new template
- [ ] Opens naming prompt (defaults to stage name)
- [ ] Template captures only app list — not window positions or sizes

---

## Reordering

### Move an app between stages

- [ ] Arrow Up: move selected app to stage above
- [ ] Arrow Down: move selected app to stage below
- [ ] Source stage remains even if it becomes empty (not auto-deleted)

### Swap stage position

- [ ] Option+Arrow Up: swap selected stage's position with stage above
- [ ] Option+Arrow Down: swap selected stage's position with stage below
- [ ] Stage index numbers (1–9) update to reflect new order

### Mouse drag and drop

- [ ] Drag app icon → drop onto another stage's plate to move app
- [ ] Drag stage plate → reorder within vertical stack

---

## Summary: All Keyboard Shortcuts

| Shortcut | Context | Action | Status |
|---|---|---|---|
| Cmd+Tab (tap) | Global | Switch to last-used app in active stage | [ ] |
| Cmd+Tab (hold) | Global | Open Stage Manager | [ ] |
| Tab | Stage Manager | Next app (right) | [ ] |
| Shift+Tab | Stage Manager | Previous app (left) | [ ] |
| Option+Tab | Stage Manager | Next stage (down) | [ ] |
| Shift+Option+Tab | Stage Manager | Previous stage (up) | [ ] |
| 1–9 | Stage Manager | Jump to stage by index | [ ] |
| N | Stage Manager | New stage below | [ ] |
| Shift+N | Stage Manager | New stage above | [ ] |
| Delete | Stage Manager | Delete selected stage | [ ] |
| R | Stage Manager | Rename selected stage | [ ] |
| Space | Stage Manager | Save stage as template | [ ] |
| Arrow Up/Down | Stage Manager | Move selected app to stage above/below | [ ] |
| Option+Arrow Up/Down | Stage Manager | Swap stage position with neighbor | [ ] |
| Enter | Rename mode | Commit rename | [ ] |
| Esc | Rename mode | Cancel rename | [ ] |
| Esc | Stage Manager | Discard selection, close overlay | [ ] |
| Release Cmd | Stage Manager | Commit selection, close overlay | [ ] |
