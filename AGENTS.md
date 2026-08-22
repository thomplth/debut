# Debut Project Instructions

## Issue Lifecycle

- Linear is the source of truth for task scope, decisions, progress, and acceptance criteria.
- Before starting work, create a Linear issue if the user did not specify one. If the user specified an issue, use that issue instead.
- Completed work moves to Review.
- Only humans move issues to Done or close them.

## Task Workflow

For every task:

1. Always work in a clean, isolated Git worktree. Do not make task changes directly in the primary checkout.
2. Use one task per worktree. Keep commits scoped and write imperative commit messages. Prefix every commit message with its Linear issue ID (for example, `KHA-123: Fix window ordering`). Do not prescribe issue IDs in branch names.
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
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift test --no-parallel
./scripts/build-app.sh
pkill -f "Debut.app" || true
rm -rf /Applications/Debut.app
cp -R .build/Debut.app /Applications/Debut.app
open /Applications/Debut.app
```

Never leave code changes uninstalled — the installed app must always match the source.

`--no-parallel` is required, not a preference. Several suites block the main thread waiting on semaphores or sleeping, which starves main-queue work in whichever suite happens to run alongside them. Parallel runs therefore fail on timing rather than behaviour — the wallpaper-observer test fails almost every time, and the `StageController` suite flakes. Serial runs cost about three seconds and remove that whole class of false failure.

### Full E2E

Only run E2E for high-risk changes. Routine model, settings, copy, styling, and localized UI changes should use the relevant unit and screenshot tests instead.

High-risk changes include global keyboard handling, Accessibility integration, window discovery or lifecycle, stage switching, overlay presentation, persistence reconciliation, app installation, and code signing.

When E2E is justified, prioritize the headless Tart VM first:

```bash
./scripts/tart-e2e.sh run
```

This runs the stable virtualized suite without taking over the foreground developer session. It explicitly skips the synthetic drag gestures that neither Tart nor GitHub-hosted macOS delivers; the script's own output is the authority on how many scenarios pass. Setup and evidence locations are documented in `docs/local-e2e.md`.

Use `./scripts/tart-e2e.sh run-all` only when diagnosing those virtualized drag checks. If Tart is unavailable, use the free GitHub-hosted macOS 26 workflow in `.github/workflows/e2e.yml` as the fallback or remote confirmation. Do not manually trigger or wait for E2E on routine changes merely because the hosted workflow exists.

`./scripts/e2e-test.sh` runs against the foreground developer session and is a last resort for validating physical drag delivery. Warn the user before running it because it displays the overlay, injects global input, and captures the live desktop.

`./scripts/rebuild.sh` only builds, installs, and launches the app locally; it never runs E2E.

## Releases

Releases are automated in GitHub Actions and are never cut by hand. Both paths gate on the full CI suite (`.github/workflows/ci.yml`) and the full E2E suite before anything is tagged or published.

- **Daily** (`release-daily.yml`) — a scheduled run bumps the patch number and publishes when `main` has moved since the last tag, and skips when it has not.
- **Manual** (`release-manual.yml`) — human triggered with a `minor` or `major` bump, and never skipped for want of new commits.

Every job in a release run is pinned to the commit that triggered it, and `scripts/verify-release-commit.sh` aborts the publish if `main` has moved on since. Landing on `main` while a release is gating therefore does not ship an untested commit — it fails that release, and the next run picks the new commit up. Re-run the release rather than trying to rescue a failed one.

The next version comes from the tags alone, via `scripts/release-plan.sh`; nothing else records the current version. Release notes are the commit subjects in the range, so a vague commit message becomes a vague changelog entry.

A release never commits and never pushes a branch. The `Main Protection` ruleset forbids any bot from updating `main`, and an earlier design that pushed a `Release vX.Y.Z` commit died at that push having already pushed its tag. The publish workflow instead tags the tested commit in place and pushes only the tag, which the ruleset does not cover.

`scripts/apply-version.sh` therefore stamps the version into `Sources/DebutCore/DebutCore.swift` and `Resources/Info.plist` for the build only — those edits are deliberately thrown away. Both files must keep their current shape for the stamp to land. What is checked in stays `0.0.0-dev`, so a build reporting that version is telling you it is not a release. Do not "fix" it to a real number.

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

## Architecture Rules

### macOS Window Management
- **CGWindowIDs are ephemeral** — they change between app restarts. Never persist them directly. Use (bundleID, windowTitle) as the stable key for cross-session matching.
- **AX position clamping** — macOS keeps 40px of every window visible on all sides via AX. Cannot be bypassed. Don't use position-based window hiding.
- **SLS/CGS private APIs** (SLSSetWindowAlpha, SLSMoveWindow, etc.) only work on windows owned by the calling process. They silently no-op on other processes' windows without SIP disabled.
- **Stages are real macOS desktops** — A stage is the desktop at the same index, and macOS is the source of truth for which desktop a window is on (`SpaceService.desktopIndex(forWindow:)`). Debut never creates or destroys one: `SLSSpaceCreate` returns an id no display manages. Switching a stage forges a high-velocity DockSwipe so the Dock snaps instead of animating; the whole point is that macOS reveals the desktop in one composited transition, so never AX-raise the target stage's windows one by one.
- **A window is reassigned through the bridged window server, never by dragging it** — The plain private writes (`SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`, `SLSSetWindowListWorkspace`) all silently no-op on another process's window, and `SLSProcessAssignToSpace` pins the whole process. macOS 26's `SLSBridgedMoveWindowsToManagedSpaceOperation` does work cross-process, in ~3ms, with SIP enabled and no cursor movement — see `BridgedWindowManagement`. It has three silent preconditions and getting any of them wrong is a no-op rather than an error, so `canMoveWindows` gates the feature and `StageController.canRelocate(from:to:)` refuses a cross-stage move outright when the bridge is inert. The model must never record a move the window server did not perform. The synthetic-drag path this replaced cost 1.7s and visibly drove the cursor; do not bring it back.
- **The stage list must equal the desktop list** — Nothing may add or remove a stage independently of `reconcileStagesWithDesktops`. In particular do not prune empty stages: an empty desktop is still a desktop, and dropping it shifts every later stage off the desktop it maps to.
- **AX raise doesn't activate** — AXUIElementPerformAction(kAXRaiseAction) only reorders the window within its app's stack. Always also call NSRunningApplication.activate() on the target app.

### Screen Capture
- **`CGWindowListCreateImage` corrupts silently and per app** — macOS 15 obsoleted the family and the package no longer targets a version that can call it, so this is now a rule about capture paths in general rather than about one API. It did not fail cleanly and it did not fail uniformly: measured on macOS 26.5.2 across 21 live windows, 18 captured real content while Linear's windows came back a uniform gray image. Because most windows still looked right, the failure hid. Never treat a non-nil capture as proof of content; assert that a capture contains more than one distinct luminance value. Use ScreenCaptureKit wherever the result must actually contain screen content.
- **Capture cost is per window, not per pixel** — `SCScreenshotManager` costs 12–17ms per window regardless of requested size; 400px thumbnails measured the same as full resolution. Requesting smaller images is not a latency optimization, only a memory one. Capture concurrently (21 windows: 398ms serial vs 163ms concurrent), but expect sublinear scaling, since the same run burned 1.8s of CPU for 163ms of wall time. The only large win is capturing fewer windows.
- **Wallpaper cannot be resolved from its configuration** — providers such as `com.apple.NeptuneOneExtension` and `com.apple.wallpaper.extension.photos` generate images and expose no file, so the wallpaper store and `desktopImageURL` are both dead ends. Capture the pixels macOS already rendered instead.
- **`SCShareableContent.excludingDesktopWindows` describes the returned list, not your intent** — pass `true` so desktop windows stay *out* of that list, then hand the list to `SCContentFilter(display:excludingWindows:)` to get wallpaper without UI. Passing `false` puts the wallpaper in the list, and excluding it leaves the filter with nothing to composite: that fails at capture time with `-3811`, not at filter construction.

### Performance
- **Never leave NSHostingView attached when overlay is hidden** — SwiftUI continues layout passes on ordered-out windows, consuming 50%+ CPU. Remove the hosting view in hideOverlay() and recreate in showOverlay().
- **No polling/timers** — Use event-driven architecture only: AXObserver for focus changes, NSWorkspace notifications for app lifecycle.
- **AXObserver pattern** — Observe kAXFocusedWindowChangedNotification on the frontmost app only. Move the observer when didActivateApplicationNotification fires.

### Keyboard Event Tap
- **Consume ALL events when overlay is active** — Return nil for both keyDown and keyUp. Passing keyUp through leaks to the active app.
- **Session vs overlay** — Cmd-held session and overlay visibility are separate states. Esc closes overlay but keeps session alive. Track via `stageManagerActive` (EventTap) and `overlayVisible` (synced from StageController).
- **Check Option flag BEFORE bare Tab** — Prevents Cmd+Option+Tab being caught by the Cmd+Tab handler.
- **Global quick-switch uses configurable modifiers + 1-9** — Check both chords BEFORE Cmd-state tracking. The direct-stage chord defaults to Control; the same-app chord defaults to Control+Option and falls back to the stage MRU. Digit 0 does nothing.
- **No app queries in the event-tap callback** — Workspace and cross-process Accessibility calls block keyboard delivery and can disable the event tap. Cache the frontmost bundle ID from `NSWorkspace.didActivateApplicationNotification`; quick-switch app priority is then only an in-memory exclusion-set lookup.

### State Management
- **Exclusion list must filter at ALL layers** — Discovery, launch, activation, reconciliation, and AXObserver.
- **Activation moves the window, never the user** — A window cannot take focus on a desktop that is not showing, so a window activating "on another stage" proves the stored assignment is stale, not that the user should be switched. Reacting with a stage switch produced an observed live loop: the switch changed the Space, the Space change resynced the active stage, and the next focus event switched straight back. Don't duplicate windows either — reassign, never copy.
- **Debut must follow desktops it did not switch** — Mission Control, Control+Arrow and clicking a window on another desktop all change the Space behind Debut's back. `NSWorkspace.activeSpaceDidChangeNotification` drives `desktopDidChange()`; without it the active stage silently points at the desktop the user left.
- **A stage switch cannot focus its window until the desktop has actually changed** — The Dock consumes the forged swipe asynchronously, so focusing straight after posting it focuses on the desktop being left, and macOS then restores its own per-Space focus as the transition settles and overwrites the choice. Measured on a desktop holding a single Calculator window: the switch landed on Finder every time but the first, while activating Calculator by hand a second later worked. The focus request is therefore held until `activeSpaceDidChangeNotification` confirms the desktop, and dropped if the user landed somewhere else. Don't "fix" this with a sleep or a timer — the notification is the signal.
- **Every reported event must refresh the diagnostic state block** — `diagnostic.json`'s `state` is the only way E2E observes a running session, and long stretches of a scenario (a held Tab, for example) report nothing but `.transient` events. Skipping `DiagnosticReporter`'s state provider for those levels leaves the block stale and silently breaks E2E while unit tests stay green.
- **Stage labels are position-derived, not stored** — Stages have no `name` field. The displayed label is the 1-based array index (`stageLabel(forID:)` / `PlateData.name = "\(index + 1)"`), so create/delete/reorder need zero bookkeeping. Rename was removed entirely. Removing `Stage.name`/`AppSettings.defaultStageName` is Codable-forward-safe (JSONDecoder ignores leftover keys in existing state.json/settings.json).

### Window Lifecycle
- **All discovery paths must register tracking** — Windows enter the stage manager via three paths: startup reconciliation, app launch, and focus-change (Cmd+N). All three must call `registerTracking` to get `kAXUIElementDestroyedNotification` and `kAXTitleChangedNotification`. Missing any path causes ghost windows.
- **Only lifecycle events remove live assignments** — Absence from AX or `CGWindowList` never proves destruction; hidden and ordered-out windows disappear from those snapshots. Remove a live assignment on `kAXUIElementDestroyedNotification`, explicit exclusion/reset, or stage deletion.
- **AX role/subrole is a snapshot, not a verdict** — An app still warming up can report a standard window as a dialog or panel, so an untrackable classification must make the assignment dormant, never delete it. Deleting turns a momentary misreport into permanent layout loss: it stranded a browser's four windows, which then returned as `reason: new` and collapsed into the active stage. Dormancy makes the same misreport self-healing on the next snapshot.
- **Every destructive assignment change must report** — A removal that emits no diagnostic event is unfalsifiable after the fact. The untrackable deletion above left no trace, so the log showed only a harmless-looking `windows_reconciled` summary and the damage had to be inferred from a later `reason: new`.
- **App process exit makes assignments dormant** — Track every window-owning PID with an event-driven kernel process-exit source; keep `didTerminateApplicationNotification` only as a backup. Both signals must use one idempotent cleanup path. PID monitoring must survive AX observer pruning and must not depend on window visibility. An exit removes windows from the live stage view but persists their stage and position as dormant assignments. A later launch restores exact bundle/title matches, then complete one-to-one bundle matches for dynamic titles. There is no time-based expiry.
- **A window with no single desktop is not on desktop 1, and not on the desktop showing either** — Windows assigned to every Space (Finder, on some systems) and windows on a fullscreen Space report no sole index. Absence of an answer means "leave the assignment alone". Reading it as index 0 sweeps those windows onto the first stage; reading it as the desktop currently showing is subtler and was briefly live — an activated Finder window followed the user from stage to stage, because focus is not evidence of location for a window that exists everywhere. Only a positive index may move a window that already belongs to a stage. The showing desktop is a fair guess only for a window Debut has never seen, which has no assignment to destroy.
- **The desktop macOS reports for a window does not depend on which desktop is showing, but the window *list* does** — Verified by enumerating every window from two different desktops: every window common to both reported the same index. The `CGWindowList` snapshot, though, was less than half as long from the emptier desktop. Desktop answers can be trusted from anywhere; absence from the list still proves nothing.

### Persistence & Reconciliation
- **Window titles are NOT stable keys** — Terminal prompts, browser tabs, Slack channels all change titles between sessions. Reconciliation must fall back to bundleID-only matching when (bundleID, title) exact match fails.
- **Dormant assignments are persistent state** — Preserve them across Debut restarts and deliberate app quits as well as updater relaunches; macOS does not reliably distinguish those termination reasons. Purge them only through explicit window destruction, exclusion/reset, or stage deletion.
- **Prune only truly empty stages on restore** — Keep stages that have dormant assignments even when they currently have no live windows.
- **Focus-based starting stage** — On launch, query AX for the currently focused window, find its owning stage, and activate that stage instead of always stage 0.
