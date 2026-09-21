# Performance observability contract

Performance recording is triggered by existing work; it adds no recurring window-discovery poll. Bounded animation, retry, verification, and presentation schedules remain part of the app behavior. `diagnostic.json` is the offline source of truth; Instruments signposts, deterministic benchmark JSON, and Tart artifacts use the same `PerformanceOperation` names and millisecond units.

Stage presentation uses `overlay_end_to_end_visible` as its primary user-facing latency. The span begins when the event tap recognizes a non-repeating activation and ends when the overlay's reveal animation completes. `diagnostic.json.overlayPresentation` retains the latest 20 correlated traces, including main-actor delivery, fullscreen probing, intentional presentation delay, deadline overshoot, preparation, window ordering, render submission, reveal completion, and preview capture. Wallpaper fields remain in the schema for compatibility, but the current overlay reports wallpaper as unavailable: Debut no longer captures or draws a desktop backdrop. Rejected and cancelled attempts remain local diagnostic traces but never enter the successful latency summary.

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

Report cold launch, first use, and warm operation runs separately. Overlay traces retain orthogonal process-use, preview-cache, legacy wallpaper, hosting-view, process-age, and workload dimensions. Every observation carries a random in-memory span ID plus an optional in-memory trace ID and geometric workload counts (spaces, windows, dormant windows, processes, captures). IDs never leave local diagnostics and traces.

## Local schema and budgets

Durations use a monotonic clock and milliseconds. Event-driven process samples expose user/system CPU nanoseconds, physical and peak footprint bytes, thread count, wakeups, and disk bytes. CPU percentage is derived only between two valid samples. Each operation retains the latest 100 durations and reports median, p95, p99, and max. Diagnostics retain the latest 20 correlated observations per operation so high-frequency event taps cannot evict evidence for slower paths.

Tart baselines require at least 20 iterations where practical. A regression gates only when it exceeds both the absolute budget and the recorded baseline by the configured percentage. Hidden-idle checks use CPU, wakeups, memory growth, and layout/signpost activity. System budgets remain separate from deterministic algorithm responsiveness tests.

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
window, and `wallpaper_capture` remains in the schema without an active production
wallpaper-capture path.

Installed-app input and pixel validation runs in Tart. Profiling commands that
only inspect an existing process are distinct from the global-input E2E harness.
