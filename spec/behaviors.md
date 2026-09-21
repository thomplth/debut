# System behaviors

Debut provides window switching and desktop navigation on top of macOS. A
**stage** is the product's representation of a real desktop; `Space`,
`SpaceManager`, and `SpaceController` are the existing implementation names.
See [architecture](../docs/architecture.md) for the component map and
[the switcher specification](space-manager.md) for interaction details.

## Desktop authority

macOS is the source of truth for desktop count, order, current desktop, and window
membership. Users create, delete, and reorder desktops in Mission Control.
Debut can navigate existing desktops and request window moves, but does not own a
second workspace layout independent of macOS.

Every connected display stack contains one stage per normal desktop in macOS's
order, including empty desktops. With separate Spaces disabled, there is one
shared stack. Reconciliation retains a desktop's persistent UUID as a join key
so a Mission Control reorder carries its stage's state along with it. The UUID
does not prescribe desktop order. Legacy records without that identity adopt
the reported desktops by position; if UUIDs are unavailable, reconciliation
falls back to the reported count.

Active-Space notifications synchronize visible desktops and window placements.
Desktop-reconfiguration notifications also refresh the list, since reordering or
removing an inactive desktop need not change the active Space. Opening the
overlay rechecks topology. Display reconnection and shared/separate-Space mode
changes reconcile against the newly reported topology. Disconnected stacks may
retain state for recovery but are not offered as connected stage stacks.

The old same-desktop workspace model is retired. There is no desktop-covering
surface, position-based hiding, app minimization scheme, or per-window raise loop
to simulate a desktop switch. macOS reveals the destination desktop as a whole.

## Switching scope and focus

Command-Tab and Command-backtick, when workspace isolation is enabled, cycle
windows in the current stage. Explicit stage navigation, numbered shortcuts,
Option-Tab, Control-arrow, and the desktop swipe feature can cross desktops.
Isolation scopes the window cycle; it does not prohibit intentional navigation.

Debut selects windows rather than applications. One app can therefore have
separate selectable windows in several stages. The stage overlay groups by
desktop; the all-windows overlay uses a flat global recency order.

A requested desktop switch uses the DockSwipe path in `SpaceService`. A
multi-desktop route is a sequence of adjacent hops, with the configured duration
per hop. The default is Instant. Where available, Debut seeds the destination's
front-process memory before switching; the actual window focus waits until
macOS confirms the destination through the active-Space notification. Landing
elsewhere invalidates the pending focus request.

Window activation uses window-server fronting plus a key-window event, with AX
and AppKit support/fallbacks. An accepted request is not proof that focus arrived:
the controller verifies delivery and reports failures. Focus reports answering
Debut's own request are credited to the requested window for a bounded interval
because an app can report a different one of its windows.

An external activation is an observation, not a request to restore a saved
layout. If macOS says a tracked window now belongs to a different desktop, Debut
updates its assignment. It does not switch the user back to the stale stored
desktop. Native navigation remains valid and is reflected in Debut.

The optional desktop indicator appears after a confirmed desktop change, showing
the desktop number and count on the affected display. It also reflects native
switches, is suppressed while the switcher is visible, and does not announce an
unconfirmed switch request.

## Discovery and membership

The inventory comes from Core Graphics plus per-desktop SkyLight queries. AX
provides metadata and notifications for windows reached through those sources;
`kAXWindows` is not a complete inventory of windows on other desktops.

Eligible windows belong to regular applications. Discovery combines window-server
layer, size, parent, and desktop evidence with available AX role/subrole/modal
classification. Standard windows and non-modal dialogs can be tracked; modal
dialogs, child surfaces, floating tools, and other auxiliary UI are excluded or
handled as system-attention UI. Missing AX access alone does not reject a window
that has suitable window-server evidence. A transient contradictory classification
makes an existing assignment dormant rather than erasing it.

Each live tracked window has one assignment. Positive desktop membership always
wins over a saved assignment, including for newly discovered windows. New windows
are not unconditionally sent to stage 1 or to the desktop currently showing.

Windows on every desktop have no single location. Existing assignments stay
where they are until there is a positive location; a previously unknown shared
window may be admitted to the current stage. A window on no normal desktop,
including a newly encountered fullscreen-only surface, is different: it is not
admitted just because a desktop happens to be showing. `placedWindowIDs()`
distinguishes these cases.

App exclusions apply to discovery, launch, focus/activation, reconciliation, and
tracking. They do not change global numbered or Control-arrow shortcuts.

## Lifecycle and ordering

Lifecycle observers are shared per PID and register notifications at the app
element, so windows on inactive desktops can still be tracked without a currently
enumerable AX window element. Focus observation follows only the frontmost app.
Launching apps can refuse AX registration temporarily; bounded retries stop on
success, process exit, or superseding activation. Startup, app launch, window
creation, and focus discovery all establish lifecycle tracking.

Window destruction removes its assignment and records a tombstone scoped to the
window ID, PID, and bundle ID. Tombstones survive Debut restarts only while the
owning process is still valid. They prevent a dismissed but still-listed backing
surface from becoming a ghost card. A trusted creation event resolving to that
same process and window ID can begin a new lifetime and clear the tombstone;
mere presence in a scan cannot.

Process-exit monitoring is event-driven, with workspace termination notifications
as backup. An app exit makes its live windows dormant through one idempotent
cleanup path. Title and resize notifications update metadata and previews.

Absence from AX or from one window-server list alone does not prove destruction.
If both CG and SkyLight inventories no longer know an assignment, reconciliation
makes it dormant (`vanished`). Explicit AX contradictions can also make it
dormant. Neither case permanently deletes its saved recovery information.

Stage window order is most-recently-used first, except for deliberate overlay
reordering. Activation moves a window to the head and records `lastActivatedAt`;
the all-windows list sorts those timestamps, retaining discovery order for ties
or windows never activated. Same-app cycling freezes its walk order but writes
each step to MRU immediately. Dormant assignments are absent from both switchers.

## Persistence and restore

State lives under `~/Library/Application Support/Debut`. `state.json` stores
display stacks, selected stack, stage identities and desktop UUID joins, per-stack
active stages, live window records, recency, and dormant assignments. Settings,
AX contradiction records, and retired-window tombstones have separate JSON files.
`DebouncedSaver` coalesces mutations and flushes on termination.

The serialized window records **do include** runtime CGWindowIDs and PIDs. Those
values are not durable identity and must be validated against the live process,
bundle, and window snapshot on restore. A recycled ID cannot claim another app's
assignment. Recovery uses valid process-scoped identity, exact bundle/title
matches, and then complete one-to-one bundle matching for changed titles where
the evidence supports it. Titles alone are not stable keys.

Startup reconciles the real desktop topology before window membership, preserves
empty desktop stages, restores eligible assignments, and adopts the desktops
macOS is currently showing without navigating the user. Positive current desktop
locations override restored placements; loading state does not move windows back
to a saved layout.

Dormant assignments preserve position and recency across Debut restarts and app
quits, including updater relaunches. There is no time expiry. Explicit destruction,
app exclusion, reset, or loss of the owning desktop can purge them. Disconnected
display state is retained while it has live or dormant assignments. Troubleshooting's
reset rebuilds window assignments from current desktops and preserves settings.

## Window movement

Overlay moves and within-stage reordering use `StageStackTransaction`: the UI
previews changes, and commit applies them to the model and requests the required
desktop relocations. Escape discards the preview. The bridge's capability gate
refuses unsupported cross-desktop moves. Delivery failures are diagnosed, and
subsequent reconciliation corrects optimistic state from macOS membership.
Moving a window between stages with Up or Down places it at the destination's
MRU head and refreshes its global activation recency; pointer drops and Left or
Right reordering retain their chosen slot.

Immediate focused-window movement keeps the requested window throughout an
in-flight route, follows it to the adjacent desktop, and focuses it after
confirmation. It does not move whichever unrelated window macOS briefly focuses
on an intermediate desktop. Neither movement path creates or prunes stages.
