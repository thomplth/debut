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

High-risk input, window-management, persistence, presentation, and signing changes
also need [headless Tart E2E](docs/local-e2e.md). Never drive the foreground desktop
with the E2E harness. Report unavailable VM coverage in the pull request.

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

Personal agent overrides and account configuration belong in local, untracked
files. Use Git's local exclude file (`git rev-parse --git-path info/exclude`) for
machine-specific paths; do not put credentials or personal workflow mandates in
shared contributor instructions.
