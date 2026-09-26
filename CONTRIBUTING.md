# Contributing to Debut

Use a GitHub issue to discuss bugs or substantial changes, then submit a focused
pull request from your fork. Include the problem, resulting behavior, and validation.
Use imperative commit subjects; release notes are generated from those subjects.

## Setup and verification

Requires Apple Silicon, macOS 26, and Xcode 26 with Swift 6.2 or later.

```bash
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift test --no-parallel
for test in Tests/CI/*.sh; do bash "$test" || exit; done
./scripts/build-app.sh
```

The Swift suite includes screenshot tests. Serial execution is required because
several suites block the main thread while other checks need main-queue work.
Add a failing regression test before changing behavior, then run the relevant
checks and the complete suite before submitting your pull request.

The build is at `.build/Debut.app`. The build script selects a local signing
identity when available and otherwise signs ad hoc. Distribution credentials are
not needed. `./scripts/rebuild.sh` replaces `/Applications/Debut.app` and launches
it; run it only when you want to replace your installed copy.

The global-input E2E harness runs in a disposable headless Tart VM with
`./scripts/tart-e2e.sh run`. Do not run it against an active desktop session.
Pull requests exercise nine focused window-move durations, including every value
from 40 through 80 ms. Release and manual E2E workflows exercise the full
41-value matrix, and so does the Tart VM by default.

While iterating on a change that does not touch input, focus, desktop topology,
or window-move timing, `./scripts/tart-e2e.sh run --duration-profile ordinary`
runs the nine pull-request values instead, and `--no-gallery` skips the glass
screenshot gallery; neither removes a behavioral assertion. Run the full profile
before submitting any change to those areas. An unknown profile is rejected
before anything is built or the VM is touched. The E2E executable's
`--harness-self-check` mode checks its assertion logic without injecting input.

## Project map

- `Sources/DebutCore`: models, macOS services, and views.
- `Sources/DebutApp`: application entry point and updater integration.
- `Sources/DebutE2E`, `Sources/DebutBenchmarks`, and the demo and performance
  fixtures: verification and reproducible captures.
- `Tests`: Swift unit/screenshot tests and shell contracts for packaging and CI.
- `scripts`: build, VM verification, media capture, and release tooling.

Read [architecture constraints](AGENTS.md), [settings](spec/settings.md),
[performance observability](docs/performance-observability.md), and
[release verification](docs/release-verification.md) when relevant to your change.
Release publication is handled by maintainers through GitHub Actions.

Keep personal editor, agent, and account configuration in local untracked files.
Do not put credentials or machine-specific workflow mandates in the repository.
