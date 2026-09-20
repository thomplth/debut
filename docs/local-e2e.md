# Isolated local E2E

The E2E suite can run inside a headless Tart macOS VM. Keyboard and mouse events
stay inside the guest, so the suite never takes over the developer's desktop.
Building stays on the host for fast incremental iteration; only compressed,
cache-busted app and `DebutE2E` artifacts are shared with the guest.

[AGENTS.md](../AGENTS.md) decides *when* E2E is warranted: high-risk changes only.
The preferred headless path is the Tart VM. GitHub-hosted CI is not an agent fallback:
if Tart is unavailable or cannot exercise a scenario, report that limitation rather
than running against the foreground session or manually dispatching hosted E2E.
The hosted workflow remains an automated CI/release gate. Routine code changes use
relevant unit and screenshot tests; documentation-only changes use applicable
shell contracts and a source/link audit.

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

This is the fast, stable iteration loop, and it runs every scenario, including the
synthetic drag gestures. The script's own output is the authority on the current
pass count.

The first run boots the VM headlessly; later runs reuse the warm guest and its
GUI session. Results, screenshots, and the latest console output — retained even
when the suite fails — land in the shared directory, by default under
`~/Library/Caches/Debut/TartE2E`. `DEBUT_TART_VM` and `DEBUT_TART_SHARE` override
the VM and shared-directory names.

Use `./scripts/tart-e2e.sh stop` when the warm VM is no longer needed, and
`./scripts/tart-e2e.sh status` to inspect it.

## The foreground session is not an option

`./scripts/e2e-test.sh` runs against the developer's own desktop: it opens the
overlay, injects global keyboard and mouse events, and captures the live screen.
Only the developer may start it. Agents must use Tart, including for physical-drag
validation; a VM limitation is not permission to use the foreground session.
The normal Tart suite includes the window-drop scenarios.

## Drags under virtualization

Tart delivers synthetic drags. An earlier note here claimed
Virtualization.framework could not, and the two drop scenarios were skipped on
that basis; re-measured on the Tahoe base image they pass, moving a window across
desktops and back. The original claim was extrapolated from GitHub-hosted macOS,
which genuinely does not deliver them and where the two checks still skip.

That extrapolation held because every other pointer scenario was failing too, for
an unrelated reason: stacked TCC alerts on the warm VM swallowed the events until
KHA-612 cleared them. The VM still runs with `--no-graphics --no-pointer
--no-keyboard`; a VNC framebuffer and retained virtual input devices were tested
and neither is needed.

## Real desktop fixtures

A fresh disposable host starts with one desktop. Since stages are real desktops,
a passing single-desktop run cannot prove switching or cross-desktop movement.
`scripts/tart-e2e-guest.sh` and `scripts/ci-e2e.sh` explicitly invoke
`DebutE2E provision-desktops <n>` before launching Debut. This fixture uses Mission
Control's `mc.spaces.add` Accessibility button. It is test-only provisioning, not
an app feature, and must remain confined to disposable hosts.

Do not seed the Dock's spaces plist: it can produce duplicate desktop identities.
Gate each scenario on its actual needs: switching requires multiple desktops;
window-drop checks also need the appropriate empty destination. Validate the
real window location, focused window, or on-screen panel through the window
server, rather than accepting an optimistic model flag as proof of success.

Overlay drag edits are preview transactions. A drag scenario must commit before
asserting relocation, and cancellation must leave the real window on its original
desktop. See [the switcher contract](../spec/space-manager.md#moving-windows).
