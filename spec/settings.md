# Settings and onboarding

First launch opens onboarding: choose features, grant permissions, then learn workspace
switching, desktop navigation, all-windows switching and moving windows. The three
feature pillars are screenshot previews, workspace-scoped switching, and faster desktop
navigation. Spaces are actual macOS desktops, created and removed in Mission Control.

Settings opens on **Features**. Its sidebar selects one independently scrolling page:
Features, Excluded Apps, App, Privacy, Keyboard Shortcuts, Advanced, Troubleshooting,
About. Choices save immediately and also update onboarding and menu-bar checkmarks.

**Features** uses the same controls as onboarding. Window previews, workspace isolation,
and numbered shortcuts default on. Control-arrow and trackpad desktop interception
default off, including on upgrade. Disabling workspace isolation returns its activation
shortcuts and same-app cycling to macOS; Option-Tab and workspace browsing remain
available. Disabling previews stops captures and clears cached images; cards still show
icons and titles. Screen Recording remains required for desktop wallpaper.

Numbered shortcuts, Control-arrow and trackpad desktop gestures are independently
switchable. Debut's duration setting applies per desktop crossed, from Instant to
400 ms. New input handlers must leave other gestures and unclaimed shortcuts untouched,
consume the matching key-up of a claimed key-down, and never intercept their own
synthetic DockSwipe events. Trackpad interception commits one adjacent hop per gesture.

**Keyboard Shortcuts** holds editable activation and session bindings, separate numbered
modifiers for direct navigation and same-app preference, overlay delay, held-repeat pace,
and app exclusions for numbered and Control-arrow inputs. Existing bindings remain saved
when their feature is disabled.

**Advanced** holds glass, card geometry, adaptive sizing, selection appearance, preview
refresh policy and cache lifetime. **Excluded Apps** removes selected apps from window
management. **App** controls login launch and Dock visibility. **Privacy** contains the
sharing switch and exact-payload preview. **Troubleshooting** exports local diagnostics
or resets assignments against the real desktop list. **About** shows the version and
provides update checks.

The menu bar provides quick feature checkmarks, Settings, Tutorial, update checks and Quit.
Control values and ranges live in AppSettings and SettingsWindow.swift.
