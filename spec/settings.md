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
└──────────────┴───────────────────────────────────────────┘
```

### Implementation Checklist

- [x] Sidebar with fixed-width list of section names ✅ verified
- [x] Clicking sidebar item scrolls main area to that section ✅ verified
- [x] Active section highlighted based on scroll position ✅ verified
- [x] Main area: single scrollable view with all sections stacked vertically ✅ verified
- [x] Each section has a header and content below ✅ verified
- [x] Native macOS settings visual style ✅ verified

---

## Sections

### Templates

- [x] Scrollable list of saved templates (name + bundle ID list) ✅ verified
- [ ] Create template button → opens editor — NOT IMPLEMENTED
- [ ] Click template to edit name or app list — NOT IMPLEMENTED
- [x] Delete button per template ✅ verified
- [ ] Template editor: name field (text input) — NOT IMPLEMENTED
- [ ] Template editor: searchable app picker — NOT IMPLEMENTED
- [ ] Template editor: save / cancel buttons — NOT IMPLEMENTED

### App

- [x] Launch at login toggle (default: off) ✅ verified (UI only, no SMAppService wiring)
- [x] Show in menu bar toggle (default: on) ✅ verified
- [x] Default stage name text field (default: "Stage") ✅ verified
- [x] New stage placement dropdown: Above / Below (default: Below) ✅ verified
- [x] Confirm stage deletion toggle (default: on) ✅ verified
- [x] Stage Manager animation toggle (default: on) ✅ verified

### Keyboard Shortcuts

- [x] All shortcuts listed with current bindings ✅ verified (display only)
- [ ] Shortcut editor: click to enter recording mode — NOT IMPLEMENTED
- [ ] Conflict detection with warning — NOT IMPLEMENTED

### About

- [x] App icon and name display ✅ verified
- [x] Version number ✅ verified
- [ ] Check for updates button — NOT IMPLEMENTED
- [x] Credits / attribution ✅ verified
