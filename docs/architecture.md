# Architecture and terminology

Debut supplements macOS desktops and Mission Control with window-based navigation.
Its four product benefits are choosing individual windows across desktops,
keeping ordinary switching within the current desktop, recognizing windows from
screenshots, and moving between desktops faster. macOS remains responsible for
the desktop system. The current behavior contracts are indexed in
[the documentation guide](README.md).

## Vocabulary and boundaries

| Term | Meaning |
| --- | --- |
| Desktop | A normal macOS desktop created, removed, and ordered in Mission Control. |
| Stage | Debut's representation of one desktop and its tracked windows. |
| Space | Apple's broader term, which can include fullscreen Spaces; also the retained `Space` model name for a stage. |
| Display stack | The ordered desktops for one display when separate Spaces is enabled, or one shared stack otherwise. |
| Workspace isolation | Keeping Command-Tab and same-app cycling inside the current stage. It is a navigation scope, not a security boundary or a window-hiding mechanism. |
| Stage overlay | The stacked desktop view, named “Space Manager” in some existing UI and code. |
| All-windows switcher | The flat Option-Tab list of tracked live windows across stages and displays. |
| Dormant assignment | Saved placement and recency for a window that is currently unavailable; no selectable card. |

A stage at index N represents the desktop at index N **within its display stack**.
A persistent desktop UUID joins the saved record to that desktop when Mission
Control changes the order. Labels are positional; stages have no stored name.
Fullscreen Spaces are not additional stages. Existing code and diagnostic fields
named `space` remain valid identifiers; documentation should distinguish those
identifiers from product language rather than imply a source/API rename.

Desktop creation, removal, and ordering belong to Mission Control. Debut follows
native desktop switches and window moves as well as changes requested through
its own controls. It does not enforce a saved placement against macOS, create
same-desktop virtual workspaces, or cover inactive windows with a fake desktop.
The full-screen overlay panel is switcher UI, not the retired desktop surface.

## Component map

| Component | Responsibility |
| --- | --- |
| [AppDelegate](../Sources/DebutCore/AppDelegate.swift) | Startup, permissions, event wiring, topology refresh, overlay placement, settings, onboarding, and app lifecycle. |
| [SpaceManager](../Sources/DebutCore/Models/SpaceManager.swift), [Space](../Sources/DebutCore/Models/Space.swift), [SpaceTopology](../Sources/DebutCore/Models/SpaceTopology.swift) | Per-display stage state, desktop UUID joins, window order, dormancy, and the topology macOS reports. |
| [SpaceService](../Sources/DebutCore/Services/SpaceService.swift) | SkyLight desktop reads, window membership, synthetic desktop-switch routes, and window-server focus support. |
| [DesktopReconfigurationObserver](../Sources/DebutCore/Services/DesktopReconfigurationObserver.swift) | Signals desktop-list changes and system-overview transitions that active-Space notifications alone cannot describe. |
| [SpaceController](../Sources/DebutCore/Services/SpaceController.swift) | Selection, MRU, overlay sessions, preview capture, movement, and focus after desktop confirmation. |
| [StageStackTransaction](../Sources/DebutCore/Models/StageStackTransaction.swift) | Preview, commit, and cancel boundaries for overlay window moves and reordering. |
| [BridgedWindowManagement](../Sources/DebutCore/Services/BridgedWindowManagement.swift) | Cross-process window relocation through the window-server bridge. |
| [WindowDiscoveryService](../Sources/DebutCore/Services/WindowDiscoveryService.swift), [AccessibilityWindowService](../Sources/DebutCore/Services/AccessibilityWindowService.swift) | CG/SkyLight inventory, AX classification/notifications, tombstones, lifecycle registration, and window actions. |
| [RuntimeWindowReconciler](../Sources/DebutCore/Services/RuntimeWindowReconciler.swift) | Recover assignments, follow positive desktop locations, and make contradicted or vanished windows dormant. |
| [EventTapKeyboardService](../Sources/DebutCore/Services/EventTapKeyboardService.swift), [DesktopSwipeService](../Sources/DebutCore/Services/DesktopSwipeService.swift) | Feature-gated input routing, held sessions, exclusions, and native-input pass-through. |
| [OverlayWindow](../Sources/DebutCore/Views/OverlayWindow.swift), [StageView](../Sources/DebutCore/Views/StageView.swift), [AltTabView](../Sources/DebutCore/Views/AltTabView.swift) | Nonactivating presentation, glass stages, adaptive cards, pointer interaction, and the flat window list. |
| [DesktopSwitchIndicator](../Sources/DebutCore/Views/DesktopSwitchIndicator.swift) | Brief feedback for a confirmed desktop change, independently of the switcher panel. |
| [StateStore](../Sources/DebutCore/Services/StateStore.swift), [DebouncedSaver](../Sources/DebutCore/Services/DebouncedSaver.swift) | Local persistence, decoding/migration, atomic writes, and mutation-driven saves. |
| [DiagnosticReporter](../Sources/DebutCore/Services/DiagnosticReporter.swift), [PerformanceObservability](../Sources/DebutCore/Services/PerformanceObservability.swift), [Telemetry](../Sources/DebutCore/Services/Telemetry.swift) | Local state/evidence and separately allowlisted, optional remote aggregates. |

## Desktop switching and window movement

The synthetic DockSwipe technique is credited in `SpaceService` to
[InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) for the
original switching technique and velocity presets, and
[Space Rabbit](https://github.com/Tahul/space-rabbit) for the gesture-field
reference and driven-progress pattern. Debut adapts the timed progress to the
horizontal desktop axis. The macOS 27 serialized IOHID payload work is credited
to [iss](https://github.com/joshuarli/iss).

When faster desktop transitions are enabled, `DockSwipeAnimation` posts a
high-velocity instant switch at duration zero, or a Began/Changed/Ended sequence
over the requested duration. Each gesture crosses one desktop; longer routes
wait for confirmation and continue through adjacent hops. The macOS 27 recipe
includes the augmented IOHID payload. Capability and system-overview gates
preserve native input when Debut cannot safely own the navigation. When the
parent feature is disabled, cross-desktop window selection fronts the requested
window through the native-transition path: it selects the exact window before
fronting its process so macOS follows that window to its desktop. This is not a
global change to macOS's animation preferences. The parent gates the numbered,
Control-arrow, and trackpad integrations without erasing their saved settings.

Stage commits, numbered navigation, cross-desktop Option-Tab selection, enabled
Control-arrow/trackpad input, and move-and-follow commands use this common
switching integration. macOS navigation that Debut does not intercept remains
native and is observed afterwards. Window focus waits for the destination, rather
than raising each window before the desktop has changed.

Relocating a window is a separate operation. `BridgedWindowManagement` uses
`SLSBridgedMoveWindowsToManagedSpaceOperation`; direct legacy private writes do
not provide working cross-process relocation. `canMoveWindows` gates the
feature. Overlay dragging previews an assignment change, then invokes this bridge
on commit; it does not drag the real window or drive the user's cursor.

## Events, capture, and persistence

Window state is driven by workspace notifications, AX lifecycle/focus events,
process-exit sources, and desktop reconfiguration. Bounded retries handle AX
servers and newly created windows that are not ready yet. Animation schedules,
presentation delays, focus verification, debounced saves, and indicator dismissal
are event-triggered work, not a background discovery poll. Hidden overlays detach
their hosting view so SwiftUI does not keep laying out invisible content.

ScreenCaptureKit supplies window screenshots. Captures are concurrent, cached in
memory, and refreshed according to eligibility and age when requested. Previews
are not continuous video. The desktop behind the glass is the real desktop;
wallpaper capture fields retained in diagnostics are legacy schema, not evidence
of an active wallpaper rendering path.

The saved model is a recovery aid. Window IDs and PIDs appear in local state, but
must be validated against current identities. Desktop UUIDs join records to real
desktops, while macOS continues to decide their order and current window membership.
See [system behaviors](../spec/behaviors.md) for recovery, tombstone, and dormancy
rules and [privacy](privacy.md) for what is kept locally.

## Verification map

Model and controller tests cover topology/desktop reorder, movement transactions,
focus, lifecycle reconciliation, and switching scope. Settings and keyboard tests
cover defaults, feature gates, and bindings. Screenshot tests cover stage layout,
selectors, settings, onboarding, and indicator presentation. Shell contracts in
`Tests/CI` cover packaging, release policy, and execution wrappers.

Real global-input, window-server, and presentation checks run in the headless
Tart VM for agent work. Their assertions must inspect the actual desktop/window
outcome, not just Debut's requested state. A non-nil image is also insufficient:
capture validation must establish that it contains real, varied content.
See [local E2E](local-e2e.md) and [agent guidance](../AGENTS.md) for the required
workflow, toolchain, and verification scope.
