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
- Confirm whether the packaged build configures a working telemetry namespace/app ID. For an enabled endpoint, verify the EU hosting region, dashboard access, and daily cap; do not infer service-side settings from client code.
- Compare the disclosure with TelemetryDeck's current privacy FAQ and data protection agreement. Record both the plan's live-query retention and the vendor's cold-storage/deletion position; never describe live retention as deletion.
- Confirm the policy identifies the purpose, legitimate interest, recipient, optional nature, right to object, other applicable data-subject rights, supervisory-authority complaint right, and the practical limits created by sending no user or installation identifier.
- Review dependency updates for automatic fields, capture, identity, replay, and endpoint changes.
- Archive the payload snapshot, network trace, manifest, diagnostics, benchmark JSON, and selected Instruments trace with release evidence.
