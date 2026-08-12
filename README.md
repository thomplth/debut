# Debut

A stage-based workspace manager for macOS. Debut replaces the native app switcher
with isolated workspaces: Cmd+Tab and Cmd+\` cycle only within the active stage,
never across stages.

## Concepts

**Stage** — a workspace holding a set of windows, scoped to one task or project.
Exactly one stage is active at a time; windows in inactive stages stay where they
are and are occluded by a full-screen desktop surface. Stages are not named. A
stage's label is its 1-based position, so create, delete, and reorder need no
bookkeeping.

**Window** — the unit Debut tracks. Stages hold individual windows rather than
apps, so one app can have windows in several stages at once.

**Plate** — a stage's representation inside the overlay: a horizontal row of
window previews, each badged with its app icon and captioned with its title.
Plates stack vertically with the active stage centered, and carry no title of
their own.

**Template** — a list of app bundle IDs captured from a stage. Templates record
which apps were present, not window geometry. They can currently be saved and
deleted only; no flow applies one to a new stage.

## Specs

- [Stage Manager overlay](spec/stage-manager.md) — layout, activation, navigation, stage management
- [Settings window](spec/settings.md) — sections and behavior
- [System behaviors](spec/behaviors.md) — assignment rules, isolation, persistence, reconciliation

Architecture constraints, the toolchain, and the task workflow live in
[AGENTS.md](AGENTS.md).

## Verification

Unit and screenshot tests are the default development loop. E2E is reserved for
high-risk changes — see [AGENTS.md](AGENTS.md) for the policy and
[docs/local-e2e.md](docs/local-e2e.md) for running it headlessly.
