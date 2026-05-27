# Settings

The Settings window is the entry point on first launch and the central place for configuring Debut's behavior, managing templates, and customizing keyboard shortcuts.

---

## Window Layout

```
┌──────────────────────────────────────────────────────────┐
│ ● ● ●                         Debut Settings             │
├──────────────┬───────────────────────────────────────────┤
│              │                                           │
│  Templates   │  (scrollable main content area)           │
│              │                                           │
│  App         │  All sections are rendered in a single    │
│              │  scrollable view. Clicking a sidebar item │
│  Keyboard    │  scrolls to that section.                 │
│  Shortcuts   │                                           │
│              │                                           │
│  About       │                                           │
│              │                                           │
├──────────────┤                                           │
│              │                                           │
│              │                                           │
└──────────────┴───────────────────────────────────────────┘
```

### Implementation Checklist

- [ ] Sidebar with fixed-width list of section names
- [ ] Clicking sidebar item scrolls main area to that section
- [ ] Active section highlighted based on scroll position
- [ ] Main area: single scrollable view with all sections stacked vertically
- [ ] Each section has a header and content below
- [ ] Native macOS settings visual style

---

## Sections

### Templates

- [ ] Scrollable list of saved templates (name + row of app icons)
- [ ] Create template button → opens editor
- [ ] Click template to edit name or app list
- [ ] Delete button per template (with confirmation)
- [ ] Template editor: name field (text input)
- [ ] Template editor: searchable app picker (toggle apps on/off)
- [ ] Template editor: save / cancel buttons

### App

- [ ] Launch at login toggle (default: off)
- [ ] Show in menu bar toggle (default: on)
- [ ] Default stage name text field (default: "Stage")
- [ ] New stage placement dropdown: Above / Below (default: Below)
- [ ] Confirm stage deletion toggle (default: on)
- [ ] Stage Manager animation toggle (default: on)

### Keyboard Shortcuts

Non-configurable (system overrides):
- [ ] Display: Open Stage Manager — Cmd+Tab (hold)
- [ ] Display: Quick switch last app — Cmd+Tab (tap)
- [ ] Display: Commit selection — Release Cmd
- [ ] Display: Discard selection — Esc

Configurable shortcuts:
- [ ] Next app — default: Tab
- [ ] Previous app — default: Shift+Tab
- [ ] Next stage — default: Option+Tab
- [ ] Previous stage — default: Shift+Option+Tab
- [ ] Jump to stage 1–9 — default: 1–9
- [ ] New stage below — default: N
- [ ] New stage above — default: Shift+N
- [ ] Delete stage — default: Delete
- [ ] Rename stage — default: R
- [ ] Save as template — default: Space
- [ ] Move app up — default: Arrow Up
- [ ] Move app down — default: Arrow Down
- [ ] Swap stage up — default: Option+Arrow Up
- [ ] Swap stage down — default: Option+Arrow Down
- [ ] Shortcut editor: click to enter recording mode, press combo, Enter to confirm, Esc to cancel
- [ ] Conflict detection with warning

### About

- [ ] App icon and name display
- [ ] Version number and build
- [ ] Check for updates button
- [ ] Credits / attribution
- [ ] Links (website, support, feedback)
- [ ] License info
