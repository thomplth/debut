# Debut Project Instructions

## Build & Test Workflow

After any code change, always run the full cycle:
```bash
./scripts/rebuild.sh
```
This kills the running app, builds, installs to /Applications, launches, and runs E2E tests.

Never leave code changes uninstalled — the installed app must always match the source.

### Quick build without E2E:
```bash
pkill -f "Debut.app" || true; sleep 1
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift package clean
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release
# Then assemble .app, sign, install, launch (see build-app.sh)
```

## Toolchain

This machine has a broken Swift Wasm toolchain in PATH. Always use:
```bash
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift
```
The convenience scripts (`rebuild.sh`, `e2e-test.sh`, `build-app.sh`) handle this automatically.

## Code Signing

Uses a self-signed "Debut Dev" certificate (persists in login keychain). This keeps Accessibility permissions stable across rebuilds. The build script auto-detects it.

If the certificate is missing, create it with:
```bash
openssl req -x509 -newkey rsa:2048 -keyout /tmp/dk.pem -out /tmp/dc.pem -days 3650 -nodes \
  -subj "/CN=Debut Dev" -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning"
openssl pkcs12 -export -out /tmp/d.p12 -inkey /tmp/dk.pem -in /tmp/dc.pem -passout pass:x \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import /tmp/d.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
security add-trusted-cert -d -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/dc.pem
```

## Tests

- Unit + screenshot tests: `TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift test`
- E2E only: `./scripts/e2e-test.sh`
- Full cycle: `./scripts/rebuild.sh`

## Architecture Rules

### macOS Window Management
- **CGWindowIDs are ephemeral** — they change between app restarts. Never persist them directly. Use (bundleID, windowTitle) as the stable key for cross-session matching.
- **AX position clamping** — macOS keeps 40px of every window visible on all sides via AX. Cannot be bypassed. Don't use position-based window hiding.
- **SLS/CGS private APIs** (SLSSetWindowAlpha, SLSMoveWindow, etc.) only work on windows owned by the calling process. They silently no-op on other processes' windows without SIP disabled.
- **Desktop surface approach** — Use a Debut-owned full-screen NSWindow at .normal level between active and inactive windows in z-order. Order surface to front, then AX-raise active windows above it. No position/minimize manipulation needed.
- **AX raise doesn't activate** — AXUIElementPerformAction(kAXRaiseAction) only reorders the window within its app's stack. Always also call NSRunningApplication.activate() on the target app.

### Performance
- **Never leave NSHostingView attached when overlay is hidden** — SwiftUI continues layout passes on ordered-out windows, consuming 50%+ CPU. Remove the hosting view in hideOverlay() and recreate in showOverlay().
- **No polling/timers** — Use event-driven architecture only: AXObserver for focus changes, NSWorkspace notifications for app lifecycle.
- **AXObserver pattern** — Observe kAXFocusedWindowChangedNotification on the frontmost app only. Move the observer when didActivateApplicationNotification fires.

### Keyboard Event Tap
- **Consume ALL events when overlay is active** — Return nil for both keyDown and keyUp. Passing keyUp through leaks to the active app.
- **Session vs overlay** — Cmd-held session and overlay visibility are separate states. Esc closes overlay but keeps session alive. Track via `stageManagerActive` (EventTap) and `overlayVisible` (synced from StageController).
- **Check Option flag BEFORE bare Tab** — Prevents Cmd+Option+Tab being caught by the Cmd+Tab handler.

### State Management
- **Exclusion list must filter at ALL layers** — Discovery, launch, activation, reconciliation, and AXObserver.
- **Cross-stage activation = stage switch** — Don't duplicate windows. Exception: truly new windows go to active stage.
