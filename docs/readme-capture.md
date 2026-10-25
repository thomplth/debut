# README media capture

The README covers and interaction GIFs show real Debut overlays over real macOS
windows, captured in a disposable headless Tart guest. Never run the demo driver,
global key injection, or E2E against an active desktop session.

Keep a capture scoped to the assets you intend to change. A two-GIF correction
does not imply recapturing the covers or rewriting the README.

## Maintained entrypoints

These files are the implementation; this document only describes how to use them.
Read them before adapting a capture, and fix repeatability problems there rather
than working around them per run.

- `scripts/demo-capture.sh`: host build and staging, headless launch, SSH, and the
  authoritative conversion filters.
- `scripts/demo-capture-guest.sh`: guest-only installation, TCC grants, display and
  nine-window setup, and KeyCastr preferences.
- `Sources/DebutDemo/CaptureSettings.swift`: the only settings a capture changes from
  Debut's fresh defaults. Never hard-code appearance in a script or the driver; media
  follows whatever the app ships.
- `Sources/DebutDemo/ReadmeDemo.swift`: Weather, appearance, placement, keystrokes,
  and destination verification.
- `Sources/DebutDemo/MediaCapture.swift` and `DemoMediaSupport.swift`:
  ScreenCaptureKit capture and alpha-preserving PNG framing.

## Visual baseline

| Item | Baseline |
| --- | --- |
| Space 1 | Safari / Field Notes, Terminal / Research, Notes / Reading list |
| Space 2 | Safari / Weekend Guide, Weather / Cupertino, Stocks |
| Space 3 | Notes / Project notes, Chess, Terminal / Project |
| Display | 1440×900 logical pixels at 2× |
| Debut | Fresh `AppSettings()` defaults: previews use the preview appearance, the two no-preview onboarding stills the icon appearance. `Sources/DebutDemo/CaptureSettings.swift` adds only login launch off, no exclusions, and faster switching per clip |
| GIF appearance | Light mode, with light rendered overlay plates |
| Weather | Cupertino, California, search closed, no other saved locations visible |
| KeyCastr | Pinned 0.11.1; 64 pt for individual demos, 128 pt before half-width comparison scaling |
| Captions | No modifier-release caption; comparison labels only |

This is the site's fixture, shared by README, onboarding, and site media (KHA-1119); the
driver's `captureFixture` and debut.site's recorder must change together. Notes uses two
real Apple Notes windows opened separately from a "Debut Demo" folder, and Safari loads the
offline pages in `Tests/Fixtures/Demo/html`, copied from debut.site's `native/Fixtures/html`.

Dismiss Weather and Stocks onboarding and tutorials, native dialogs, notification
banners, and capture reminders before recording. The fixture must not use the host's
location or personal app data; the driver asserts that Weather is titled Cupertino
and that its sidebar has no extra cities.

| Clip selector | Sequence and verified result |
| --- | --- |
| `onboarding` | Four lossless transparent UI screenshots: Command-Tab and Option-Tab, each with previews enabled and disabled; same nine-window scene, no keystroke captions |
| `onboarding-speed` | Matched Control-Right then Control-Left at 60 fps, space 2 → 3 → 2; macOS default left, Debut Instant right; MP4 and first-frame poster for setup |
| `cover` | Both `overlay.png` and native dark-mode `overlay-dark.png`, with space 2 expanded |
| `overview` | See [Overview clip](#overview-clip). `overview.gif`: space 2, Weekend Guide → hold Command-Tab, Stocks selected → Up → release → Stocks focused in space 1 → hold Command-Tab → Shift-Tab, Stocks selected → Down → Tab, Weekend Guide selected → release → Weekend Guide focused in space 2; fixture as at start |
| `command-tab` | Retired from the README. Terminal fronted in space 3, then space 2 → hold Command-Tab → 3 → Tab → release → Project notes, second window in space 3 |
| `organize-windows` | Retired from the README. Space 2 → hold Command-Tab, Weather selected → Up → release → Weather in space 1 |
| `option-tab` | Retired from the README. Safari in space 2 → hold Option-Tab → release → Field Notes Safari window, first in space 1 |
| `faster-space-switching` | Retired from the README. Matched Control-Right then Control-Left, space 2 → 3 → 2; macOS default left, Instant right |

The README embeds only the covers and `overview.gif`; per-feature demos live on
debutspace.com. The four retired clips stay in the driver; their GIFs left
`docs/media` when the overview landed. The `onboarding` and
`onboarding-speed` clips are unaffected: the app bundles their assets.

Cards in a space follow its MRU order, not the fixture order, so each switcher clip reads
Debut's live selection and fails before releasing the modifier if the intended card is not
selected. Faster switching stays disabled in the retired single-window demos; the overview uses the default, Instant.
The comparison preserves elapsed time: do not accelerate either recording or trim
the two sides independently around transitions.

### Overview clip

One loop of at most about 12 seconds that shows Command-Tab across spaces and a
window move, and ends on the frame it began with, using the visual baseline above.

Before recording, set recency so Field Notes leads space 1 and space 2 reads Weekend
Guide, Stocks, Weather, then show space 2 with Weekend Guide frontmost. Set that order
through Debut's Command-Tab: an Accessibility raise does not restack across apps on
macOS 27, and the loop ends in that order. Faster switching is Debut's default, Instant;
with it off, macOS 27 switches through the system's Control-number shortcut, which
KeyCastr captions as a press nobody made. Wait until every
preview, including Chess, has loaded.

| Time (s) | Input | Verified result |
| --- | --- | --- |
| 0.0 | None | Space 2, Weekend Guide focused |
| 1.0 | Hold Command, Tab | Overlay with space 2 expanded; Stocks (second by recency) selected |
| 1.8 | Up | Stocks staged first in space 1; selection follows it |
| 2.8 | Release Command | Space 1 showing, Stocks frontmost and assigned to space 1 |
| 4.6 | Hold Command, Tab | Overlay with space 1 expanded; Field Notes selected |
| 5.3 | Shift-Tab | Stocks selected |
| 6.0 | Down | Stocks staged first in space 2; selection follows it |
| 6.8 | Tab | Weekend Guide selected |
| 7.6 | Release Command | Space 2 showing, Weekend Guide frontmost, Stocks assigned to space 2 |
| 9.4–11.2 | None | Desktop indicator dismissed; 1.8 s final hold |

Times are targets; let each transition settle rather than cutting it short. The
driver asserts each selection from diagnostics before the next key, the space
membership and frontmost window after each release, and space 2's recency order at
the end. Compare decoded first and last frames for a clean loop boundary. KeyCastr
shows every key at 64 pt.

## Running a scoped capture

Requires an Apple Silicon host with Xcode and command-line tools, `tart`,
`ffmpeg`/`ffprobe`, and a prepared guest VM. Media is captured on the macOS 27
guest, `debut-e2e-27`, so it shows the current system look and desktop management;
`./scripts/tart-e2e.sh prepare` provisions it (see
[the macOS 27 guest](#the-macos-27-guest)). Capture only once the E2E suite passes
on that guest.

Clone the stopped prepared VM into a disposable capture VM with a dedicated shared
cache, so older raw files cannot be converted by accident. Choose unused names when
captures run concurrently.

```bash
tart clone debut-e2e-27 debut-readme-capture
tart set debut-readme-capture --cpu 6 --memory 8192 --display 1440x900

DEBUT_TART_OS=27 \
DEBUT_TART_VM=debut-readme-capture \
DEBUT_TART_SHARE="$HOME/Library/Caches/Debut/ReadmeCapture" \
./scripts/demo-capture.sh --clips organize-windows,option-tab --keep-raw
```

For onboarding assets only, use `--clips onboarding --keep-raw`. This uses the same
nine-window fixture and fresh light-mode Debut process as README capture, producing
`onboarding-workspace.png`, `onboarding-workspace-no-previews.png`,
`onboarding-previews.png`, and `onboarding-no-previews.png`. It leaves README assets
unchanged. The app bundles these four PNGs.

For the faster-switching page, use `--clips onboarding-speed --keep-raw`. It records
both sides in one run at 60 fps and produces `onboarding-speed.mp4` plus a lossless
first-frame `onboarding-speed.png` poster. Playback loops silently in setup and
pauses when the page is hidden; the poster remains visible while video loads.

Omitting `--clips` regenerates both covers, `overview.gif` and the four retired GIFs,
which the README no longer uses; capture `--clips cover,overview` for the README. Keep raw output
until visual review passes. The script starts the guest without graphics, audio,
clipboard, pointer, or keyboard, and installs KeyCastr only inside the guest. Do not
run the guest script on the host.

An already-running VM keeps the share it was started with; changing the environment
variable does not remount it. Stop and restart only the capture VM, with the correct
`--dir`, if the mount needs to change.

### The macOS 27 guest

`debut-e2e-27` is a clone of `ghcr.io/cirruslabs/macos-golden-gate-base:latest`, the
Cirrus Labs macOS 27 (Golden Gate) base image, prepared on 2026-10-17 from the
image uploaded on 2026-10-03: macOS 27.0 (build 26A428). The image already has what
the harness expects (user `admin` with passwordless `sudo`, automatic login, Remote
Login, and `tart-guest-agent`), so prepare only clones it, sizes it like the Tahoe
guest (6 CPUs, 8 GB, 1440×900) and drops the cached image.

Its appearance stays at system defaults: Light, Multicolor accent, and System
Settings → Appearance → Liquid Glass Tint Amount untouched. After prepare the guest's
global and Universal Access domains hold no appearance, accent, icon-tint or glass
key at all. Neither prepare, the host profile nor the capture scripts write the
tint; do not change it for a capture. The host profile still pins Light appearance
and turns Reduce Transparency, Increase Contrast and Reduce Motion off, as on 26.

### Appearance is a capture invariant

Check actual frames, not the system's dark-mode boolean. One batch produced charcoal
plates with black light-mode labels after earlier overlays and space transitions; the
first clip and the covers were fine, so reviewing only those missed it.

For each interaction clip the driver restores the fixture, selects light appearance,
and starts a fresh Debut process before starting KeyCastr and recording.
`setDemoInstant(false)` currently restarts Debut from the fresh capture settings with
faster switching disabled; nothing set for an earlier clip carries over.
Cover capture intentionally switches native appearance for each PNG and refreshes
Debut's previews, then light mode is retained for the GIFs.

Reject a clip that is still visually dark. Inspect guest appearance and accessibility
contrast and transparency settings, and retry that clip alone with a fresh Debut
process. Do not recolor screenshots, replace real UI with a mockup, or change product
rendering solely to make a demo pass.

## Conversion

The conversion section of `scripts/demo-capture.sh` is the source of truth.

- Individual GIFs: 1440 px wide, 15 fps sampling, Lanczos scaling, a 128-color shared
  palette, `mpdecimate` with timestamps retained, Bayer dithering, changed rectangles,
  and transparent deltas. The final hold is 1.8 seconds.
- Comparison: each 2880×1800 capture scales to 720×450 with a 48 px label strip;
  the combined output is 1440×498. Build both halves from the same run.
- Onboarding comparison: 2880×996, 60 fps, full-color H.264 at CRF 16 with fast
  start and no audio. Each half is 1440×900 with a 96 px label strip. Preserve
  both recordings' elapsed time; do not interpolate motion or accelerate either
  side. ScreenCaptureKit omits idle frames, so extend only the final still to a
  common five-second endpoint. The shared starting/ending desktop makes the repeat
  unobtrusive.
- Covers: lossless RGBA PNG, isolated overlay alpha, and 128 physical pixels of
  transparent padding beyond the entire shadow. White and black neutral backing is
  used for light and dark compositing recovery. Do not substitute a desktop
  screenshot or crop the shadow.
- The README selects a cover with `<picture>` and `prefers-color-scheme` sources,
  falling back to `overlay.png`. Keep both files with matching geometry.

Individual GIFs have run about 1.4–2.7 MB and the comparison about 0.9 MB. Treat
those as a baseline rather than a reason to reduce legibility, and investigate large
increases for duplicate frames, palette churn, or accidental full-frame updates.

## Verification

Inspect every changed asset, including the encoded GIF rather than only its raw
movie. Extract representative frames or a contact sheet:

```bash
ffmpeg -loglevel error -y -i docs/media/overview.gif \
  -vf 'fps=1,scale=480:-1,tile=3x3' -frames:v 1 /tmp/debut-overview-contact.png
ffmpeg -loglevel error -y -ss 1.3 -i docs/media/overview.gif \
  -frames:v 1 /tmp/debut-overview-overlay.png
ffprobe -v error -show_entries stream=width,height,nb_frames,duration \
  -show_entries format=size -of json docs/media/overview.gif
```

Open the images and check plate color and label contrast, readable keys, Cupertino,
absence of dialogs and banners, correct window counts, complete transitions, and final
focus. Driver logs must confirm actual space membership and the frontmost window, not
just input delivery. Inspect both transitions and the return in a comparison, and
check PNG alpha and the full shadow against light and dark backgrounds. The speed
fixture settles Dock after Mission Control before recording, and asserts two Debut
switch events for Instant and zero for the native side, preventing an accidental
native recovery transition from being presented as accelerated switching.

Confirm that unrelated assets and README prose stayed byte-identical for a scoped
update. Choose verification proportionate to the change: media-only changes need
visual, link, and whitespace checks, while fixture or script changes also need the
relevant shell contracts and the serial Swift suite. Use Xcode's toolchain
(`TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift`); the host `PATH`
may point at a different Swift.

Afterwards, stop and delete only the disposable capture VM, stop any temporary
networking helper, and report dimensions, sizes, and material limitations. Do not
delete the base VM or unrelated captures.

## Troubleshooting

Read this section only when a normal capture fails. Keep UI, TCC, app preference, and
network-setting changes inside the disposable guest. Inspect the failed log before
retrying; successful input delivery does not prove an interaction happened.

### No guest address or Weather results

`tart exec` uses vsock and works without DHCP. The host script falls back to SSH over
guest loopback when `tart ip` fails. That runs commands but gives no internet access
for Weather's city search.

Inspect with `tart exec <capture-vm> /bin/bash -c '...'`:

- `/sbin/ifconfig en0` and `/sbin/route -n get default`; `sbin` may not be in `PATH`.
- `networksetup -listallnetworkservices`, then the service's IP, DNS, and proxy
  configuration.
- A short, bounded HTTPS request.

A self-assigned 169.254 address with no default route indicates missing DHCP, not an
Accessibility failure. One host needed a temporary static guest address on the active
Tart bridge and an HTTP CONNECT forwarding proxy on that bridge because a VPN blocked
guest NAT. Do not hard-code that workaround. Inspect the bridge, subnet, and an
unused address first; if a proxy is needed, bind it only to the VM bridge, restrict
clients to the capture guest, forward TLS unchanged, and configure only the guest's
proxy settings. Preserve host VPN and network preferences, and stop the proxy
afterwards; deleting the capture VM removes its guest settings.

Weather's AX search waits for "Cupertino, CA…" and fails if no result arrives.
Establish connectivity before retrying rather than switching to an inferred location
or capturing an empty or errored search panel.

Finish connectivity probes before recording. A request through `tart exec` can trigger
a native local-network permission dialog for `tart-guest-agent`, owned by
`UserNotificationCenter`, even while the demo is running. Resolve that guest-only
permission during preflight and inspect a guest still before retrying. A movie
containing the dialog must be discarded even if destination assertions pass.

### Permissions and process responsibility

The guest script grants Screen Recording, Accessibility, event posting, and Apple
Events using the actual signed executable requirements in the guest's TCC databases.
Appearance control needs Apple Events to `com.apple.systemevents`, and the fixture's
note windows Apple Events to `com.apple.Notes`, for the driver/SSH/osascript
responsibility chain.

Use direct SSH or the script's loopback SSH path. A raw `tart exec` launch of a GUI
driver can inherit a different responsible process and prompt despite existing grants.
Restaging a rebuilt driver to a new path requires fresh matching TCC grants. Do not
modify host TCC or signing credentials to fix a guest prompt.

### Retry the minimum necessary work

The supported retry is `scripts/demo-capture.sh --clips <failed-clips> --keep-raw`. It
rebuilds and reinstalls, resets the guest fixture, and clears that run's raw media
directory, without regenerating other committed README assets.

When retaining a prepared fixture for iteration, first check the guest script's
argument order and grants. Stage a uniquely named current driver, grant it the same
permissions, then invoke it through the established loopback SSH with
`--output <new-run-directory> --clips <requested-clips>`. Use a fresh raw directory:
the converter iterates whatever files are present and can otherwise copy stale assets
after a failed run. Convert only after the driver succeeds and destination assertions
pass, and do not run unrelated UI commands while recording.

The fixture reset kills apps before deleting saved state. Tahoe restores windows from
`~/Library/Daemon Containers/**/*.savedState` as well as the conventional saved-state
location; skipping that accumulates Terminal or Notes windows and breaks the 3/3/3
layout.

Weather can leave search open after selecting a saved city, display tips, or ask for
confirmation when deleting a saved city. The maintained AX setup clears search,
dismisses tips, removes other cities, confirms deletion, and waits for the sidebar to
rebuild. A leftover sheet or an extra city is a capture failure, not something to crop
away.

Native space animations can affect KeyCastr. Inspect both directions and preserve the
comparison's real timing; do not adjust video speed to exaggerate Instant switching.
