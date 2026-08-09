# Settings

The Settings window is the entry point on first launch and the central place for configuring Debut's behavior, managing templates, customizing appearance, and managing excluded apps.

---

## Window Layout

```
┌──────────────────────────────────────────────────────────┐
│                          Debut Settings                   │
├──────────────┬───────────────────────────────────────────┤
│              │                                           │
│  Appearance  │  (scrollable main content area)           │
│              │                                           │
│  Templates   │  All sections are rendered in a single    │
│              │  scrollable view. Clicking a sidebar item │
│  Excluded    │  scrolls to that section.                 │
│  Apps        │                                           │
│              │                                           │
│  App         │                                           │
│              │                                           │
│  Keyboard    │                                           │
│  Shortcuts   │                                           │
│              │                                           │
│  About       │                                           │
│              │                                           │
└──────────────┴───────────────────────────────────────────┘
```

### Implementation Checklist

- [x] Sidebar with fixed-width list of section names
- [x] Clicking sidebar item scrolls main area to that section
- [x] Active section highlighted based on scroll position
- [x] Main area: single scrollable view with all sections stacked vertically
- [x] Native macOS settings visual style
- [x] Settings changes saved immediately via onSettingsChanged callback
- [x] Changes take effect live (no restart required)

---

## Sections

### Appearance

- [x] Glass style picker: Clear / Regular (default: Clear)
- [x] Corner radius slider: 0-40 (default: 22)
- [x] Inactive plate scale slider: 0.4-1.0 (default: 0.8)
- [x] Selection fill opacity slider: 0-0.5 (default: 0.15)
- [x] Selection border width slider: 0-4 (default: 1.5)
- [x] Selection border opacity slider: 0-0.5 (default: 0.2)

### Templates

- [x] Scrollable list of saved templates (name + bundle ID list)
- [x] Delete button per template
- [ ] Create template button -> opens editor
- [ ] Click template to edit name or app list
- [ ] Template editor: searchable app picker

### Excluded Apps

- [x] Description text explaining exclusion behavior
- [x] Dropdown picker populated from running regular apps (excluding already-excluded)
- [x] Add button to add selected app to exclusion list
- [x] List of excluded apps with icon, name, bundle ID, and delete button
- [x] Changes take effect immediately (removed from all stages, filtered from discovery)
- [x] Exclusion list persisted in settings.json

### App

- [x] Launch at login toggle (default: off)
- [x] Show in menu bar toggle (default: on)
- [x] New stage placement picker: Above / Below (default: Below)
- [x] Confirm stage deletion toggle (default: on)
- [x] Stage Manager animation toggle (default: on)

### Keyboard Shortcuts

- [x] All global and Stage Manager shortcuts listed with current bindings
- [x] Overlay hold delay slider: 0-500ms (default: 100ms), persisted and applied immediately
- [x] Quick switch exclusion picker for apps that keep their own Ctrl+number shortcuts
- [x] Quick switch exclusion list persisted and applied immediately
- [x] Shortcut editor: click to enter recording mode
- [x] Command-Tab activation, same-app cycling, quick switch, and session commands are configurable
- [x] Conflict detection with inline warning and explicit replacement

### About

- [x] App icon and name display
- [x] Version number
- [ ] Check for updates button
