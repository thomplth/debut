# System Behaviors

This document specifies how Debut manages the relationship between stages, windows, and apps at the system level — including isolation rules, transitive behaviors, persistence, and edge cases.

---

## Window-Centric Model

Debut tracks individual **windows** (by CGWindowID), not apps. Each stage contains a list of StageWindow entries. A single app (e.g., Safari) can have windows in different stages.

- [x] Windows identified by CGWindowID (ephemeral) + ownerBundleID/windowTitle (stable for persistence)
- [x] Window list sourced from AX API (kAXWindowsAttribute) cross-referenced with CGWindowList
- [x] Real windows only — track non-modal `AXStandardWindow` elements; exclude dialogs, floating windows, `AXUnknown` popups, shadows, toolbars, and other auxiliary surfaces
- [x] Per-window AXObserver lifecycle tracking: kAXUIElementDestroyedNotification removes closed windows instantly
- [x] Per-window AXObserver title tracking: kAXTitleChangedNotification updates titles in real-time
- [x] One AXObserver per PID, shared across all that app's window notifications

---

## App Switcher Isolation

- [x] Cmd+Tab quick tap: switch to most recently used window within active stage only
- [x] Cmd+Tab hold: open Stage Manager overlay
- [x] Cmd+` passes through to system (native window cycling within app)
- [x] Isolation guarantee: no keyboard-driven switching crosses stage boundaries

---

## Window-to-Stage Assignment

- [x] Every tracked window belongs to exactly one stage (no sharing/duplication)

### New window created (Cmd+N, "code .", etc.)

- [x] New window assigned to active stage, even if same app has windows in other stages
- [x] Detected via kAXFocusedWindowChangedNotification (new window gets focus)

### Existing window activated from another stage (Dock, Spotlight)

- [x] Debut switches to the stage that owns that window
- [x] No duplication — window stays in its original stage

### Excluded apps

- [x] Excluded apps' windows are invisible to the stage manager
- [x] Configured in Settings with running app picker
- [x] Exclusion list persisted in settings.json
- [x] Changes take effect immediately (live update to discovery service)

### Quick switch exclusions

- [x] Configured apps keep their Ctrl+number shortcuts while frontmost
- [x] Exclusion list is persisted and applied immediately
- [x] Frontmost app is cached from activation events; quick switching performs no workspace or AX lookup

---

## Stage Switching via Desktop Surface

Debut uses a full-screen "desktop surface" window (OLED black, NSWindow.level.normal) positioned above stage windows in z-order. The selected destination window is then raised above the surface.

- [x] On switch: surface ordered to front, then only the selected destination window is raised above it via AX
- [x] All other stage windows remain at their positions — occluded by the surface
- [x] No minimize animation, no position manipulation
- [x] Surface locked: canBecomeKey=false, canBecomeMain=false, mouseDown no-op, isMovable=false
- [x] Focus moves to selected window in new stage
- [x] New active stage becomes reference for Cmd+Tab behavior

---

## MRU (Most Recently Used) Ordering

- [x] Windows in stage ordered by recency: index 0 = most recently focused
- [x] AXObserver (kAXFocusedWindowChangedNotification) tracks within-app focus changes — event-driven, no polling
- [x] NSWorkspace.didActivateApplicationNotification tracks cross-app activation
- [x] Observer moves to frontmost app on activation — one observer active at a time
- [x] Cmd+Tab tap switches to windows[1] (second most recent)
- [x] Overlay opens with selectedWindowIndex=1 (second MRU)

---

## Persistence

Full persistence across app restarts and system reboots.

### What is persisted

- [x] Stage list, order, and names
- [x] Window-to-stage assignments (by bundleID + windowTitle)
- [x] Templates (by app bundleIDs)
- [x] Settings / preferences (including appearance and exclusion list)
- [x] Active stage ID

### Restore behavior on launch

- [x] Load saved stage state from state.json
- [x] Reconcile: match persisted windows to live windows by (bundleID, windowTitle)
- [x] Fallback reconciliation: if title match fails, match by bundleID alone (handles dynamic titles like terminals, browsers, Slack)
- [x] Update ephemeral CGWindowIDs, PIDs, and window titles to current values
- [x] Remove windows that no longer exist (app was quit between sessions)
- [x] Remove empty stages after reconciliation (keep at least one)
- [x] Add new live windows (not in snapshot) to first stage
- [x] Excluded apps filtered during reconciliation
- [x] Activate stage containing currently focused window on launch (fall back to first stage)

### Storage

- [x] Save to `~/Library/Application Support/Debut/state.json`
- [x] Write on app terminate
- [ ] Write on every stage mutation (currently only on quit)

---

## Stage Deletion

- [x] Windows overflow to adjacent stage (first stage -> below, otherwise -> above)
- [x] Active stage moves to stage that received overflow
- [x] If only stage deleted -> create new empty default stage

---

## Fullscreen Apps

- [x] Overlay not shown when frontmost app is in fullscreen (AXFullScreen check)
- [x] Cmd+Tab passes through to system in fullscreen mode
- [x] Desktop surface does not follow into fullscreen Spaces (no .canJoinAllSpaces)

---

## Edge Cases

- [x] First launch: create single default stage with all running windows
- [x] App quits: all its windows removed from all stages (per-app observer cleaned up)
- [x] Window closed (Cmd+W, red button): removed from stage instantly via kAXUIElementDestroyedNotification
- [x] Window title changes (cd, tab switch, save): updated in real-time via kAXTitleChangedNotification
- [x] Window created outside Debut's awareness -> added to active stage on focus, lifecycle tracking registered
- [x] System Cmd+` restored — Debut does not intercept backtick
