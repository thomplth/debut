# Debut Project Instructions

## Task Workflow

For every task:

1. Always work in a clean, isolated Git worktree. Do not make task changes directly in the primary checkout.
2. Always use test-driven development:
   - Add or update the tests first.
   - Run them and confirm they fail for the expected reason.
   - Implement the change.
   - Continue running and fixing the tests until they pass.
3. After finishing the work, commit it and merge the task branch back into `main`.
4. From `main`, install the completed local build and replace the existing `/Applications/Debut.app`. The installed app must match the completed source.
5. Push the completed `main` branch to the remote.

## Build & Test Workflow

After any code change, run the relevant unit and screenshot tests, then build, install, and launch the app:
```bash
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift test
./scripts/build-app.sh
pkill -f "Debut.app" || true
rm -rf /Applications/Debut.app
cp -R .build/Debut.app /Applications/Debut.app
open /Applications/Debut.app
```

Never leave code changes uninstalled — the installed app must always match the source.

### Full E2E

Do not run the full E2E suite by default. Full E2E is optional and should only be run when the change is risky, such as changes to global keyboard handling, Accessibility integration, window discovery or lifecycle, stage switching, overlay presentation, persistence reconciliation, app installation, or code signing.

The full E2E suite is interactive: it launches Debut, displays its overlay, injects global keyboard events into the active macOS session, and captures the live desktop. Warn the user before running it when it could disrupt their session.

For risky changes, run the full cycle:
```bash
./scripts/rebuild.sh
```
This kills the running app, builds, installs to `/Applications`, launches, and runs E2E tests.

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
- Interactive E2E only, for risky changes: `./scripts/e2e-test.sh`
- Full build, install, launch, and interactive E2E cycle, for risky changes: `./scripts/rebuild.sh`

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
- **Global quick-switch gates on `!maskCommand`** — `Ctrl+Option+<1-9>` switches stages without the overlay open. It must be checked BEFORE Cmd-state tracking and require Control+Option WITHOUT Command, so it never collides with the in-overlay Cmd+digit selection (which always has Cmd held).

### State Management
- **Exclusion list must filter at ALL layers** — Discovery, launch, activation, reconciliation, and AXObserver.
- **Cross-stage activation = stage switch** — Don't duplicate windows. Exception: truly new windows go to active stage.
- **Stage labels are position-derived, not stored** — Stages have no `name` field. The displayed label is the 1-based array index (`stageLabel(forID:)` / `PlateData.name = "\(index + 1)"`), so create/delete/reorder need zero bookkeeping. Rename was removed entirely. Removing `Stage.name`/`AppSettings.defaultStageName` is Codable-forward-safe (JSONDecoder ignores leftover keys in existing state.json/settings.json).

### Window Lifecycle
- **All discovery paths must register tracking** — Windows enter the stage manager via three paths: startup reconciliation, app launch, and focus-change (Cmd+N). All three must call `registerTracking` to get `kAXUIElementDestroyedNotification` and `kAXTitleChangedNotification`. Missing any path causes ghost windows.
- **Desktop surface must not join all Spaces** — `.canJoinAllSpaces` causes the surface to follow into fullscreen Spaces, covering the fullscreen app. The surface only matters on the normal desktop.

### Persistence & Reconciliation
- **Window titles are NOT stable keys** — Terminal prompts, browser tabs, Slack channels all change titles between sessions. Reconciliation must fall back to bundleID-only matching when (bundleID, title) exact match fails.
- **Prune empty stages on restore** — After reconciliation removes stale windows, drop stages with zero windows remaining (keep at least one).
- **Focus-based starting stage** — On launch, query AX for the currently focused window, find its owning stage, and activate that stage instead of always stage 0.

## Wrap Process

When the user asks to "wrap", perform the following steps:

1. **Review all changes** since the last wrap/commit — `git diff`, `git status`, `git log`
2. **Update spec docs** (`spec/`) to reflect any new or changed requirements, and update task tracker checkboxes
3. **Update AGENTS.md** with any architecture rules or learnings discovered during the session
4. **Commit all changes** to the GitHub repo with a descriptive commit message
5. **Push to remote**
6. **Create a GitHub release** with:
   - Release notes summarizing changes
   - DMG built via `./scripts/build-app.sh` and packaged with `hdiutil`
