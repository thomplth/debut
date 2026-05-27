# System Behaviors

This document specifies how Debut manages the relationship between stages, windows, and apps at the system level — including isolation rules, transitive behaviors, persistence, and edge cases.

---

## App Switcher Isolation

- [ ] Cmd+Tab quick tap: switch to most recently used app within active stage only
- [ ] Cmd+Tab hold: open Stage Manager overlay
- [ ] Cmd+` cycles windows of frontmost app, only windows in active stage
- [ ] Cmd+` excludes windows of the same app in other stages
- [ ] Isolation guarantee: no keyboard-driven switching crosses stage boundaries

---

## Window-to-Stage Assignment

- [ ] Every visible window belongs to exactly one stage (except shared windows)

### New app launch

- [ ] App not currently running → window assigned to active stage

### Already-running app: multi-window capable

- [ ] New window created in active stage
- [ ] Existing windows in other stages remain unaffected
- [ ] Each window independently assigned to its stage

### Already-running app: single-window only

- [ ] App becomes a shared window — appears in both stages' plates
- [ ] Same window shown when either stage is active
- [ ] App icon appears in both stages' plates in Stage Manager
- [ ] Cmd+Tab in either stage includes this app as candidate

### Shared windows

- [ ] Window visible whenever any of its assigned stages is active
- [ ] On stage switch, shared windows are NOT hidden — they remain on screen
- [ ] Removing app from a stage via drag-and-drop reduces sharing
- [ ] Removing from all but one stage → normal single-stage window
- [ ] Closing the window removes it from all stages

---

## Stage Switching

- [ ] Hide all windows belonging exclusively to the previous stage
- [ ] Show all windows belonging to the newly active stage
- [ ] Shared windows remain visible (not hidden or shown)
- [ ] Focus moves to selected app in new stage (or most recently used if none selected)
- [ ] New active stage becomes reference for Cmd+Tab / Cmd+` behavior

### Combined stage + app switch

- [ ] Stage switches first (hide/show windows)
- [ ] Then selected app in new stage receives focus

---

## Persistence

Full persistence across app restarts and system reboots.

### What is persisted

- [ ] Stage list and order
- [ ] Stage names
- [ ] Window-to-stage assignments
- [ ] Window positions and sizes
- [ ] Shared window associations
- [ ] Templates
- [ ] Settings / preferences

### Restore behavior on launch

- [ ] Load saved stage state from disk
- [ ] Running apps with matching windows: reassign to saved stages, restore positions
- [ ] Running apps with new windows: assign to active stage
- [ ] Not-yet-launched apps: mark as unavailable (dimmed icon)
- [ ] As unavailable apps launch later, auto-capture into correct stage
- [ ] User can clean up unavailable entries

### Storage

- [ ] Save to `~/Library/Application Support/Debut/state.json`
- [ ] Write on every stage mutation (create, delete, rename, reorder)
- [ ] Write on every window assignment change
- [ ] Debounced writes for window position updates (every 5 seconds after last change)

---

## Stage Deletion

- [ ] Step 1: attempt to close all windows belonging to the stage
- [ ] Step 2: unclosable windows overflow to adjacent stage
  - [ ] First stage → overflow to stage below
  - [ ] Any other position → overflow to stage above
- [ ] Step 3: active stage moves to stage that received overflow
- [ ] Step 4: if only stage deleted → create new empty default stage

---

## Stage Creation from Template

- [ ] New stage created with template's name (numbered variant if name exists)
- [ ] Each app in template launched (if not already running)
- [ ] New windows assigned to new stage
- [ ] Already-running multi-window app → new window in new stage
- [ ] Already-running single-window app → shared window

---

## Edge Cases

- [ ] First launch: create single default stage with all open windows
- [ ] App quits: windows removed from stage, icon removed from plate
- [ ] Shared window app quits: removed from all stages
- [ ] App launched outside Debut's awareness → assigned to active stage
- [ ] Fullscreen apps follow same stage assignment rules
- [ ] Fullscreen windows on stage switch: handle per macOS API constraints (TBD)
- [ ] Minimized windows remain in stage (dimmed icon in plate)
- [ ] Cmd+Tab selection of minimized window un-minimizes it
