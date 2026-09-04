# Debut Project Instructions

## Issue Lifecycle

- Linear is the source of truth for task scope, decisions, progress, and acceptance criteria.
- Before starting implementation works that involves creating a commit to the repo, create a Linear issue if the user did not specify one. If the user specified an issue, use that issue instead.
- Work with implementation plan decided moves to Todo.
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

`--no-parallel` is required, not a preference. Several suites block the main thread waiting on semaphores or sleeping, which starves main-queue work in whichever suite happens to run alongside them. Parallel runs therefore fail on timing rather than behaviour — the wallpaper-observer test fails almost every time, and the `SpaceController` suite flakes. Serial runs cost about three seconds and remove that whole class of false failure.

### Full E2E

Only run E2E for high-risk changes. Routine model, settings, copy, styling, and localized UI changes should use the relevant unit and screenshot tests instead.

High-risk changes include global keyboard handling, Accessibility integration, window discovery or lifecycle, space switching, overlay presentation, persistence reconciliation, app installation, and code signing.

When E2E is justified, prioritize the headless Tart VM first:

```bash
./scripts/tart-e2e.sh run
```

This runs the whole suite without taking over the foreground developer session; the script's own output is the authority on how many scenarios pass. Setup and evidence locations are documented in `docs/local-e2e.md`.

Tart delivers synthetic drags, so the two window-drop checks run there. GitHub-hosted macOS does not deliver them and skips those two; that skip is keyed on `GITHUB_ACTIONS` alone. A skip claimed for "virtualized macOS" was carried for a month on an extrapolation from the hosted runner, while the real cause of every pointer failure in the VM was stacked TCC alerts (KHA-612). Before attributing a failure to virtualization, check what else in the guest is failing with it.

All agent-initiated E2E validation must run inside the headless Tart VM. Never run `./scripts/e2e-test.sh` or otherwise run the E2E executable against the developer's foreground session: it displays the overlay, injects global input, and captures the live desktop. This prohibition has no last-resort exception, including physical-drag validation. If Tart is unavailable or the VM cannot exercise a scenario, stop and report that limitation; do not fall back to the foreground session or manually trigger a hosted workflow.

`./scripts/rebuild.sh` only builds, installs, and launches the app locally; it never runs E2E.

#### Disposable hosts start with one desktop, and a space is a desktop

A hosted runner and a freshly cloned Tart VM both log in with exactly one Space. Since spaces are desktops, such a host cannot switch a space, move a window across one, or time a switch — the whole architecture goes untested while the suite still reports green. `DebutE2E provision-desktops <n>` therefore runs before Debut launches, from `scripts/ci-e2e.sh` and `scripts/tart-e2e-guest.sh`. It is a separate invocation and never implied, so provisioning remains an explicit fixture operation confined to disposable hosts.

The desktop has to come from Mission Control's own add button, found on the Dock by the accessibility identifier `mc.spaces.add`. Seeding the Dock's `com.apple.spaces` plist is a dead end that looks like it works: the entry survives, and after a reboot the window server really does report a second Space — but every seeded desktop carries the *first* desktop's `id64`, so `SpaceService.index(of:in:)` maps them all to space 0. `killall Dock` does not apply the file at all. A duplicate identity is worse than a missing desktop, because the suite then passes against a broken map.

Before adding a check that needs two desktops, decide what it should do on a host that has one, and gate it on the precondition it actually has. Switching a space needs two spaces; the window-drop fixture needs an empty space after a populated one. Sharing one gate across checks with different needs hides them behind conditions they do not have.

## Releases

Releases are automated in GitHub Actions and are never cut by hand. Both paths gate on the full CI suite (`.github/workflows/ci.yml`) and the full E2E suite before anything is tagged or published.

- **Daily** (`release-daily.yml`) — a scheduled run bumps the patch number and publishes a GitHub prerelease when `main` has moved since the last tag, and skips when it has not. Daily releases never generate or modify the stable Sparkle appcast.
- **Manual** (`release-manual.yml`) — human triggered with a `minor` or `major` bump, and never skipped for want of new commits. A single explicit user request authorizes an agent to dispatch and monitor the release end to end; do not require a second confirmation. The resulting `.0` release is Developer ID-signed, notarized, isolated through the `stable-release` environment, and published to the stable automatic-update feed.

Automatic-update eligibility is a promotion decision, not a version comparison alone. `scripts/stable-update-eligibility.sh` must accept a release before an appcast is generated. Patch releases and every daily build are ineligible, even if their version is newer. The Sparkle EdDSA private key exists only in the protected `stable-release` environment; never expose it to the daily job.

Every job in a release run is pinned to the commit that triggered it, and `scripts/verify-release-commit.sh` aborts the publish if `main` has moved on since. Landing on `main` while a release is gating therefore does not ship an untested commit — it fails that release, and the next run picks the new commit up. Re-run the release rather than trying to rescue a failed one.

The next version comes from the tags alone, via `scripts/release-plan.sh`; nothing else records the current version. Release notes are the commit subjects in the range, so a vague commit message becomes a vague changelog entry.

The manual workflow's reusable publish job must keep `secrets: inherit`. GitHub otherwise resolves the called job's protected `stable-release` environment variables but leaves its environment secrets empty. The daily caller must not inherit secrets: it uses `daily-release`, and the Sparkle private key must remain unreachable from that path. `scripts/validate-release-credentials.sh` is the fail-fast guard for this wiring.

The `stable-release` environment deliberately has no required reviewer. Its custom deployment branch policy still permits only `main`, while the CI, E2E, commit-pinning, eligibility, signing, and notarization gates remain mandatory. This lets one explicit release request complete without a second approval while preserving the boundary that excludes daily and patch builds.

A release never commits and never pushes a branch. An earlier design that pushed a `Release vX.Y.Z` commit died at that push having already pushed its tag. The publish workflow instead tags the tested commit in place and pushes only the tag. Do not read the `Main Protection` ruleset as the thing that stops a branch push: it blocks deletion and force-push, not an ordinary update. The design holds because the workflow never attempts one.

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
- **Spaces are real macOS desktops** — A space is the desktop at the same index, and macOS is the source of truth for which desktop a window is on (`SpaceService.desktopIndex(forWindow:)`). Debut never creates or destroys one: `SLSSpaceCreate` returns an id no display manages. Switching a space forges a DockSwipe gesture; the whole point is that macOS reveals the desktop in one composited transition, so never AX-raise the target space's windows one by one.
- **A window is reassigned through the bridged window server, never by dragging it** — The plain private writes (`SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`, `SLSSetWindowListWorkspace`) all silently no-op on another process's window, and `SLSProcessAssignToSpace` pins the whole process. macOS 26's `SLSBridgedMoveWindowsToManagedSpaceOperation` does work cross-process, in ~3ms, with SIP enabled and no cursor movement — see `BridgedWindowManagement`. It has three silent preconditions and getting any of them wrong is a no-op rather than an error, so `canMoveWindows` gates the feature and `SpaceController.canRelocate(from:to:)` refuses a cross-space move outright when the bridge is inert. The model must never record a move the window server did not perform. The synthetic-drag path this replaced cost 1.7s and visibly drove the cursor; do not bring it back.
- **The switch setting is a duration, and only because Debut draws the transition** — The Dock ignores swipe progress and cuts straight to the target above roughly velocity 80, so a velocity slider is not a speed control: its whole usable range renders identically. `DockSwipeAnimation` posts Began, then timed Changed samples, then Ended, which is what makes a number in milliseconds honest. Progress saturates at one desktop per gesture — the instant path asks for 2 and still lands one hop — so an N-desktop jump is N driven gestures, not one ramped further.
- **The space list must equal the desktop list** — Nothing may add or remove a space independently of `reconcileSpacesWithDesktops`. In particular do not prune empty spaces: an empty desktop is still a desktop, and dropping it shifts every later space off the desktop it maps to.
- **Spaces cannot be reordered, and the drag handle is not coming back** — Reordering spaces means reordering desktops, and the Dock owns that order even though the window server performs the move. `SLSMoveManagedSpaceToDisplayIndex` really does reorder a desktop, instantly and with no visible transition, but the Dock keeps navigating by its own stale copy, so the forged swipe that switches a space lands on the wrong desktop afterwards; and the new order does not survive a reboot — measured across three VM trials, with `com.apple.spaces` never taking it in four minutes of polling and `killall Dock` making no difference. Reordering the space array alone is not an alternative: it would break the index-is-the-desktop identity every other rule here depends on. A permutation stored beside the desktop list would restore reordering at the cost of that identity; it was considered and rejected.
- **AX raise doesn't activate, and neither does AppKit** — `AXUIElementPerformAction(kAXRaiseAction)` only reorders the window within its app's stack, so something else has to move the front between processes. `NSRunningApplication.activate()` is not that something: macOS 14 downgraded it to an advisory request and declines it outright for a background *regular* application. Debut became one when it gained a Dock icon, and its overlay is a borderless status-level window that never takes activation, so every commit asked from the background and was refused — the MRU moved while the app stayed put, for a day, with a green suite. Front through the window server (`_SLPSSetFrontProcessWithOptions` with `kCPSUserGenerated`, via `FrontProcessManagement`), which is not advisory and names the window so the chosen one arrives rather than whichever the app last used. Keep AppKit only as the fallback. Never discard the return value of an activation call, and never let a mock hardcode success: a mock that cannot refuse proves Debut *asked*, never that macOS agreed, which is exactly how this stayed invisible.
- **Fronting a process does not move the keyboard, and the call that took it reports success either way** — Naming the window in `_SLPSSetFrontProcessWithOptions` decides which window arrives in front, not which one is key; the app's previously key window keeps the keyboard, which reads to the user as the switch having done nothing. Post the event a click on the window would have produced — a `CGSEventRecord` left mouse-**down**, no up, addressed by window ID and located far past any content so an app sanitizing the point cannot land it on a real control — through `SLPSPostEventRecordTo` (see `FrontProcessManagement.keyWindowEventRecord`). An up cancels the down before the app acts on it. Neither the front call nor the posted record answers anything about the outcome: `frontWindow` reported `via: windowServer` on 467 of 467 focuses while roughly one switch in five did nothing, so a front request is verified by reading `frontmostApplicationPID()` back afterwards and reporting `window_front_not_taken`. Confirm that verification path actually fires before trusting a run of zeroes — invert its comparison, rebuild, and check it reports on every switch.
- **A focus report names the app, not reliably the window** — Fronting a process makes macOS report focus on whichever of that app's windows it settles on, and for a multi-window app that is regularly one on a different space. Measured on the installed build: Debut fronted Dia's Space-3 window 4796 and macOS reported 4794, its Space-1 window. Read literally that is a user activation of a window the user never touched, so it takes the MRU head — and then Option-Tab offers a window on a space the user was never on, while the window actually in front drops to second, where selecting it looks like nothing happened. Both symptoms are that one misread. Debut knows which window it asked for, so `creditedActivation` credits the report answering its own request to that window, one-shot with a 1s failsafe so a request nothing answers cannot misread a later click. The in-flight and desktop-not-showing guards do not cover this: a same-space focus involves no switch, and the report resolves to a desktop that really is showing.
- **`kAXWindows` cannot see other Spaces** — `AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute)` only returns windows on the active Space plus windows assigned to every Space. Measured across 4 desktops: AX found 9 of 26 real windows; a per-desktop `SLSCopyWindowsWithOptionsAndTags` call (via `SpaceSwitching.windowLocations()`) found all 26. AX must never be used to enumerate which windows exist or which Space they're on — only to classify a window already reached through CG/SkyLight (see "AX role/subrole is a snapshot, not a verdict" below). `listWindows()` and `windowLocations()` source membership from CG plus SkyLight for exactly this reason.

### Screen Capture
- **`CGWindowListCreateImage` corrupts silently and per app** — macOS 15 obsoleted the family and the package no longer targets a version that can call it, so this is now a rule about capture paths in general rather than about one API. It did not fail cleanly and it did not fail uniformly: measured on macOS 26.5.2 across 21 live windows, 18 captured real content while Linear's windows came back a uniform gray image. Because most windows still looked right, the failure hid. Never treat a non-nil capture as proof of content; assert that a capture contains more than one distinct luminance value. Use ScreenCaptureKit wherever the result must actually contain screen content.
- **Capture cost is per window, not per pixel** — `SCScreenshotManager` costs 12–17ms per window regardless of requested size; 400px thumbnails measured the same as full resolution. Requesting smaller images is not a latency optimization, only a memory one. Capture concurrently (21 windows: 398ms serial vs 163ms concurrent), but expect sublinear scaling, since the same run burned 1.8s of CPU for 163ms of wall time. The only large win is capturing fewer windows.
- **Wallpaper cannot be resolved from its configuration** — providers such as `com.apple.NeptuneOneExtension` and `com.apple.wallpaper.extension.photos` generate images and expose no file, so the wallpaper store and `desktopImageURL` are both dead ends. Capture the pixels macOS already rendered instead.
- **`SCShareableContent.excludingDesktopWindows` describes the returned list, not your intent** — pass `true` so desktop windows stay *out* of that list, then hand the list to `SCContentFilter(display:excludingWindows:)` to get wallpaper without UI. Passing `false` puts the wallpaper in the list, and excluding it leaves the filter with nothing to composite: that fails at capture time with `-3811`, not at filter construction.

### Performance
- **Never leave NSHostingView attached when overlay is hidden** — SwiftUI continues layout passes on ordered-out windows, consuming 50%+ CPU. Remove the hosting view in hideOverlay() and recreate in showOverlay().
- **No polling/timers** — Use event-driven architecture only: AXObserver for focus changes, NSWorkspace notifications for app lifecycle.
- **AXObserver pattern** — Observe kAXFocusedWindowChangedNotification on the frontmost app only. Move the observer when didActivateApplicationNotification fires.
- **A launching app refuses observer registration, and the refusal is silent** — `AXObserverAddNotification` returns -25204 (`kAXErrorCannotComplete`) while the target's AX server is still coming up: measured for nine of nine freshly launched apps, whose servers stayed silent for the first 0.8–2.9s while `didActivateApplicationNotification` arrived 0.13–0.39s in. Discarding that return code and recording the pid anyway left the focused-window observer dead for the app's whole first activation, so focus moving between that app's own windows never reached `recordWindowActivation` and the MRU order became whatever a later reconcile appended. Nothing announces an AX server coming up, so recovery is a bounded retry rather than an event — the one place a timer is warranted — and it must stop on the first success, on the next activation, and on process exit. Never accept the first answer as final, and never record the pid on one you did not get.

### Keyboard Event Tap
- **Consume ALL events when overlay is active** — Return nil for both keyDown and keyUp. Passing keyUp through leaks to the active app.
- **Session vs overlay** — Cmd-held session and overlay visibility are separate states. Esc closes overlay but keeps session alive. Track via `spaceManagerActive` (EventTap) and `overlayVisible` (synced from SpaceController).
- **Check Option flag BEFORE bare Tab** — Prevents Cmd+Option+Tab being caught by the Cmd+Tab handler.
- **Global quick-switch uses configurable modifiers + 1-9** — Check both chords BEFORE Cmd-state tracking. The direct-space chord defaults to Control; the same-app chord defaults to Control+Option and falls back to the space MRU. Digit 0 does nothing.
- **No app queries in the event-tap callback** — Workspace and cross-process Accessibility calls block keyboard delivery and can disable the event tap. Cache the frontmost bundle ID from `NSWorkspace.didActivateApplicationNotification`; quick-switch app priority is then only an in-memory exclusion-set lookup.

### State Management
- **Exclusion list must filter at ALL layers** — Discovery, launch, activation, reconciliation, and AXObserver.
- **Activation moves the window, never the user** — A window cannot take focus on a desktop that is not showing, so a window activating "on another space" proves the stored assignment is stale, not that the user should be switched. Reacting with a space switch produced an observed live loop: the switch changed the Space, the Space change resynced the active space, and the next focus event switched straight back. Don't duplicate windows either — reassign, never copy.
- **Debut must follow desktops it did not switch** — Mission Control, Control+Arrow and clicking a window on another desktop all change the Space behind Debut's back. `NSWorkspace.activeSpaceDidChangeNotification` drives `desktopDidChange()`; without it the active space silently points at the desktop the user left.
- **A space switch cannot focus its window until the desktop has actually changed** — The Dock consumes the forged swipe asynchronously, so focusing straight after posting it focuses on the desktop being left, and macOS then restores its own per-Space focus as the transition settles and overwrites the choice. Measured on a desktop holding a single Calculator window: the switch landed on Finder every time but the first, while activating Calculator by hand a second later worked. The focus request is therefore held until `activeSpaceDidChangeNotification` confirms the desktop, and dropped if the user landed somewhere else. Don't "fix" this with a sleep or a timer — the notification is the signal.
- **Every reported event must refresh the diagnostic state block** — `diagnostic.json`'s `state` is the only way E2E observes a running session, and long stretches of a scenario (a held Tab, for example) report nothing but `.transient` events. Skipping `DiagnosticReporter`'s state provider for those levels leaves the block stale and silently breaks E2E while unit tests stay green.
- **Space labels are position-derived, not stored** — Spaces have no `name` field. The displayed label is the 1-based array index (`spaceLabel(forID:)` / `StageData.name = "\(index + 1)"`), so a change in the desktop list needs zero bookkeeping. Rename was removed entirely. Removing `Space.name`/`AppSettings.defaultSpaceName` is Codable-forward-safe (JSONDecoder ignores leftover keys in existing state.json/settings.json).

### Window Lifecycle
- **All discovery paths must register tracking** — Windows enter the space manager via three paths: startup reconciliation, app launch, and focus-change (Cmd+N). All three must call `registerTracking` to get `kAXUIElementDestroyedNotification` and `kAXTitleChangedNotification`. Missing any path causes ghost windows.
- **Only lifecycle events remove live assignments** — Absence from AX or `CGWindowList` never proves destruction; hidden and ordered-out windows disappear from those snapshots. Remove a live assignment on `kAXUIElementDestroyedNotification`, explicit exclusion/reset, or space deletion.
- **A destroyed window must be remembered as destroyed** — Presence in `CGWindowList` does not prove a window is alive any more than absence proves it is dead. An app can keep a dismissed window's backing surface listed for the rest of its life: Preview's Open panel was still reported at `layer=0`, `880x448`, on a resolved desktop four minutes after it closed, while AX correctly reported Preview had one window. Since discovery admits an AX-unknown window on CG evidence alone, retiring a window without recording the destruction means the next snapshot re-admits it as `reason: new`, and it then persists as a dormant assignment. Tombstone the ID against its owning PID — not unconditionally, because the window server recycles IDs, and the same ID under a different process is a different window. The tombstone must also outlive the launch that recorded it, because the leaked surface is bounded by the owning process's life and not by Debut's: OmniDiskSweeper's `Drive List` (28846) was retired on a destroy notification at 17:21, and a restart 46 minutes later re-admitted the still-listed surface and bound it to a dormant assignment as `reason: dormant_restored`, its preview capture failing `-3811` on the same tick. `retired-windows.json` persists `(windowID, ownerPID, ownerBundleID)` and is honoured only while that PID still runs that bundle ID. Restoring it has to evict as well as refuse: the assignment the state file brought back is already live, and every path that could later remove it is closed — the process is alive, CG still lists the surface, and the destroy notification has already been and gone.
- **AX enumerability is a presentation state, never evidence about a window** — Whether `kAXWindows` lists a window depends on which desktop is showing and whether its app is hidden, so it must never gate tracking, arming, or exclusion. Measured on one TextEdit process, same two window IDs, seconds apart: visible with its windows on a non-active desktop reported `axWindows=0`; hidden reported `axWindows=2`; unhidden on that same desktop reported `0` again — `axError=0` throughout. Hiding an app *reveals* its windows to AX. Subrole moves with the same state: one Preview window reported `AXStandardWindow` while visible and `AXDialog` in 12 of 12 samples while hidden. Requiring a per-window AX element before arming therefore fails on exactly the windows hardest to discover; lifecycle notifications register on the application element and need no window element at all.
- **AX role/subrole is a snapshot, not a verdict** — An app still warming up can report a standard window as a dialog or panel, so an untrackable classification must make the assignment dormant, never delete it. Deleting turns a momentary misreport into permanent layout loss: it stranded a browser's four windows, which then returned as `reason: new` and collapsed into the active space. Dormancy makes the same misreport self-healing on the next snapshot.
- **Every destructive assignment change must report** — A removal that emits no diagnostic event is unfalsifiable after the fact. The untrackable deletion above left no trace, so the log showed only a harmless-looking `windows_reconciled` summary and the damage had to be inferred from a later `reason: new`.
- **App process exit makes assignments dormant** — Track every window-owning PID with an event-driven kernel process-exit source; keep `didTerminateApplicationNotification` only as a backup. Both signals must use one idempotent cleanup path. PID monitoring must survive AX observer pruning and must not depend on window visibility. An exit removes windows from the live space view but persists their space and position as dormant assignments. A later launch restores exact bundle/title matches, then complete one-to-one bundle matches for dynamic titles. There is no time-based expiry.
- **A window with no single desktop is not on desktop 1, and not on the desktop showing either** — Windows assigned to every Space (Finder, on some systems) and windows on a fullscreen Space report no sole index. Absence of an answer means "leave the assignment alone". Reading it as index 0 sweeps those windows onto the first space; reading it as the desktop currently showing is subtler and was briefly live — an activated Finder window followed the user from space to space, because focus is not evidence of location for a window that exists everywhere. Only a positive index may move a window that already belongs to a space. The showing desktop is a fair guess only for a window Debut has never seen, which has no assignment to destroy.
- **The desktop macOS reports for a window does not depend on which desktop is showing, and neither does the `CGWindowList` snapshot** — An earlier note here claimed the CG snapshot was less than half as long from the emptier desktop; KHA-560 re-measured with `CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements])` across 4 desktops and got all 26 real windows back regardless of which desktop was active, so that claim was wrong and is retracted. What still holds: desktop-index answers can be trusted from anywhere, and absence from a list still proves nothing about destruction (see "Only lifecycle events remove live assignments" above). The API whose *list* is Space-limited is AX, not CG — see "`kAXWindows` cannot see other Spaces" under macOS Window Management.

### Persistence & Reconciliation
- **Window titles are NOT stable keys** — Terminal prompts, browser tabs, Slack channels all change titles between sessions. Reconciliation must fall back to bundleID-only matching when (bundleID, title) exact match fails.
- **Dormant assignments are persistent state** — Preserve them across Debut restarts and deliberate app quits as well as updater relaunches; macOS does not reliably distinguish those termination reasons. Purge them only through explicit window destruction, exclusion/reset, or space deletion.
- **Prune only truly empty spaces on restore** — Keep spaces that have dormant assignments even when they currently have no live windows.
- **Focus-based starting space** — On launch, query AX for the currently focused window, find its owning space, and activate that space instead of always space 0.
