# Settings

The Settings window is the entry point on first launch and the place to configure
Debut's behavior, appearance, shortcuts, and exclusions.

## Layout

```
┌───────────────┬──────────────────────────────────┐
│ Appearance    │                                  │
│ Excluded Apps │   all sections stacked           │
│ App           │                                  │
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

**Appearance** — glass style, plus the plate and selection geometry the overlay
renders with.

**Excluded Apps** — a picker over running regular apps and the resulting
exclusion list. Adding an app removes it from every stage and filters it out of
discovery immediately.

**App** — launch at login, menu bar visibility, new-stage placement, stage
deletion confirmation, and the animation toggle.

**Keyboard Shortcuts** — an editable binding for every `KeyAction`, recorded by
clicking a row and pressing the combination. Conflicts are detected inline and
require explicit replacement. The section also carries the overlay hold delay,
the command-hint controls, and quick-switch exclusions.

Command hints annotate the overlay's available commands. `Automatic` retires each
hint once its command has been used more than three times, `Never` hides them
all, and `Always` keeps them visible. Learned usage counts can be reset.

**Troubleshooting** — exports a diagnostic snapshot covering window assignments,
Accessibility tracking, lifecycle events, and persisted state (it includes app
and window names and window titles), and resets the window cache when closed or
duplicate windows linger in Debut.

**About** — icon, name, and version.

## Not yet implemented

- No check-for-updates control.
