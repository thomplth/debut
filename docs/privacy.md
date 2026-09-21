# Debut privacy and anonymous performance data

Last updated: 21 September 2026.

## Who is responsible

The Debut project maintainer is responsible for processing performed by Debut. Privacy questions, objections, and requests can be submitted through the [Debut repository](https://github.com/thomplth/Debut/issues). Debut has no appointed data protection officer.

## Data kept on your Mac

Debut uses Accessibility locally for window control and global shortcuts, and Screen Recording for window screenshot previews. Stages represent real macOS desktops; Debut does not capture or paint desktop wallpaper. Previews can be disabled in Settings.

Window titles are stored locally. `state.json` keeps them in plaintext because window assignments can be recovered across restarts using bundle ID and title, with validated runtime identity and fallback matching, and the current-state `diagnostic.json` snapshot keeps them too; that file is capped and overwritten in place rather than accumulating. The append-only lifecycle log records only a salted digest of each title, and the salt never leaves the machine, so one install's digests cannot be compared with another's. The app's window-preview cache is held in memory and is not written to disk. `state.json` also contains desktop/display-stack records, recency, and runtime window/process IDs that are validated when restored. `retired-windows.json` and `ax-contradictions.json` preserve local lifecycle evidence. None of these files is automatically uploaded.

Exporting diagnostics is user-initiated and writes wherever the save panel points. The export replaces every window title with the same digest, so a file attached to a public issue carries no document names, tab titles, or channel names. Developer demo and isolated E2E capture tools deliberately write media and evidence; those tools are separate from the installed app's preview cache.

## Optional anonymous usage and performance data

“Share anonymous usage and performance data” ships enabled, but nothing is sent until onboarding has been completed and the setting has been shown. Sharing is optional, is not a statutory or contractual requirement, and is not used for advertising, cross-app tracking, profiling, or automated decisions. Its purpose is to measure Debut's reliability and performance so maintainers can find regressions and prioritize improvements.

To the extent that collecting or transmitting a record is considered processing of personal data before the record reaches TelemetryDeck, Debut relies on the maintainer's legitimate interest under Article 6(1)(f) GDPR in improving the reliability and performance of the app. Debut limits that processing through coarse buckets, low daily volume, no user identifier, no precise device identity, and an immediate opt-out. You have the right to object at any time by turning sharing off in Settings → Privacy; the app remains fully usable.

Debut sends one aggregate session-summary event and a small number of rate-limited performance-anomaly events. The allowlist is:

- event type and schema version;
- Debut version and macOS major version;
- coarse workload and first-use/cache-temperature classes;
- canonical operation names with aggregate counts;
- bucketed latency ranges and an aggregate anomaly count; and
- a server-generated receipt time and event count added by TelemetryDeck.

Debut sends an empty `clientUser` value. It does not send a session ID, user ID, installation ID, trace ID, exact timing, locale, time zone, screen or hardware details, window titles, app names or bundle IDs, PIDs, window IDs, paths, screenshots, raw diagnostics, free-form errors, or cache counts. The direct HTTPS integration does not use TelemetryDeck's SDK and therefore does not add the SDK's automatic device or user fields. Like any HTTPS request, the connection necessarily presents an IP address to the receiving server; TelemetryDeck states that it neither stores nor logs IP addresses.

You can inspect the exact current session-summary JSON in Settings → Privacy → View data being shared.

## Recipient and location

Records are sent to TelemetryDeck GmbH, Von-der-Tann-Str. 54, 86159 Augsburg, Germany. TelemetryDeck states that usage data is hosted within the European Union using infrastructure in Germany and the Netherlands, including Hetzner, Microsoft Azure, and Amazon Web Services. There is no intentional transfer of telemetry outside the European Union.

TelemetryDeck's [data protection agreement](https://telemetrydeck.com/dpa/) states that, from its perspective, received analytics are anonymous under GDPR Recital 26 and that TelemetryDeck is neither Debut's processor nor a joint controller for those records. Debut's integration is deliberately stricter than TelemetryDeck's normal SDK configuration because it sends no persistent or pseudonymous user identifier.

## Retention and deletion

The local queue holds at most 100 unsent records and delivery is capped at 20 events per installation day. A successfully delivered record is removed from that queue. Disabling sharing immediately deletes all queued unsent records and prevents future collection until sharing is enabled again. Local diagnostics remain available and are never uploaded automatically.

TelemetryDeck's plan retention controls how long events remain queryable in the live dashboard; it is not a deletion period. According to TelemetryDeck's [privacy FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/), older events move to cold storage, have no scheduled deletion date, and are expected to be deleted after 7–10 years without a guarantee. TelemetryDeck also says anonymous analytics may be retained when a customer account is closed. Because Debut sends no stable identifier, maintainers and TelemetryDeck cannot locate a delivered record as belonging to a particular person or installation for individual access or deletion.

## Your rights

Where GDPR applies, you may request access, rectification, erasure, restriction, or portability of personal data, and you may exercise the right to object, by contacting the maintainer. The absence of any user or installation identifier means a delivered anonymous telemetry record cannot be linked back to you; this limits what can be retrieved, corrected, or deleted individually. You may also lodge a complaint with the supervisory authority responsible for your place of residence, work, or the alleged infringement.

If the payload, recipient, purpose, or vendor's anonymization or retention position changes, telemetry export must be reassessed before release. A privacy incident pauses export, preserves local evidence, audits the allowlist, and documents remediation. Removing a vendor means disabling its endpoint, requesting deletion where available, removing its configuration, and re-running the release checklist.

See the [performance payload contract](performance-observability.md#remote-privacy-contract) and [release checklist](privacy-release-checklist.md) for verification requirements.
