# Debut

**A stage-based workspace manager for macOS that replaces the native app switcher with fully isolated, switchable workspaces.**

Debut lets you organize your open applications into named stages — focused workspaces scoped to a single task or project. Switching between stages is instant: one gesture hides everything from the previous context and reveals the next. Unlike macOS Spaces or Stage Manager, Debut provides complete isolation — Cmd+Tab and Cmd+\` only cycle within the active stage, never across stages.

---

## Core Concepts

### Stage

A named workspace containing a set of application windows. Each stage represents one task or project context (e.g., "Coding," "Code Review," "Email"). Only one stage is active at a time. Windows in inactive stages are hidden.

### Plate

The visual representation of a stage inside the Stage Manager overlay. Each plate is a horizontal strip of app icons — visually similar to the native macOS app switcher — with the stage name displayed in the top-left corner. Plates are stacked vertically, with the active stage's plate centered on screen.

### Active Stage

The currently visible workspace. All app-switching shortcuts (Cmd+Tab, Cmd+\`) are scoped to the active stage. Launching a new app adds it to the active stage.

### Template

A saved app list that can be applied when creating a new stage. Templates capture which apps should be launched — not window positions or sizes. Useful for recurring workflows (e.g., a "Coding" template that opens your editor, terminal, and browser).

---

## How Debut Differs

| | Debut | Stage Manager | BetterStage | Contexts |
|---|---|---|---|---|
| Cmd+Tab isolation | Full | None | None | Per-Space only |
| Named workspaces | Yes | No | Yes | No |
| Visual stage overview | Vertical plate stack | Side thumbnails | Stage list | Window list |
| Persistence across reboot | Full | Partial | Partial | No |
| Templates / presets | Yes | No | No | No |
| Window sharing across stages | Yes (single-window apps) | No | No | N/A |

---

## Architecture

Debut has two views:

### 1. Stage Manager (overlay)

A system-wide overlay activated by holding Cmd+Tab. Displays all stages as vertically stacked plates. Supports navigation between apps and stages, stage creation/deletion, reordering, renaming, and template saving — all via keyboard or mouse.

**[Full spec: spec/stage-manager.md](spec/stage-manager.md)**

### 2. Settings (window)

A standalone settings window with a sidebar + scrollable main area. Manages templates, app preferences, keyboard shortcut customization, and about info. Entry point on first launch.

**[Full spec: spec/settings.md](spec/settings.md)**

### System Behaviors

Window-to-stage assignment rules, Cmd+Tab/\` isolation, persistence, and transitive behaviors (what happens when apps launch, stages switch, or stages are deleted).

**[Full spec: spec/behaviors.md](spec/behaviors.md)**
