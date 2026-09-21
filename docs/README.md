# Debut documentation

Debut complements macOS desktops and Mission Control. A **stage** is Debut's
window-oriented view of a real desktop. macOS owns desktop membership, order,
and visibility; Debut helps users recognize windows, switch within a stage,
select windows across desktops, and navigate desktops faster.

## Product and behavior

- [Stage and window switchers](../spec/space-manager.md): shortcuts, pointer
  interactions, previewed moves, displays, and fullscreen boundaries.
- [System behaviors](../spec/behaviors.md): desktop authority, discovery, focus,
  ordering, persistence, and reconciliation.
- [Settings and onboarding](../spec/settings.md): current defaults, permissions,
  feature switches, and tutorial behavior.
- [Architecture](architecture.md): terminology, component map, and platform
  integration, with links to the implementing source.

## Development and operations

- [Agent guidance](../AGENTS.md): task workflow, architectural constraints, and
  verification requirements. [CLAUDE.md](../CLAUDE.md) points to the same guidance.
- [Local E2E](local-e2e.md): headless Tart setup, fixtures, and evidence.
- [Performance observability](performance-observability.md): local measurements,
  benchmark commands, and the remote payload boundary.
- [Release verification](release-verification.md): channels, publication gates,
  update rehearsal, and recovery.
- [Privacy](privacy.md), [telemetry anonymization assessment](telemetry-anonymization-assessment.md),
  and [privacy release checklist](privacy-release-checklist.md).

These Markdown documents describe the current implementation. The legacy HTML
documentation is deprecated and is not a source of current behavior; it is retained
unchanged pending removal. Historical measurements and release evidence are
identified as such rather than treated as current product guarantees.
