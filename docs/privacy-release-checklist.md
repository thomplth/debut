# Privacy release checklist

Verify the packaged build against [the privacy disclosure](privacy.md) and
[the payload contract](performance-observability.md#remote-privacy-contract).

- Confirm `PrivacyInfo.xcprivacy` matches the binary and dependency inventory.
- Snapshot the exact enabled payload and compare every key with `TelemetryPayload`.
- Verify disabled mode produces zero DNS, TCP, and HTTP telemetry traffic.
- Verify opt-out deletes the on-disk queue without restarting, and no delivery occurs before onboarding completion.
- Verify disabling previews clears the in-memory cache and prevents new window captures; no production wallpaper capture should occur.
- Confirm diagnostic exports redact titles, local state and tombstones stay local, and no screenshot is present in telemetry.
- Search payload evidence for the documented denylist and stable identifiers.
- Confirm whether the packaged build configures a working telemetry namespace/app ID. For an enabled endpoint, verify its region, 90-day retention policy, dashboard access, and daily cap; do not infer service-side settings from client code.
- Review dependency updates for automatic fields, capture, identity, replay, and endpoint changes.
- Archive the payload snapshot, network trace, manifest, diagnostics, benchmark JSON, and selected Instruments trace with release evidence.
