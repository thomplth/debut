# Isolated local E2E

The E2E suite can run inside a headless Tart macOS VM. Keyboard and mouse events
stay inside the guest, so the suite does not take over the developer's desktop.
Building remains on the host for fast incremental iterations; only compressed,
cache-busted app and `DebutE2E` artifacts are shared with the guest.

## High-risk changes only

Do not use E2E for routine changes. Unit and screenshot tests are the normal
verification path. E2E is reserved for high-risk work involving global keyboard
handling, Accessibility, window discovery or lifecycle, stage switching,
overlay presentation, persistence reconciliation, installation, or code
signing.

When E2E is warranted, the preferred headless path is Tart because it keeps the
developer desktop undisturbed and provides a warm local iteration loop. The
GitHub-hosted macOS 26 workflow is the fallback when Tart is unavailable and a
remote confirmation when the change is already being pushed.

## One-time setup

Tart requires an Apple Silicon Mac. The official Cirrus Labs installation and
Tahoe base image are free, but the image download is about 27 GB compressed.

```bash
brew install cirruslabs/cli/tart
./scripts/tart-e2e.sh prepare
```

The prepared `debut-e2e-tahoe` VM uses six CPUs, 8 GB RAM, and a 1440×900
display. Cirrus Labs' image supplies an auto-login user, SSH, and the Tart guest
agent; Xcode is intentionally not installed in the VM.

## Preferred headless run

```bash
./scripts/tart-e2e.sh run
```

The default command is the fast, stable iteration loop: 32 assertions pass and
the four synthetic drags unsupported by virtualized macOS are reported as
explicit skips. It exits successfully when those supported scenarios pass.

Use the diagnostic mode only when investigating the virtualized drag limitation:

```bash
./scripts/tart-e2e.sh run-all
```

The first run boots the VM headlessly. Later runs reuse the warm guest and its
GUI session. Results and screenshots are copied to
`~/Library/Caches/Debut/TartE2E/results`, and the latest console output is kept
in `~/Library/Caches/Debut/TartE2E/e2e-latest.log` even when the suite fails.

Use `./scripts/tart-e2e.sh stop` when the warm VM is no longer needed, and
`./scripts/tart-e2e.sh status` to inspect it. `DEBUT_TART_VM` and
`DEBUT_TART_SHARE` override the default VM and shared-directory names.

Do not manually trigger or wait for E2E on routine changes. When a high-risk
change reaches a pull request or `main`, the GitHub-hosted workflow provides an
additional remote result, but the headless Tart run remains the preferred first
check.

## Foreground last resort

`./scripts/e2e-test.sh` runs against the foreground developer session and is the
only local option for checking physical drag delivery. It opens the overlay,
injects global keyboard and mouse events, and captures the live desktop. Warn
the user before running it, and use it only when the four drag scenarios are
material to the high-risk change.

## Current drag limitation

On the Tahoe 26.6.1 base image, Virtualization.framework does not deliver drag
sequences to SwiftUI. The default `run` result is 32 passing assertions, four
explicit skips, and zero failures. `run-all` attempts those gestures for
diagnostics and currently reports the same four unsupported drag behaviors as
GitHub-hosted macOS. Ordinary global keyboard, hover, click, Accessibility,
screenshots, Mission Control, app lifecycle, and settings scenarios pass.

Attaching a VNC framebuffer and retaining virtual keyboard/pointer devices were
also tested; neither enabled drag delivery. VNC additionally opens Screen
Sharing on the host, so the reproducible script deliberately uses
`--no-graphics --no-pointer --no-keyboard`.
