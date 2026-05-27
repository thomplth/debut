# Debut Project Instructions

## Build & Test Workflow

After any code change, always run the full cycle:
```bash
./scripts/rebuild.sh
```
This kills the running app, builds, installs to /Applications, launches, and runs E2E tests.

Never leave code changes uninstalled — the installed app must always match the source.

## Toolchain

This machine has a broken Swift Wasm toolchain in PATH. Always use:
```bash
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift
```
The convenience scripts (`rebuild.sh`, `e2e-test.sh`, `build-app.sh`) handle this automatically.

## Code Signing

Uses a self-signed "Debut Dev" certificate (persists in login keychain). This keeps Accessibility permissions stable across rebuilds. The build script auto-detects it.

## Tests

- Unit + screenshot tests: `TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift test`
- E2E only: `./scripts/e2e-test.sh`
- Full cycle: `./scripts/rebuild.sh`
