# Isolated local E2E

The E2E suite can run inside a headless Tart macOS VM. Keyboard and mouse events
stay inside the guest, so the suite does not take over the developer's desktop.
Building remains on the host for fast incremental iterations; only compressed,
cache-busted app and `DebutE2E` artifacts are shared with the guest.

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

## Run

```bash
./scripts/tart-e2e.sh run
```

The first run boots the VM headlessly. Later runs reuse the warm guest and its
GUI session. Results and screenshots are copied to
`~/Library/Caches/Debut/TartE2E/results`, and the latest console output is kept
in `~/Library/Caches/Debut/TartE2E/e2e-latest.log` even when the suite fails.

Use `./scripts/tart-e2e.sh stop` when the warm VM is no longer needed, and
`./scripts/tart-e2e.sh status` to inspect it. `DEBUT_TART_VM` and
`DEBUT_TART_SHARE` override the default VM and shared-directory names.

This is an optional fast local loop. The GitHub-hosted workflow remains the
required E2E result for changes merged to `main`.

## Current drag limitation

On the Tahoe 26.6.1 base image, the suite executes the synthetic drag checks
instead of skipping them, but Virtualization.framework does not deliver those
drag sequences to SwiftUI. The validated result is 32 passing assertions, zero
skips, and the same four drag behaviors unsupported by GitHub-hosted macOS
(three counted failures plus the dependent reverse-drop path). Ordinary global
keyboard, hover, click, Accessibility, screenshots, Mission Control, app
lifecycle, and settings scenarios pass.

Attaching a VNC framebuffer and retaining virtual keyboard/pointer devices were
also tested; neither enabled drag delivery. VNC additionally opens Screen
Sharing on the host, so the reproducible script deliberately uses
`--no-graphics --no-pointer --no-keyboard`.
