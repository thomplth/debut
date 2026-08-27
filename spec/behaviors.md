# System Behaviors

How Debut relates spaces, windows, and apps: assignment rules, isolation,
persistence, and reconciliation. The architecture constraints explaining *why*
these rules exist are in AGENTS.md.

## Window-centric model

Debut tracks individual windows, not apps. A space holds `SpaceWindow` entries,
so one app can own windows in several spaces at once.

A window is identified at runtime by its `CGWindowID` and persisted by
(`ownerBundleID`, `windowTitle`); CGWindowIDs are ephemeral and are never written
to disk. The window list comes from the AX API cross-referenced with
`CGWindowList`.

Only real windows are tracked — non-modal `AXStandardWindow` and `AXDialog`
elements. Modal dialogs, floating windows, `AXUnknown` popups, shadows, toolbars,
and other auxiliary surfaces are excluded.

Each PID gets one AXObserver, shared across that app's window notifications.
Windows are removed on `kAXUIElementDestroyedNotification` and titles refresh on
`kAXTitleChangedNotification`.

## App switcher isolation

Tapping the activation shortcut switches to the most recently used window inside
the active space only, showing no UI. Holding presents the overlay.

Debut also handles Cmd+\` (the default binding for `nextAppWindow`), cycling the
current app's windows *within the active space* rather than deferring to the
system.

The guarantee: no keyboard-driven switching crosses a space boundary.

## Window-to-space assignment

Every tracked window belongs to exactly one space. There is no sharing or
duplication.

**A newly created window** (Cmd+N, `code .`) joins the active space even when the
same app already has windows elsewhere, detected through
`kAXFocusedWindowChangedNotification`.

**An existing window activated from another space** (Dock, Spotlight) makes Debut
switch to the space that already owns it. The window itself does not move.

**Excluded apps** are invisible to the space manager. The list is configured in
Settings from a running-app picker, persisted, and applied immediately. It must
filter at every layer — discovery, launch, activation, reconciliation, and the
AXObserver.

**Quick-switch exclusions** let configured apps keep their own number shortcuts
while frontmost. The frontmost bundle ID is cached from activation notifications,
so quick switching performs no workspace or AX lookup.

## Space switching

Debut owns a full-screen desktop surface window at `.normal` level, sitting in
z-order between active and inactive space windows.

A switch orders that surface to the front, then raises the active space's windows
above it through AX. Inactive windows keep their positions and are simply
occluded — no minimize animation, no position manipulation. Focus moves to the
selected window, and the new space becomes the reference for later switching.

The surface cannot become key or main, ignores mouse-down, and is not movable.
When a file URL drag enters it, Debut yields the surface and other applications
so Finder's real desktop becomes the drop destination while the drag is still active.

## MRU ordering

Windows within a space are ordered by recency, index 0 being most recently
focused.

Ordering is maintained event-driven, never by polling.
`kAXFocusedWindowChangedNotification` tracks focus changes inside an app and
`NSWorkspace.didActivateApplicationNotification` tracks cross-app activation. One
observer is active at a time and moves to the frontmost app on activation.

## Persistence

State survives app restarts and reboots.

Persisted: the space list and its order, window-to-space assignments (by bundle
ID and title), settings, and the active space ID. Spaces have no name to persist.

Writes are debounced through `DebouncedSaver` on space mutation and flushed
synchronously on terminate.

### Restore

On launch Debut loads `state.json` and reconciles persisted windows against live
ones by (bundleID, windowTitle). When an exact title match fails it falls back to
bundleID alone, because titles are not stable keys — terminal prompts, browser
tabs, and Slack channels all change between sessions. Ephemeral CGWindowIDs,
PIDs, and titles are refreshed to current values.

Live windows absent from the snapshot join the first space, and excluded apps are
filtered out during reconciliation. Empty spaces are pruned except those holding
dormant assignments, and at least one space always remains.

Debut then activates the space owning the currently focused window, falling back
to the first space.

### Dormancy

When an app exits, its windows leave the live space view but their space and
position persist as dormant assignments. A later launch reclaims them by exact
bundle and title match, then by complete one-to-one bundle matching for apps with
dynamic titles.

Dormant assignments have no time-based expiry and survive deliberate quits and
updater relaunches alike, because macOS does not reliably distinguish those
termination reasons. They are purged only by explicit window destruction,
exclusion or reset, or space deletion.

Absence from an AX or `CGWindowList` snapshot never removes an assignment —
hidden and ordered-out windows drop out of those snapshots routinely. Only a
lifecycle event does.

## Fullscreen apps

The overlay is shown inside a fullscreen app's Space, and every shortcut behaves
as it does on the desktop. The overlay window joins all Spaces at
`.statusBar` level so the stages reach the Space the user is actually looking
at.

The desktop surface must not join all Spaces, or it would follow into the
fullscreen Space and cover the app. Inactive spaces are therefore not occluded
inside a fullscreen Space — the fullscreen app already covers them.

## Edge cases

- First launch creates a single space containing every running window.
- A window closed with Cmd+W or the red button leaves its space immediately.
- A title change from `cd`, a tab switch, or a save updates in place.
- A window created outside Debut's awareness joins the active space on focus and
  gains lifecycle tracking at that point. All three discovery paths — startup
  reconciliation, app launch, and focus change — must register tracking, or the
  window becomes a ghost.
- Hidden apps keep their ordered-out assignments until their windows return.

Space deletion and its overflow rules are specified in
[space-manager.md](space-manager.md).
