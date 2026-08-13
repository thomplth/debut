# Performance observability contract

Debut measures work only when an existing event occurs. It adds no polling or recurring timer. `diagnostic.json` is the offline source of truth; Instruments signposts, deterministic benchmark JSON, Tart artifacts, and anonymous summaries use the same `PerformanceOperation` names and millisecond units.

Plate presentation uses `overlay_end_to_end_visible` as its primary user-facing latency. The span begins when the event tap recognizes a non-repeating activation and ends when the overlay's reveal animation completes. `diagnostic.json.overlayPresentation` retains the latest 20 correlated traces, including main-actor delivery, fullscreen probing, intentional presentation delay, deadline overshoot, preparation, window ordering, render submission, reveal completion, preview capture, and wallpaper completion. Rejected and cancelled attempts remain local diagnostic traces but never enter the successful latency summary.

`overlay_render_submission` replaces the old `overlay_first_frame` name. It means AppKit drew pending content and Core Animation was flushed; it is not evidence that WindowServer displayed a physical frame. Installed-app performance validation may compare that marker and reveal completion against ScreenCaptureKit pixel observations.

## Workloads and measurement phases

| Profile | Stages | Windows | Processes |
| --- | ---: | ---: | ---: |
| typical | 4 | 12 | 4 |
| busy | 7 | 21 | 7 |
| stress | 10 | 50 | 10 |

Report cold launch, first use, and warm operation runs separately. Overlay traces retain orthogonal process-use, preview-cache, wallpaper, hosting-view, process-age, and workload dimensions. Every observation carries a random in-memory span ID plus an optional in-memory trace ID and geometric workload counts (stages, windows, dormant windows, processes, captures). IDs never leave local diagnostics and traces.

## Local schema and budgets

Durations use a monotonic clock and milliseconds. Event-driven process samples expose user/system CPU nanoseconds, physical and peak footprint bytes, thread count, wakeups, and disk bytes. CPU percentage is derived only between two valid samples. Each operation retains the latest 100 durations and reports median, p95, p99, and max. Diagnostics retain the latest 20 correlated observations per operation so high-frequency event taps cannot evict evidence for slower paths.

Tart baselines require at least 20 iterations where practical. A regression gates only when it exceeds both the absolute budget and the recorded baseline by the configured percentage. Hidden-idle checks use CPU, wakeups, memory growth, and layout/signpost activity. System budgets remain separate from deterministic algorithm responsiveness tests.

## Remote privacy contract

The remote allowlist is: schema version, event kind, app version, operating-system major version, workload class, overlay temperature class, canonical operation name/count, latency bucket, and aggregate anomaly count. Values are bucketed before enqueue. Expected volume is one session summary plus at most 19 anomaly records per installation day; each operation may contribute at most two anomaly records per day so a noisy capture path cannot crowd out UI latency. The queue holds at most 100 records.

Latency anomalies require at least 500 ms of delayed work. `hidden_idle` is excluded because its duration measures an expected inactive interval rather than execution latency; startup also prunes idle anomalies queued by older builds.

The denylist includes window titles, bundle IDs, app names, PIDs, CGWindowIDs, paths, screenshots, raw diagnostics, free-form error descriptions, locale/time zone, precise hardware identity, and persistent user or installation identifiers. No automatic SDK fields are accepted. Local diagnostics remain available when sharing is disabled.

## Commands

Run deterministic release benchmarks with `scripts/performance-test.sh`. Run installed-app scenarios with `scripts/tart-performance.sh run typical|busy|stress`. Record Instruments templates and quick-triage evidence with `scripts/profile.sh`; correlate `DebutOperation` correlation values with `diagnostic.json.performance.recent`.
