# Release verification and version migration

Releases are built by GitHub Actions from the exact commit that passed CI and E2E.
They tag that commit without creating a version commit or pushing a branch.
The checked-in version stays `0.0.0-dev`; the release build stamps its version,
feed, and public key temporarily. See [AGENTS.md](../AGENTS.md#releases) for the
operating rules.

- [Manual release](../.github/workflows/release-manual.yml) accepts a patch,
  minor, or major bump and publishes stable after the gates pass.
- [Nightly release](../.github/workflows/release-nightly.yml) publishes a next-minor
  prerelease when the tested main commit differs from the last released commit.
- Both use [the publishing action](../.github/actions/publish-release/action.yml);
  stable reaches it through the reusable publish workflow, while nightly binds
  its own environment directly.

## Version records

Tags remain the sole release-version record. Known pre-migration automated prerelease tags
(`v0.1.1`, `v0.1.2`, `v0.2.1`, `v0.2.2`, `v0.3.1`, `v0.3.2`, `v0.4.1`,
`v0.4.2`, `v0.4.3`) are excluded from the stable baseline but remain reserved.
For example, with `v0.4.0` as a stable baseline, a manual patch plans
`v0.4.4`, not the already-reserved `v0.4.1`. This is a migration example, not a
claim about the current latest release; `scripts/release-plan.sh` reads live tags.

Nightlies target the next minor and use `vX.Y.0-nightly.YYYYMMDD[.N]` tags.
Stable release notes start at the previous stable. Nightly notes and change
detection use the last release on the first-parent history, including a stable
publication, so unchanged commits do not produce repeated nightly releases.

The full label is stamped into `DebutCore.version`; the bundle's short version
is numeric (for example, `0.5.0`). A separate integer `CFBundleVersion` starts at 10000 and
increments for every publication across both channels. Each annotated tag records
it as `Debut-build: N`. The appcast uses that build, not the display version.
Stable and nightly releases now have separate appcast URLs and separate Sparkle
keypairs. A build accepts updates only from the channel stamped into its packaged
Info.plist. Existing nightlies from before this split retain their historical stable
feed; the first newly isolated nightly bootstraps the nightly feed, and subsequent
nightlies update only from a compatible nightly.

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
The stable release gate requires a previous signed stable release and fails rather
than silently skipping if none is available. The first isolated nightly has no
compatible predecessor and explicitly bootstraps its feed; later nightly releases
must pass the same real update test against the previous compatible nightly.

## Nightly signing and recovery

Nightlies require Developer ID signing and notarization (introduced by KHA-648). The
`nightly` environment contains the certificate, export password, App Store Connect
notary key, and a Sparkle keypair distinct from stable, and accepts only `main`.
The nightly job binds that environment directly rather than relying on reusable-workflow
secret inheritance. Both channels invoke the same composite publishing action and
generate independently signed appcasts. Validation refuses a nightly public key that
matches the checked-in stable identity.

`verify-nightly-signing.yml` is a manual, non-publishing rehearsal of that exact
signing action. It has `contents: read`, uses `dry-run: true`, and retains the
notarized DMG and signed nightly appcast as workflow artifacts for inspection in Tart. Signing credentials
are removed on success and failure. It runs no GUI/E2E against the hosted runner.
Use it to verify credential provisioning without creating a GitHub release or
altering either live feed.

GitHub's `releases/latest` URL excludes prereleases and remains the stable feed.
The permanent `nightly-feed` prerelease carries only the moving nightly `appcast.xml`;
the DMG referenced by that appcast remains attached to its immutable versioned nightly
release. Updating this carrier never changes the stable release or stable appcast.

Sparkle supports key rotation while keeping the other signing identity unchanged;
the EdDSA key is not permanently immutable. See [Sparkle's rotation rules](https://sparkle-project.org/documentation/#rotating-signing-keys).
Moving the latest feed to an older release can stop further distribution, but
cannot undo installed updates. Recovery requires a higher-build corrective release.

## Historical verification evidence

The following records the KHA-645 audit on 2026-09-08; it does not identify the
latest release today or substitute for a new candidate's publication gates.

Verified against GitHub main `bba36cc` on 2026-09-08 (KHA-645): `v0.4.0`
was the latest stable release and included `appcast.xml`. Both `v0.3.0` and
`v0.4.0` had completed Developer ID signing and notarization. The original plan's
“first stable signing path has never run” premise was obsolete. Action SHA pins,
restricted secret file modes, cleanup, and read-only repository Actions defaults
were already present. Dependabot was missing. The three misclassified historical
prereleases (`v0.1.1`, `v0.1.2`, `v0.2.1`) were corrected on GitHub;
`v0.4.0` was latest stable at that audit.

The published `v0.4.0` DMG's EdDSA signature was independently verified against
the public key inside that artifact. Gatekeeper accepted the disk image and app.
The actual `v0.3.0` → `v0.4.0` Sparkle replacement and relaunch passed in a
separate headless Tart VM, using untouched, signed release binaries.
