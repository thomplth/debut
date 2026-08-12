# Isolated local E2E

The E2E suite can run inside a headless Tart macOS VM. Keyboard and mouse events
stay inside the guest, so the suite never takes over the developer's desktop.
Building stays on the host for fast incremental iteration; only compressed,
cache-busted app and `DebutE2E` artifacts are shared with the guest.

AGENTS.md decides *when* E2E is warranted — rarely, and only for high-risk
changes. This document covers only how to run it.

## One-time setup

Tart requires an Apple Silicon Mac. The Cirrus Labs tooling and Tahoe base image
are free, but the image download is large — tens of GB compressed.

```bash
brew install cirruslabs/cli/tart
./scripts/tart-e2e.sh prepare
```

`prepare` provisions and sizes the VM; its CPU, memory, and display values live
in `scripts/tart-e2e.sh`. The Cirrus Labs image supplies an auto-login user, SSH,
and the Tart guest agent. Xcode is intentionally not installed in the guest.

## Running

```bash
./scripts/tart-e2e.sh run
```

This is the fast, stable iteration loop. It runs the supported scenarios and
reports the synthetic drags that virtualized macOS cannot deliver as explicit
skips, exiting successfully when the supported scenarios pass. The script's own
output is the authority on the current pass count.

Use the diagnostic mode only when investigating that drag limitation:

```bash
./scripts/tart-e2e.sh run-all
```

The first run boots the VM headlessly; later runs reuse the warm guest and its
GUI session. Results, screenshots, and the latest console output — retained even
when the suite fails — land in the shared directory, by default under
`~/Library/Caches/Debut/TartE2E`. `DEBUT_TART_VM` and `DEBUT_TART_SHARE` override
the VM and shared-directory names.

Use `./scripts/tart-e2e.sh stop` when the warm VM is no longer needed, and
`./scripts/tart-e2e.sh status` to inspect it.

## Foreground last resort

`./scripts/e2e-test.sh` runs against the foreground developer session and is the
only local option for exercising physical drag delivery. It opens the overlay,
injects global keyboard and mouse events, and captures the live desktop. Warn the
user before running it, and only when the drag scenarios are material to the
change at hand.

## Drag limitation

On the Tahoe base image, Virtualization.framework does not deliver drag sequences
to SwiftUI, so `run` reports those scenarios as skips rather than failures.
`run-all` attempts them for diagnostics and reproduces the same unsupported
behavior GitHub-hosted macOS shows. Ordinary global keyboard, hover, click,
Accessibility, screenshot, Mission Control, app lifecycle, and settings scenarios
all pass.

Attaching a VNC framebuffer and retaining virtual keyboard and pointer devices
were both tested; neither enabled drag delivery, and VNC additionally opens
Screen Sharing on the host. The script therefore runs with
`--no-graphics --no-pointer --no-keyboard`.
