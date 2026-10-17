# Performance observability contract

Performance recording is triggered by existing work; it adds no recurring window-discovery poll. Bounded animation, retry, verification, and presentation schedules remain part of the app behavior. `diagnostic.json` is the offline source of truth; Instruments signposts, deterministic benchmark JSON, and Tart artifacts use the same `PerformanceOperation` names and millisecond units.

Stage presentation uses `overlay_end_to_end_visible` as its primary user-facing latency. The span begins when the event tap recognizes a non-repeating activation and ends when the overlay's reveal animation completes. `diagnostic.json.overlayPresentation` retains the latest 20 correlated traces, including main-actor delivery, fullscreen probing, intentional presentation delay, deadline overshoot, preparation, window ordering, render submission, reveal completion, and preview capture. Debut does not capture or draw a desktop backdrop, so traces have no wallpaper phase or state. Rejected and cancelled attempts remain local diagnostic traces but never enter the successful latency summary.

`overlay_render_submission` replaces the old `overlay_first_frame` name. It means AppKit drew pending content and Core Animation was flushed; it is not evidence that WindowServer displayed a physical frame. Installed-app performance validation may compare that marker and reveal completion against ScreenCaptureKit pixel observations inside the headless Tart VM.

## Responsiveness policy

Debut holds a process-lifetime `userInitiatedAllowingIdleSystemSleep` activity so App Nap cannot demote its global switcher while the app has no ordinary visible window. The assertion still permits idle system sleep. The event-tap thread, its main-queue delivery block, and user-driven desktop switch/move workers use interactive QoS; diagnostics and persistence remain utility work.

Overlay invocation is cache-only for cross-process state. Focus identity and geometry come from event-driven window discovery, and desktop topology comes from the most recent launch, desktop-change, or display-change read. The invocation path must not add a synchronous AX or WindowServer query. External AX, WindowServer, and process reads have separate bounded scheduler lanes so one unresponsive dependency cannot consume every worker.

`diagnostic.json` still represents every reported state transition, but snapshot writes are coalesced over a 50 ms burst window. `flush()` forces the newest pending snapshot for tests and exporters. Durable lifecycle JSONL records are never coalesced.

## Workloads and measurement phases

| Profile | Stages (desktops) | Windows | Processes |
| --- | ---: | ---: | ---: |
| typical | 4 | 12 | 4 |
| busy | 7 | 21 | 7 |
| stress | 10 | 50 | 10 |

Report cold launch, first use, and warm operation runs separately. Overlay traces retain orthogonal process-use, preview-cache, hosting-view, process-age, and workload dimensions. Every observation carries a random in-memory span ID plus an optional in-memory trace ID and geometric workload counts (spaces, windows, dormant windows, processes, captures). IDs never leave local diagnostics and traces.

## Local schema and budgets

Durations use a monotonic clock and milliseconds. Event-driven process samples expose user/system CPU nanoseconds, physical and peak footprint bytes, thread count, wakeups, and disk bytes. CPU percentage is derived only between two valid samples. Each operation retains the latest 100 durations and reports median, p95, p99, and max. Diagnostics retain the latest 20 correlated observations per operation so high-frequency event taps cannot evict evidence for slower paths.

Tart baselines require at least 20 iterations where practical. A regression gates only when it exceeds both the absolute budget and the recorded baseline by the configured percentage. Hidden-idle checks use CPU, wakeups, memory growth, and layout/signpost activity. System budgets remain separate from deterministic algorithm responsiveness tests.

## Preview freshness and capture cost

Every overlay session that reaches its reveal writes one durable `preview_freshness` event when
it closes. It records what the cards showed at the reveal (`cards`, `withPreview`, median and
maximum preview age, `shapeMismatches` for previews drawn letterboxed because the window changed
shape, `pendingCaptures`) and what changed while the overlay was up: `replacementsAfterReveal`
(a card's image swapped for a newer one), `fillsAfterReveal` (an app icon replaced by a
preview), and the first and last change in milliseconds after the reveal. A replacement after
the reveal is a change the user could see happen; the goal is none.

Each capture batch reports `preview_capture_batch` (reason, the window IDs asked for, requested,
captured, discarded, failed, `fellBack` for captures the -3811 fallback took, and wall time).
Wall time leaves out any time capture was suspended while the batch waited, reported separately
as `suspendedMilliseconds`. Batches roll up into a durable `preview_capture_rollup` once an hour
has passed: captures by reason, and captures per user action (`capturesPerReveal`,
`capturesPerDesktopArrival`, `capturesPerFocusChange`, with the action counts). Capture power
scales with the capture count, and a per-action rate is what can tell use of the Mac from idle
time; a wall-clock rate cannot. Each capture costs ~80 CPU-ms in macOS's privacy services
regardless of the ScreenCaptureKit API (capbench, 2026-10-13). The rollup is emitted by the first
batch after the hour, not by a timer, and closes when capture is suspended, so it never spans a
locked screen.

Captures go through `PreviewCaptureScheduler`: one batch in flight at a time, captured one
window after another in priority order (selected card, its stage, other stages, background).
Concurrent captures measured slower in total on macOS 27. A request for a window already being
captured is dropped, and an overlay open reorders queued work instead of cancelling it.
ScreenCaptureKit window handles are held between captures and the window list is fetched again
only for a window that is missing; captures are sized from Debut's tracked window bounds,
because a held handle keeps the frame it was enumerated with.

Between overlay opens, previews are kept current by window events. Focus leaving a window and
a desktop switch that has settled capture at once: each is evidence the change is over. A
settled switch captures only the arriving windows whose previews are older than the preview
TTL, so switching back and forth does not recapture what the last visit just captured. Focus
arriving, a resize, a title change and a new window restart a per-window timer, and the capture
fires once the window has been quiet for a second, and only if it is on a showing desktop. There
is no maximum wait. A title change captures a window at most once every 30 seconds from its last
capture, taking the trailing change, and never captures the focused window, which focus leaving
it captures instead. An overlay open takes over any capture still waiting. Background capture
stops while the screen is locked, the displays sleep or another session is in front.

At an overlay open, the window in use when the shortcut was pressed is captured straight away,
before the reveal, since focus has not left it and no background capture has seen its current
content; everything else that is stale is captured after the reveal. Age alone (the TTL) makes a
preview stale only for a window on a showing desktop; a window elsewhere is refreshed when its
desktop settles into view.

### Development-only measurements

Measurements that cost real work run only when `DebutCore.version` is `0.0.0-dev` in the Debut
app itself (`DevelopmentMeasurements.isEnabled`); release builds never pay for them:

- a visual change score for every replacement after the reveal (mean luminance difference on a
  16x16 grid, in percent): `changesScored`, `visibleChanges` (score >= 2%), maximum and mean
- `preview_capture_batch` becomes durable instead of transient
- each rollup adds the interval's CPU milliseconds for `WindowServer`, `ControlCenter`,
  `replayd` and Debut, and energy in millijoules where the kernel reports it to an unprivileged
  reader. Root-owned daemons are read through `ps`. These are system-wide figures, so another
  app recording the screen is counted too. Over the KHA-1100 review, `replayd` CPU and
  `ControlCenter` energy tracked the capture count; `tccd` and `systemstatusd` did not.

Reading Debut's own process counters (~5 us per read) stays on in every build.

## Local-only boundary

Performance observations remain on the Mac. They feed `diagnostic.json`, local
signposts, deterministic benchmark output, and user-initiated diagnostic exports.
The app does not queue or transmit performance summaries. Diagnostic exports are
redacted as described in the [privacy notice](privacy.md).

## Commands

Run deterministic release benchmarks with `scripts/performance-test.sh`. Run installed-app scenarios with `scripts/tart-performance.sh run typical|busy|stress`. Record Instruments templates and quick-triage evidence with `scripts/profile.sh`; correlate `DebutOperation` correlation values with `diagnostic.json.performance.recent`.

## Interpreting desktop measurements

`space` remains the implementation/schema name for a stage. A stage belongs to a
display stack and represents a normal macOS desktop. Model updates and request
spans can finish before macOS confirms a switch, so a `space_switch` duration
alone is not proof of settled desktop pixels or delivered window focus. Use
confirmation and focus-delivery evidence alongside request timing. Likewise,
`space_raise` is a retained operation name, not an instruction to AX-raise every
window.

Installed-app input and pixel validation runs in Tart. Profiling commands that
only inspect an existing process are distinct from the global-input E2E harness.

## E2E verification cost

Every local Tart run writes `report.json` under `~/Library/Caches/Debut/TartE2E/runs/<run-id>/`
with host phases (build, queue, stage, boot, provision, guest, collect), guest phases, check
results, and CPU: `buildCpuSeconds` for the host build and `suiteVmCpuSeconds` for the
Virtualization processes during the guest session. Compare runs by those fields rather than by
one wall-clock total; queue time is waiting, not work.

Measured on a 12-core Apple Silicon host on 2026-09-26. Build is the ~38 s release rebuild after a
one-file DebutCore edit (whole-module optimization); a true no-op build is ~8 s.

| Run | Boot | Guest | VM CPU |
| --- | ---: | ---: | ---: |
| Every group, 41-duration sweep, gallery (the former default) | 20 s | 338 s | 538 s |
| Every group, 9-duration profile, no gallery | 20 s | 216 s | 330 s |
| `drag-drop` alone | 23 s | 32 s | 55 s |
| `desktop-navigation` alone (swipes, Control-arrow) | 22 s | 51 s | 88 s |
| `smoke,overlay-input,drag-drop,fullscreen,rendering` (a narrow overlay change's gate) | 31 s | 82 s | 99 s |

Single groups take 24–76 s in the guest (`permissions`, the three TCC journeys, is the
slowest). With the rebuild, focused feedback is about 1.5 minutes for drag-drop and
under 2 minutes for desktop navigation.

A narrow overlay change iterated five times cost about 5 × 397 s ≈ 33 minutes of Tart runner
time and ≈ 2,700 VM CPU-seconds when every attempt ran the whole default suite. Iterating four
times on `drag-drop` and running `scripts/verify.sh affected` once costs about 4 × 93 s + 196 s
(contracts, Swift suite and the five-group gate) ≈ 9.5 minutes and ≈ 320 VM CPU-seconds: about
70% less time and 88% less VM CPU. These totals are modelled from the measured phases above,
not observed as one task. A change to shared input, focus, topology or movement still ends with
the full suite (about 6 minutes of guest time); iterating on its group first still saves about
half.
