# Release verification and version migration

Verified against GitHub main `bba36cc` on 2026-09-08 (KHA-645): `v0.4.0`
was the latest stable release and included `appcast.xml`. Both `v0.3.0` and
`v0.4.0` had completed Developer ID signing and notarization. The original plan's
“first stable signing path has never run” premise was obsolete. Action SHA pins,
restricted secret file modes, cleanup, and read-only repository Actions defaults
were already present. Dependabot was missing. The three misclassified historical
dailies (`v0.1.1`, `v0.1.2`, `v0.2.1`) were corrected to GitHub prereleases;
`v0.4.0` remains latest stable.

The published `v0.4.0` DMG's EdDSA signature was independently verified against
the public key inside that artifact. Gatekeeper accepted the disk image and app.
The actual `v0.3.0` → `v0.4.0` Sparkle replacement and relaunch passed in a
separate headless Tart VM, using untouched, signed release binaries.

## Version records

Tags remain the sole release-version record. Known pre-migration daily tags
(`v0.1.1`, `v0.1.2`, `v0.2.1`, `v0.2.2`, `v0.3.1`, `v0.3.2`, `v0.4.1`,
`v0.4.2`, `v0.4.3`) are excluded from the stable baseline but remain reserved.
From `v0.4.0`, a manual patch therefore plans `v0.4.4`, not `v0.4.1`.

Nightlies target the next minor and use `v0.5.0-nightly.YYYYMMDD[.N]` tags.
Stable release notes start at the previous stable. Nightly notes and change
detection use the last release on the first-parent history, including a stable
publication, so unchanged commits do not produce repeated daily releases.

The full label is stamped into `DebutCore.version`; the bundle's short version
is numeric (`0.5.0`). A separate integer `CFBundleVersion` starts at 10000 and
increments for every publication across both channels. Each annotated tag records
it as `Debut-build: N`. The appcast uses that build, not the display version.
A nightly may consequently update to a later-published stable hotfix; returning
to the stable channel is intentional even if the nightly's display version is
higher. Tests run the actual Sparkle comparator across the migration boundary.

## Publication gates

The existing complete CI and E2E gates remain. Stable publication then builds,
signs, notarizes and staples the candidate; creates the appcast; verifies the
final DMG's signature and metadata against the packaged app; assesses Gatekeeper;
and runs a real Sparkle install from the previous stable release to the exact
candidate bytes. No tag is pushed until these checks pass. The commit freshness
check runs again immediately before the push. It is a snapshot, not a distributed
lock; the tag still always names the tested SHA.

The update harness checks a distinct relaunched PID, the installed executable's
path and byte equality with the candidate, the expected build, and code-signature
integrity. It does not re-sign release fixtures. Its local server changes only
the enclosure URL, leaving the DMG and EdDSA signature intact. Evidence includes
AX trees, HTTP requests, and the final result. The release workflow uses the same
guest harness on its disposable macOS runner; agent-driven local verification
always uses Tart, never the foreground developer session or a hosted fallback.

Run a local rehearsal with existing signed artifacts:

```bash
tart clone debut-e2e-tahoe debut-update-tahoe
./scripts/tart-update-e2e.sh baseline.dmg candidate.dmg appcast.xml 10000
```

Use a separate VM; the wrapper stops only `debut-update-tahoe` (overridable with
`DEBUT_UPDATE_VM`). Evidence is in `~/Library/Caches/Debut/TartUpdate/evidence`.
The release gate requires a previous signed stable release and fails rather than
silently skipping if none is available.

## Daily signing and recovery

KHA-648 enables Developer ID signing and notarization for nightlies. The
`daily-release` environment contains only the certificate, export password, and
App Store Connect notary key, plus the identity/key/issuer variables, and accepts
only `main`. The daily job binds that environment directly rather than relying
on reusable-workflow secret inheritance. Both channels invoke the same composite
publishing action. Daily validation refuses an unexpected Sparkle private key;
only stable publication can generate an appcast.

`verify-daily-signing.yml` is a manual, non-publishing rehearsal of that exact
signing action. It has `contents: read`, uses `dry-run: true`, and retains the
notarized DMG as a workflow artifact for inspection in Tart. Signing credentials
are removed on success and failure. It runs no GUI/E2E against the hosted runner.
Use it to verify credential provisioning without creating a GitHub release or
altering the stable feed.

Sparkle supports key rotation while keeping the other signing identity unchanged;
the EdDSA key is not permanently immutable. See [Sparkle's rotation rules](https://sparkle-project.org/documentation/#rotating-signing-keys).
Moving the latest feed to an older release can stop further distribution, but
cannot undo installed updates. Recovery requires a higher-build corrective release.
