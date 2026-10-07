# Test reliability

Hosted macOS runners are small shared VMs, far slower than a development Mac. A
test with a timing margin can pass every local run and still fail a fifth of CI
runs. Three such checks blocked a stable release; each rule below comes from one
of them. Apply these rules whenever a test waits, reads asynchronous evidence, or
coordinates concurrent processes.

## Wait for conditions, not durations

Never sleep a fixed time and then assert once. Poll the condition against a
generous deadline: a passing run returns as soon as the condition holds, and only
a failing run pays the full timeout.

- Swift tests: loop on the condition with a short `Task.sleep` until a deadline;
  `waitUntil` in `SpaceControllerTests.swift` shows the pattern.
- E2E: `waitFor` in `Sources/DebutE2E/main.swift`.
- Shell contracts: poll in a bounded `for` loop, as `TartQueueTests.sh` does.

A *not yet* assertion is safe with a fixed sleep: load can only delay work, so
checking that something has not happened by 120 ms stays true on a slow machine.
An *already done* assertion is not, and needs a wait.

*Example.* An overlay test slept 0.5 s for a tree rebase that follows a 0.36 s
spring, an AppKit completion handler and a main-queue hop. Under load the rebase
arrived up to 0.63 s after the check, which allowed 0.38 s.

## Await every piece of evidence together

When a check combines several signals, put all of them inside one wait. Do not
wait for one signal and then read the others once. Diagnostic events are written
asynchronously and coalesced, so `diagnostic.json` can trail the effect it
describes. In E2E, use `waitForClaimedNavigation` or an equivalent combined
condition. In unit tests, call the reporter's `flush()` rather than sleeping.

*Example.* A Control-arrow check waited for the desktop to change, then read the
events once. The desktop arrived before the coalesced write carried the claim.

## Do not act on one observation of another process

Reads of another process's state (`ps`, window-server lists, AX) can be briefly
wrong under load. A participant must not abandon its work or evict another
participant on a single read. Re-verify, or make the outcome recoverable.

*Example.* Tart queue waiters prune tickets whose owners look dead. One bad
start-time read deleted a live waiter's ticket, and the waiter gave up its run.
It now restores its own ticket and keeps its place.

## Make failures explain themselves

A check that fails without context sends the next investigator back to CI for
another sample. When a check combines conditions, log each input on failure:
readiness, baseline, observed state, and the relevant events. E2E failures also
save the diagnostic snapshot as `failure-<n>.json` in the evidence artifact.

## Stress timing-sensitive tests before landing

A single local pass says little about a race. Run a new or changed test several
times with every core saturated. Gate on the exit status, because the result
glyphs differ between local and CI output.

```bash
for i in $(seq "$(( $(sysctl -n hw.ncpu) * 2 ))"); do (yes > /dev/null &); done
for i in $(seq 10); do
  TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift test --skip-build \
    --filter '<test name>' >/dev/null 2>&1 || echo "run $i failed"
done
pkill yes
```

## Treat an intermittent CI failure as a bug

Before rerunning a failed check, search recent CI runs for the same check name.
A check that fails in more than one run is a defect in the test or the product,
even if a rerun passes. Fix the cause, and file it in the tracker if it cannot be
fixed now. Failing nightlies deserve the same scrutiny as a failing release.

```bash
gh run list --limit 15
gh api repos/<owner>/<repo>/actions/jobs/<job id>/logs | grep -E '✘|FAIL'
```
