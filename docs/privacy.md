# Debut privacy notice

Last updated: 21 September 2026.

This notice describes what the Debut app currently does. It is deliberately
factual and does not claim that any particular privacy law does or does not apply
to a user, maintainer, or distribution channel.

## Project contact

Debut is maintained through the [Debut repository](https://github.com/thomplth/Debut).
The issue tracker is public, so do not include private information in an issue.
There is no dedicated private privacy-contact address at this time.

## Data kept on your Mac

Debut uses Accessibility locally for window control and global shortcuts, and
Screen Recording for window screenshot previews. Stages represent real macOS
desktops; Debut does not capture or paint desktop wallpaper. Previews can be
disabled in Settings.

Window titles are stored locally. `state.json` keeps them in plaintext so window
assignments can be recovered across restarts using bundle ID and title, with
validated runtime identity and fallback matching. The current-state
`diagnostic.json` snapshot also keeps titles; that file is capped and overwritten
instead of accumulating. The append-only lifecycle log records only a salted
digest of each title, and the salt never leaves the Mac, so digests from separate
installations cannot be compared. The window-preview cache is held in memory and
is not written to disk. `state.json` also contains desktop and display-stack
records, recency, and runtime window and process IDs that are validated when
restored. `retired-windows.json` and `ax-contradictions.json` preserve local
lifecycle evidence. None of these files is automatically uploaded.

Exporting diagnostics is user-initiated and writes wherever the save panel
points. The export replaces every window title with the same digest, so a file
attached to a public issue carries no document names, tab titles, or channel
names. Developer demo and isolated test tools deliberately write media and
evidence; those tools are separate from the installed app's preview cache.

## Optional anonymous usage and performance data

“Share anonymous usage and performance data” is disabled on a fresh install.
Debut does not enqueue or send remote telemetry unless you opt in and finish
onboarding. You can also opt in or out later in Settings → Privacy. Sharing is
not required to use any app feature and is not used for advertising, cross-app tracking,
profiling, or automated decisions. Its only purpose is to help maintainers find
reliability and performance regressions and prioritize improvements.

When sharing is enabled, Debut records three user-facing latency measurements
locally and sends one numeric P95 summary for each interaction that occurred in
the preceding hour. The three interactions are window-switcher presentation,
first-preview readiness, and desktop switching. Active-hour summaries are sent
together in one HTTPS request. A normal app quit also attempts to send the
current partial hour; an uncatchable force-kill cannot run that final hook, so at
most the current partial hour can be lost. The allowlist is:

- event type and schema version;
- Debut version and macOS major version;
- coarse workload class;
- one of the three canonical interaction names;
- the exact local hourly P95 duration in milliseconds and its aggregate sample count; and
- a server-generated receipt time and event count added by TelemetryDeck.

Debut sends an empty `clientUser` value. It does not send a session ID, user ID,
installation ID, trace ID, individual interaction timing, locale, time zone, screen or hardware
details, window titles, app names or bundle IDs, PIDs, window IDs, paths,
screenshots, raw diagnostics, free-form errors, or cache counts. The direct HTTPS
integration does not use TelemetryDeck's SDK and therefore does not add the SDK's
automatic device or user fields. Like any HTTPS request, the connection presents
an IP address to the receiving server. TelemetryDeck states that it neither
stores nor logs IP addresses.

You can inspect the exact current hourly-summary JSON in Settings → Privacy →
View data being shared.

## Recipient, location, and retention

Records are sent to TelemetryDeck GmbH, Von-der-Tann-Str. 54, 86159 Augsburg,
Germany. TelemetryDeck states that usage data is hosted within the European Union
using infrastructure in Germany and the Netherlands. Debut does not intentionally
send the telemetry to another recipient or region.

The local queue holds at most 100 unsent records and delivery is capped at 24
events per installation day. Inactive hours create no records. A successfully delivered record is removed from
that queue. Disabling sharing immediately deletes all queued unsent records and
prevents future collection until sharing is enabled again. Local diagnostics
remain available and are never uploaded automatically.

TelemetryDeck's plan retention controls how long events remain queryable in its
live dashboard; it is not a deletion period. According to TelemetryDeck's
[privacy FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/), older events
move to cold storage, have no scheduled deletion date, and are expected to be
deleted after 7–10 years without a guarantee. TelemetryDeck also says anonymous
analytics may be retained when a customer account is closed. Because Debut sends
no stable identifier, maintainers and TelemetryDeck cannot locate a delivered
record as belonging to a particular person or installation for individual access
or deletion.

## Changes and review

The current [telemetry anonymization assessment](telemetry-anonymization-assessment.md)
records the remaining identification risks and the changes that require a new
review. If the payload, recipient, purpose, volume, identity model, or vendor's
network-metadata or retention practices change, telemetry export must be
reassessed before release.

See the [performance payload contract](performance-observability.md#remote-privacy-contract)
and [release checklist](privacy-release-checklist.md) for verification steps.
