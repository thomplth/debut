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

- [x] Plates stacked vertically, each plate is a horizontal row of app icons ✅ verified
- [x] Plate styled with liquid glass (macOS 26) / ultraThinMaterial (fallback) ✅ verified
- [x] Active plate vertically centered on screen ✅ verified
- [x] Other plates positioned above/below active plate in stage order ✅ verified
- [x] Stage name displayed in top-left corner of each plate ✅ verified
- [x] Selection indicator highlights the currently selected app icon ✅ verified
- [ ] Overflow: plates beyond screen edges scroll when navigating to off-screen stage
- [ ] Icon size adaptive to screen width, shrinks as plate approaches screen edge
- [ ] Badge counts preserved on app icons (matching Dock badges)
- [ ] No full-screen overlay — plates float directly on desktop (no backdrop blur) ✅ verified

---

## Activation and Dismissal

- [x] Cmd+Tab quick tap: switch to last-used app within active stage (Stage Manager NOT shown) ✅ verified — **BUG: after first commit, subsequent taps don't switch. Root cause: selection starts at index 0 (same app). Fix: start at index 1**
- [x] Cmd+Tab hold Cmd: show Stage Manager overlay with active stage centered, last-used app pre-selected ✅ verified
- [x] Release Cmd: commit current selection and hide Stage Manager ✅ verified
- [x] Esc: discard selection, hide Stage Manager with no changes ✅ verified

---

## Navigation (while Cmd is held)

All navigation wraps cyclically — reaching the end loops back to the start.

### Within a plate (horizontal — app selection)

- [x] Tab: select next app (move right), wraps to first after last ✅ verified
- [x] Shift+Tab: select previous app (move left), wraps to last after first ✅ verified

### Across plates (vertical — stage selection)

- [x] Option+Tab: select next stage (move down), wraps to first after last ✅ verified
- [x] Shift+Option+Tab: select previous stage (move up), wraps to last after first ✅ verified
- [x] 1–9: jump directly to stage at that index position ✅ verified
- [x] When changing stages, selection defaults to first (most recently used) app in that stage ✅ verified

---

## Stage Management (while Cmd is held)

### Create

- [x] N: create new empty stage below currently selected stage ✅ verified
- [x] Shift+N: create new empty stage above currently selected stage ✅ verified
- [x] New stages receive a default name (e.g., "Stage 4") and are immediately selected ✅ verified

### Delete

- [x] Delete key: delete currently selected stage ✅ verified
- [x] Apps overflow to adjacent stage (first stage → below, otherwise → above) ✅ verified
- [x] Active stage moves to stage that received overflow ✅ verified
- [x] If only stage, create new empty default stage ✅ verified

### Rename

- [x] R: enter inline rename mode for currently selected stage ✅ verified
- [ ] Stage name label becomes editable text field, pre-filled with current name (text fully selected) — **BUG: no TextField rendered, keypresses not captured**
- [x] Enter: commit new name and exit rename mode ✅ verified (event routing)
- [x] Esc: discard changes and exit rename mode ✅ verified (event routing)
- [x] Manager locked during rename — Cmd release does NOT dismiss ✅ verified

### Save as Template

- [x] Space: save currently selected stage's app list as a new template ✅ verified
- [ ] Opens naming prompt (defaults to stage name) — currently saves silently

---

## Reordering

### Move an app between stages

- [x] Arrow Up: move selected app to stage above ✅ verified
- [x] Arrow Down: move selected app to stage below ✅ verified
- [x] Source stage remains even if it becomes empty (not auto-deleted) ✅ verified

### Swap stage position

- [x] Option+Arrow Up: swap selected stage's position with stage above ✅ verified
- [x] Option+Arrow Down: swap selected stage's position with stage below ✅ verified
- [x] Stage index numbers (1–9) update to reflect new order ✅ verified

### Mouse drag and drop

- [ ] Drag app icon → drop onto another stage's plate to move app
- [ ] Drag stage plate → reorder within vertical stack

---

## Summary: All Keyboard Shortcuts

| Shortcut | Context | Action | Status |
|---|---|---|---|
| Cmd+Tab (tap) | Global | Switch to last-used app in active stage | [x] ✅ |
| Cmd+Tab (hold) | Global | Open Stage Manager | [x] ✅ |
| Tab | Stage Manager | Next app (right) | [x] ✅ |
| Shift+Tab | Stage Manager | Previous app (left) | [x] ✅ |
| Option+Tab | Stage Manager | Next stage (down) | [x] ✅ |
| Shift+Option+Tab | Stage Manager | Previous stage (up) | [x] ✅ |
| 1–9 | Stage Manager | Jump to stage by index | [x] ✅ |
| N | Stage Manager | New stage below | [x] ✅ |
| Shift+N | Stage Manager | New stage above | [x] ✅ |
| Delete | Stage Manager | Delete selected stage | [x] ✅ |
| R | Stage Manager | Rename selected stage | [~] partial — locks manager but no text field |
| Space | Stage Manager | Save stage as template | [x] ✅ |
| Arrow Up/Down | Stage Manager | Move selected app to stage above/below | [x] ✅ |
| Option+Arrow Up/Down | Stage Manager | Swap stage position with neighbor | [x] ✅ |
| Enter | Rename mode | Commit rename | [x] ✅ (event routing) |
| Esc | Rename mode | Cancel rename | [x] ✅ (event routing) |
| Esc | Stage Manager | Discard selection, close overlay | [x] ✅ |
| Release Cmd | Stage Manager | Commit selection, close overlay | [x] ✅ |
