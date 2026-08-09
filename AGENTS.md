# Debut Project Instructions

## Task Workflow

For every task:

1. Always work in a clean, isolated Git worktree. Do not make task changes directly in the primary checkout.
2. Use one task per worktree. Keep commits scoped and write imperative commit messages. Do not prescribe issue IDs in branch or commit names.
3. Always use test-driven development:
   - Add or update the tests first.
   - Run them and confirm they fail for the expected reason.
   - Implement the change.
   - Continue running and fixing the tests until they pass.
4. After verification, commit the task, merge the task branch into `main`, then remove the worktree and task branch.
5. From `main`, install the completed local build and replace the existing `/Applications/Debut.app`. The installed app must match the completed source.
6. Push the completed `main` branch to `origin`.

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

The full E2E suite runs on the free GitHub-hosted macOS runner through `.github/workflows/e2e.yml`. It runs for pull requests and pushes to `main`, and can be started manually from GitHub Actions.

Do not run the full E2E suite on a developer machine by default. It launches Debut, displays its overlay, injects global keyboard events, and captures the live desktop. The hosted workflow is the source of truth because it supplies a clean, repeatable GUI session and does not disturb development.

`./scripts/rebuild.sh` only builds, installs, and launches the app locally. For risky changes such as global keyboard handling, Accessibility integration, window discovery or lifecycle, stage switching, overlay presentation, persistence reconciliation, app installation, or code signing, require the hosted E2E result before considering verification complete.

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
- Hosted E2E: `.github/workflows/e2e.yml`
- Local build, install, and launch without E2E: `./scripts/rebuild.sh`

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
- **Global quick-switch is Ctrl+0-9** — It must be checked BEFORE Cmd-state tracking and require Control WITHOUT Command, Option, or Shift. Digits 1-9 target stages 1-9 and 0 targets stage 10.
- **No app queries in the event-tap callback** — Workspace and cross-process Accessibility calls block keyboard delivery and can disable the event tap. Cache the frontmost bundle ID from `NSWorkspace.didActivateApplicationNotification`; quick-switch app priority is then only an in-memory exclusion-set lookup.

### State Management
- **Exclusion list must filter at ALL layers** — Discovery, launch, activation, reconciliation, and AXObserver.
- **Cross-stage activation = stage switch** — Don't duplicate windows. Exception: truly new windows go to active stage.
- **Stage labels are position-derived, not stored** — Stages have no `name` field. The displayed label is the 1-based array index (`stageLabel(forID:)` / `PlateData.name = "\(index + 1)"`), so create/delete/reorder need zero bookkeeping. Rename was removed entirely. Removing `Stage.name`/`AppSettings.defaultStageName` is Codable-forward-safe (JSONDecoder ignores leftover keys in existing state.json/settings.json).

### Window Lifecycle
- **All discovery paths must register tracking** — Windows enter the stage manager via three paths: startup reconciliation, app launch, and focus-change (Cmd+N). All three must call `registerTracking` to get `kAXUIElementDestroyedNotification` and `kAXTitleChangedNotification`. Missing any path causes ghost windows.
- **Only lifecycle events remove live assignments** — Absence from AX or `CGWindowList` never proves destruction; hidden and ordered-out windows disappear from those snapshots. Remove a live assignment on `kAXUIElementDestroyedNotification`, explicit exclusion/reset, or stage deletion.
- **App process exit makes assignments dormant** — Track every window-owning PID with an event-driven kernel process-exit source; keep `didTerminateApplicationNotification` only as a backup. Both signals must use one idempotent cleanup path. PID monitoring must survive AX observer pruning and must not depend on window visibility. An exit removes windows from the live stage view but persists their stage and position as dormant assignments. A later launch restores exact bundle/title matches, then complete one-to-one bundle matches for dynamic titles. There is no time-based expiry.
- **Desktop surface must not join all Spaces** — `.canJoinAllSpaces` causes the surface to follow into fullscreen Spaces, covering the fullscreen app. The surface only matters on the normal desktop.

### Persistence & Reconciliation
- **Window titles are NOT stable keys** — Terminal prompts, browser tabs, Slack channels all change titles between sessions. Reconciliation must fall back to bundleID-only matching when (bundleID, title) exact match fails.
- **Dormant assignments are persistent state** — Preserve them across Debut restarts and deliberate app quits as well as updater relaunches; macOS does not reliably distinguish those termination reasons. Purge them only through explicit window destruction, exclusion/reset, or stage deletion.
- **Prune only truly empty stages on restore** — Keep stages that have dormant assignments even when they currently have no live windows.
- **Focus-based starting stage** — On launch, query AX for the currently focused window, find its owning stage, and activate that stage instead of always stage 0.
