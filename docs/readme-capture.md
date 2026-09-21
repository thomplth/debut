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
- `Sources/DebutDemo/ReadmeDemo.swift`: Weather, appearance, placement, keystrokes,
  and destination verification.
- `Sources/DebutDemo/MediaCapture.swift` and `DemoMediaSupport.swift`:
  ScreenCaptureKit capture and alpha-preserving PNG framing.

## Visual baseline

| Item | Baseline |
| --- | --- |
| Space 1 | Terminal / Research, Safari / Field Notes, Chess |
| Space 2 | Safari / Weekend Guide, Weather / Cupertino, Stocks |
| Space 3 | Terminal / Project, TextEdit / Project notes, TextEdit / Reading list |
| Display | 1440×900 logical pixels at 2× |
| Debut | Clear glass, scale 1.4, inactive scale 0.7, corner radius 40; the script owns the exact settings |
| GIF appearance | Light mode, with light rendered overlay plates |
| Weather | Cupertino, California, search closed, no other saved locations visible |
| KeyCastr | Pinned 0.11.1; 64 pt for individual demos, 128 pt before half-width comparison scaling |
| Captions | No modifier-release caption; comparison labels only |

Dismiss Weather and Stocks onboarding and tutorials, native dialogs, notification
banners, and capture reminders before recording. The fixture must not use the host's
location or personal app data; the driver asserts that Weather is titled Cupertino
and that its sidebar has no extra cities.

| Clip selector | Sequence and verified result |
| --- | --- |
| `cover` | Both `overlay.png` and native dark-mode `overlay-dark.png`, with space 2 expanded |
| `command-tab` | Space 2 → hold Command-Tab → 3 → Tab → release → Project notes, second window in space 3 |
| `organize-windows` | Space 2 → hold Command-Tab, Weather selected → Up → release → Weather in space 1 |
| `option-tab` | Safari in space 2 → hold Option-Tab → release → Field Notes Safari window in space 1 |
| `faster-space-switching` | Matched Control-Right then Control-Left, space 2 → 3 → 2; macOS default left, Instant right |

Faster switching stays disabled in the first three demos. The comparison preserves
elapsed time: do not accelerate either recording or trim the two sides independently
around transitions.

## Running a scoped capture

Requires an Apple Silicon host with Xcode and command-line tools, `tart`,
`ffmpeg`/`ffprobe`, and a prepared macOS 26 VM. `scripts/tart-e2e.sh prepare`
documents initial provisioning.

Clone the stopped prepared VM into a disposable capture VM with a dedicated shared
cache, so older raw files cannot be converted by accident. Choose unused names when
captures run concurrently.

```bash
tart clone debut-e2e-tahoe debut-readme-capture
tart set debut-readme-capture --cpu 6 --memory 8192 --display 1440x900

DEBUT_TART_VM=debut-readme-capture \
DEBUT_TART_SHARE="$HOME/Library/Caches/Debut/ReadmeCapture" \
./scripts/demo-capture.sh --clips organize-windows,option-tab --keep-raw
```

Omitting `--clips` regenerates both covers and all four README GIFs. Keep raw output
until visual review passes. The script starts the guest without graphics, audio,
clipboard, pointer, or keyboard, and installs KeyCastr only inside the guest. Do not
run the guest script on the host.

An already-running VM keeps the share it was started with; changing the environment
variable does not remount it. Stop and restart only the capture VM, with the correct
`--dir`, if the mount needs to change.

### Appearance is a capture invariant

Check actual frames, not the system's dark-mode boolean. One batch produced charcoal
plates with black light-mode labels after earlier overlays and space transitions; the
first clip and the covers were fine, so reviewing only those missed it.

For each interaction clip the driver restores the fixture, selects light appearance,
and starts a fresh Debut process before starting KeyCastr and recording.
`setDemoInstant(false)` currently restarts Debut while disabling faster switching.
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
ffmpeg -loglevel error -y -i docs/media/option-tab.gif \
  -vf 'fps=1,scale=480:-1,tile=3x3' -frames:v 1 /tmp/debut-option-contact.png
ffmpeg -loglevel error -y -ss 1.3 -i docs/media/option-tab.gif \
  -frames:v 1 /tmp/debut-option-overlay.png
ffprobe -v error -show_entries stream=width,height,nb_frames,duration \
  -show_entries format=size -of json docs/media/option-tab.gif
```

Open the images and check plate color and label contrast, readable keys, Cupertino,
absence of dialogs and banners, correct window counts, complete transitions, and final
focus. Driver logs must confirm actual space membership and the frontmost window, not
just input delivery. Inspect both transitions and the return in a comparison, and
check PNG alpha and the full shadow against light and dark backgrounds.

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
Appearance control needs Apple Events to `com.apple.systemevents` for the
driver/SSH/osascript responsibility chain.

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
location; skipping that accumulates Terminal or TextEdit windows and breaks the 3/3/3
layout.

Weather can leave search open after selecting a saved city, display tips, or ask for
confirmation when deleting a saved city. The maintained AX setup clears search,
dismisses tips, removes other cities, confirms deletion, and waits for the sidebar to
rebuild. A leftover sheet or an extra city is a capture failure, not something to crop
away.

Native space animations can affect KeyCastr. Inspect both directions and preserve the
comparison's real timing; do not adjust video speed to exaggerate Instant switching.
