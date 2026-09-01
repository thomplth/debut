# Settings

The Settings window is the entry point on first launch and the place to configure
Debut's behavior, appearance, shortcuts, and exclusions.

## Layout

```
┌───────────────┬──────────────────────────────────┐
│ Appearance    │                                  │
│ Selector      │                                  │
│ Excluded Apps │   all sections stacked           │
│ App           │                                  │
│ Privacy       │                                  │
│ Keyboard      │                                  │
│ Troubleshoot  │                                  │
│ About         │                                  │
└───────────────┴──────────────────────────────────┘
```

A fixed-width sidebar lists the sections while the main area stacks all of them
in a single scrollable view. Clicking a sidebar entry scrolls to that section,
and the sidebar highlights whichever section the scroll position implies.

Changes save immediately and take effect live; nothing requires a restart. The
window uses the native macOS settings visual style.

## Sections

Individual controls, their ranges, and their default values are defined in
`SettingsWindow.swift` and `AppSettings` and are deliberately not restated here.

**Appearance** — glass style, stage geometry, and the window preview refresh
policy.

**Selector** — selection style and the controls specific to it. Filled is the
default and exposes surrounding space and corner radius. Its translucent adaptive
plate sits behind the preview and app icon while leaving the title outside. Magnify
preserves the original effect and exposes selected-window scale and shadow
strength. The fill is not drawn on drag previews.

**Excluded Apps** — a picker over running regular apps and the resulting
exclusion list. Adding an app removes it from every space and filters it out of
discovery immediately.

**App** — launch at login, registered through `SMAppService`. Overlay animation
follows the system Reduce Motion setting rather than a Debut toggle.

Every control in Settings must be wired to behaviour. Options that no code reads
are removed rather than left visible; `AppSettings` ignores unknown keys, so
files written by an older build keep loading.

**Privacy** — one switch for anonymous usage and performance sharing, on by default,
alongside a preview of the exact payload and a link to the privacy policy. The choice
takes effect immediately and turning it off discards anything still queued. Local
diagnostics are unaffected either way; see [../docs/privacy.md](../docs/privacy.md).

**Keyboard Shortcuts** — an editable binding for every `KeyAction`, recorded by
clicking a row and pressing the combination. Conflicts are detected inline and
require explicit replacement. The section also carries the overlay hold delay,
the command-hint controls, and quick-switch exclusions. Quick switching exposes
separate modifier settings for direct space switching and for switching while
keeping the current app; both apply to digits 1–9.

Command hints annotate the overlay's available commands. `Automatic` retires each
hint once its command has been used more than three times, `Never` hides them
all, and `Always` keeps them visible. Learned usage counts can be reset.

Transitive commands are excluded from hints in every mode, including `Always`.
A transitive command reaches through the overlay to act on the app under the
selection rather than on Debut — quitting the selected app is the only one today.
Hints teach Debut's own vocabulary, so they stay silent about what the overlay
does to someone else's app.

**Troubleshooting** — exports a diagnostic snapshot covering window assignments,
Accessibility tracking, lifecycle events, and persisted state (it includes app
and window names and window titles), and resets the window cache when closed or
duplicate windows linger in Debut.

**About** — icon, name, and version.

## Not yet implemented

- No check-for-updates control.
