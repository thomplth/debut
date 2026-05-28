# System Behaviors

This document specifies how Debut manages the relationship between stages, windows, and apps at the system level — including isolation rules, transitive behaviors, persistence, and edge cases.

---

## App Switcher Isolation

- [x] Cmd+Tab quick tap: switch to most recently used app within active stage only ✅ verified
- [x] Cmd+Tab hold: open Stage Manager overlay ✅ verified
- [ ] Cmd+` cycles windows of frontmost app, only windows in active stage — NOT IMPLEMENTED
- [ ] Cmd+` excludes windows of the same app in other stages — NOT IMPLEMENTED
- [x] Isolation guarantee: no keyboard-driven switching crosses stage boundaries ✅ verified

---

## App-to-Stage Assignment

Model is app-based (StageApp by bundleID), not window-based.

- [x] Every running app belongs to at least one stage ✅ verified

### New app launch

- [x] App not currently running → assigned to active stage ✅ verified (via NSWorkspace.didLaunchApplication)

### App activated from another stage (Dock click, Spotlight, Cmd+H then show)

- [ ] App should be added to current stage as shared (appears in both stages) — **BUG: currently re-hidden by isolation enforcement. Fix: add to active stage instead of re-hiding**

### Shared apps

- [x] Shared app appears in multiple stages' plates ✅ verified (model supports isShared)
- [x] On stage switch, shared apps are NOT hidden — they remain on screen ✅ verified
- [ ] Removing app from a stage via drag-and-drop reduces sharing — needs drag-and-drop
- [x] Closing/quitting app removes it from all stages ✅ verified (via NSWorkspace.didTerminateApplication)

---

## Stage Switching

- [x] Hide all apps belonging exclusively to the previous stage ✅ verified
- [x] Show all apps belonging to the newly active stage ✅ verified
- [x] Shared apps remain visible (not hidden or shown) ✅ verified
- [x] Focus moves to selected app in new stage (or most recently used if none selected) ✅ verified
- [x] New active stage becomes reference for Cmd+Tab behavior ✅ verified

### Combined stage + app switch

- [x] Stage switches first (hide/show apps) ✅ verified
- [x] Then selected app in new stage receives focus ✅ verified

---

## MRU (Most Recently Used) Ordering

- [x] Apps in stage ordered by recency: index 0 = most recently focused ✅ verified
- [x] NSWorkspace.didActivateApplication triggers MRU update (only for apps in active stage) ✅ verified
- [x] Cmd+Tab tap switches to apps[1] (second most recent) ✅ verified
- [x] Overlay shows apps in MRU order ✅ verified
- [ ] **BUG: overlay opens with selectedAppIndex=0 (same app). Native behavior: initial selection = index 1. Fix: set selectedAppIndex = 1 on open**

---

## Persistence

Full persistence across app restarts and system reboots.

### What is persisted

- [x] Stage list and order ✅ verified (JSON via StateStore)
- [x] Stage names ✅ verified
- [x] App-to-stage assignments ✅ verified
- [ ] Window positions and sizes — NOT IMPLEMENTED (app-based model doesn't track windows)
- [x] Shared app associations ✅ verified
- [x] Templates ✅ verified
- [x] Settings / preferences ✅ verified

### Restore behavior on launch

- [x] Load saved stage state from disk ✅ verified
- [ ] Running apps with matching bundleIDs: reassign to saved stages — PARTIAL (only populates empty default stage)
- [ ] Not-yet-launched apps: mark as unavailable (dimmed icon) — NOT IMPLEMENTED
- [ ] As unavailable apps launch later, auto-capture into correct stage — NOT IMPLEMENTED

### Storage

- [x] Save to `~/Library/Application Support/Debut/state.json` ✅ verified
- [x] Write on app terminate ✅ verified
- [ ] Write on every stage mutation — NOT IMPLEMENTED (only saves on quit)
- [ ] Debounced writes for position updates — NOT APPLICABLE (no window positions)

---

## Stage Deletion

- [x] Step 1: apps overflow to adjacent stage ✅ verified
  - [x] First stage → overflow to stage below ✅ verified
  - [x] Any other position → overflow to stage above ✅ verified
- [x] Step 3: active stage moves to stage that received overflow ✅ verified
- [x] Step 4: if only stage deleted → create new empty default stage ✅ verified

---

## Stage Creation from Template

- [ ] New stage created with template's name — NOT IMPLEMENTED (save works, apply doesn't)
- [ ] Each app in template launched — NOT IMPLEMENTED
- [ ] Already-running app → shared — NOT IMPLEMENTED

---

## Edge Cases

- [x] First launch: create single default stage with all running apps ✅ verified
- [x] App quits: removed from all stages ✅ verified
- [x] App launched outside Debut's awareness → assigned to active stage ✅ verified
- [ ] Fullscreen apps: stage switching behavior — TBD
- [ ] Minimized windows remain in stage (dimmed icon in plate) — NOT APPLICABLE (app-based model)
