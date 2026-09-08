# Contributor guidance

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests, and pull requests.

- Add a regression test before changing behavior and confirm it fails for the expected reason.
- Run Swift tests with `--no-parallel`; suites share main-queue resources.
- Run E2E only for high-risk changes to input, Accessibility, window lifecycle,
  desktop switching, overlay presentation, persistence reconciliation, installation,
  or signing. Use headless Tart first: `./scripts/tart-e2e.sh run`.
- Never run E2E against the developer's foreground session. If Tart cannot exercise
  a scenario, report the limitation; do not substitute live desktop automation.
- Keep changes scoped. Do not publish releases or change signing credentials as
  part of ordinary contribution work.

## Architecture constraints

- Spaces are real macOS desktops in system order. Only desktop reconciliation
  adds or removes spaces; never prune empty desktops or reorder them independently.
- Discover membership through CG and SkyLight. AX window enumeration is limited
  by presentation state; absence from a snapshot does not prove destruction.
- Track lifecycle events on every discovery path. Process exit preserves dormant
  assignments. Destroyed-window tombstones are scoped to the owning process and
  validated before reuse; persisted assignments match by bundle and title with
  one-to-one bundle fallback for changed titles.
- Move windows through the bridged window server and verify capability before
  changing the model. Never use pointer-driven moves or position-based hiding.
- Wait for the desktop-change notification before focusing a switch destination.
  Focus reports can name another window of the requested app; preserve activation
  attribution and verify that fronting actually took effect.
- Keep event-tap callbacks free of cross-process queries. Consume both halves of
  claimed key events and keep modifier sessions separate from overlay visibility.
- Use notifications and observers rather than polling. Observer registration may
  need a bounded startup retry, canceled on success, activation change, or exit.
- Use ScreenCaptureKit and verify actual image content, not just a non-nil result.
  Detach hosting views while overlays are hidden. Fullscreen presentation requires
  a nonactivating panel and window-server evidence in E2E.
- Keep exclusions consistent across discovery, activation, tracking, and restore.
  Report assignment changes and refresh diagnostic state for every event.
- Keep development versions at `0.0.0-dev`. Release workflows stamp versions for
  packaging; stable and nightly feeds and signing identities remain separate.
