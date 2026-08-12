# System Behaviors

How Debut relates stages, windows, and apps: assignment rules, isolation,
persistence, and reconciliation. The architecture constraints explaining *why*
these rules exist are in AGENTS.md.

## Window-centric model

Debut tracks individual windows, not apps. A stage holds `StageWindow` entries,
so one app can own windows in several stages at once.

A window is identified at runtime by its `CGWindowID` and persisted by
(`ownerBundleID`, `windowTitle`); CGWindowIDs are ephemeral and are never written
to disk. The window list comes from the AX API cross-referenced with
`CGWindowList`.

Only real windows are tracked — non-modal `AXStandardWindow` elements. Dialogs,
floating windows, `AXUnknown` popups, shadows, toolbars, and other auxiliary
surfaces are excluded.

Each PID gets one AXObserver, shared across that app's window notifications.
Windows are removed on `kAXUIElementDestroyedNotification` and titles refresh on
`kAXTitleChangedNotification`.

## App switcher isolation

Tapping the activation shortcut switches to the most recently used window inside
the active stage only, showing no UI. Holding presents the overlay.

Debut also handles Cmd+\` (the default binding for `nextAppWindow`), cycling the
current app's windows *within the active stage* rather than deferring to the
system.

The guarantee: no keyboard-driven switching crosses a stage boundary.

## Window-to-stage assignment

Every tracked window belongs to exactly one stage. There is no sharing or
duplication.

**A newly created window** (Cmd+N, `code .`) joins the active stage even when the
same app already has windows elsewhere, detected through
`kAXFocusedWindowChangedNotification`.

**An existing window activated from another stage** (Dock, Spotlight) makes Debut
switch to the stage that already owns it. The window itself does not move.

**Excluded apps** are invisible to the stage manager. The list is configured in
Settings from a running-app picker, persisted, and applied immediately. It must
filter at every layer — discovery, launch, activation, reconciliation, and the
AXObserver.

**Quick-switch exclusions** let configured apps keep their own number shortcuts
while frontmost. The frontmost bundle ID is cached from activation notifications,
so quick switching performs no workspace or AX lookup.

## Stage switching

Debut owns a full-screen desktop surface window at `.normal` level, sitting in
z-order between active and inactive stage windows.

A switch orders that surface to the front, then raises the active stage's windows
above it through AX. Inactive windows keep their positions and are simply
occluded — no minimize animation, no position manipulation. Focus moves to the
selected window, and the new stage becomes the reference for later switching.

The surface is inert: it cannot become key or main, ignores mouse-down, and is
not movable.

## MRU ordering

Windows within a stage are ordered by recency, index 0 being most recently
focused.

Ordering is maintained event-driven, never by polling.
`kAXFocusedWindowChangedNotification` tracks focus changes inside an app and
`NSWorkspace.didActivateApplicationNotification` tracks cross-app activation. One
observer is active at a time and moves to the frontmost app on activation.

## Persistence

State survives app restarts and reboots.

Persisted: the stage list and its order, window-to-stage assignments (by bundle
ID and title), settings, and the active stage ID. Stages have no name to persist.

Writes are debounced through `DebouncedSaver` on stage mutation and flushed
synchronously on terminate.

### Restore

On launch Debut loads `state.json` and reconciles persisted windows against live
ones by (bundleID, windowTitle). When an exact title match fails it falls back to
bundleID alone, because titles are not stable keys — terminal prompts, browser
tabs, and Slack channels all change between sessions. Ephemeral CGWindowIDs,
PIDs, and titles are refreshed to current values.

Live windows absent from the snapshot join the first stage, and excluded apps are
filtered out during reconciliation. Empty stages are pruned except those holding
dormant assignments, and at least one stage always remains.

Debut then activates the stage owning the currently focused window, falling back
to the first stage.

### Dormancy

When an app exits, its windows leave the live stage view but their stage and
position persist as dormant assignments. A later launch reclaims them by exact
bundle and title match, then by complete one-to-one bundle matching for apps with
dynamic titles.

Dormant assignments have no time-based expiry and survive deliberate quits and
updater relaunches alike, because macOS does not reliably distinguish those
termination reasons. They are purged only by explicit window destruction,
exclusion or reset, or stage deletion.

Absence from an AX or `CGWindowList` snapshot never removes an assignment —
hidden and ordered-out windows drop out of those snapshots routinely. Only a
lifecycle event does.

## Fullscreen apps

The overlay is not shown while the frontmost app is fullscreen, and the
activation shortcut passes through to the system. The desktop surface must not
join all Spaces, or it would follow into the fullscreen Space and cover the app.

## Edge cases

- First launch creates a single stage containing every running window.
- A window closed with Cmd+W or the red button leaves its stage immediately.
- A title change from `cd`, a tab switch, or a save updates in place.
- A window created outside Debut's awareness joins the active stage on focus and
  gains lifecycle tracking at that point. All three discovery paths — startup
  reconciliation, app launch, and focus change — must register tracking, or the
  window becomes a ghost.
- Hidden apps keep their ordered-out assignments until their windows return.

Stage deletion and its overflow rules are specified in
[stage-manager.md](stage-manager.md).
