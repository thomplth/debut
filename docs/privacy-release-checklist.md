# Privacy release checklist

Verify the packaged build against [the privacy notice](privacy.md) and the local
performance boundary in [performance observability](performance-observability.md).

- Confirm `PrivacyInfo.xcprivacy` matches the binary and dependency inventory and declares only crash and performance data, unlinked and not used for tracking.
- Confirm the packaged app contains no analytics endpoint, routing identifier, remote metrics queue, or analytics SDK. Sentry is the only reporting SDK, and it sends only crash and hang events.
- Confirm a release carries `DebutCrashReportDSN` in its `Info.plist`, and that `Debut.dSYM.zip` is attached to the release with a UUID matching the shipped binary.
- Confirm that with automatic sending off, a crash is sent only after Send Report, and Don’t Send leaves nothing queued in `~/Library/Caches/io.sentry`.
- Confirm the Sentry project still has IP address storage turned off and its data scrubbing defaults on.
- Confirm onboarding contains no usage-data sharing control, and that Settings offers only the crash report preference.
- Confirm local `diagnostic.json`, lifecycle evidence, state, and tombstones are never uploaded automatically.
- Confirm diagnostic export remains user-initiated, redacts every window title, and contains no screenshot pixels.
- Verify disabling previews clears the in-memory cache and prevents new window captures; no production wallpaper capture should occur.
- Review Sentry updates for new default integrations or event fields, and the others for automatic analytics, identity, capture, replay, network metadata, and endpoint changes.
- Archive the manifest, redacted diagnostic export, benchmark JSON, and selected Instruments trace with release evidence.
