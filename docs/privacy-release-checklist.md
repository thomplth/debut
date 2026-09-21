# Privacy release checklist

Verify the packaged build against [the privacy notice](privacy.md), the
[anonymization assessment](telemetry-anonymization-assessment.md), and the
[payload contract](performance-observability.md#remote-privacy-contract).

- Confirm `PrivacyInfo.xcprivacy` matches the binary and dependency inventory.
- Confirm a fresh install and a settings file without a saved telemetry choice both default to sharing off.
- Confirm onboarding presents an off-by-default opt-in and sends nothing before both opt-in and onboarding completion.
- Snapshot the exact enabled payload and compare every key with `TelemetryPayload`.
- Verify disabled mode produces zero DNS, TCP, and HTTP telemetry traffic.
- Verify opt-out deletes the on-disk queue without restarting.
- Verify disabling previews clears the in-memory cache and prevents new window captures; no production wallpaper capture should occur.
- Confirm diagnostic exports redact titles, local state and tombstones stay local, and no screenshot is present in telemetry.
- Search payload evidence for the documented denylist, stable identifiers, and fields that could increase singling-out, linkability, or inference risk.
- Confirm whether the packaged build configures a working telemetry namespace and app ID. For an enabled endpoint, verify the EU hosting region, dashboard access, and daily cap; do not infer service-side settings from client code.
- Compare the notice with TelemetryDeck's current privacy FAQ and data protection agreement. Record both the plan's live-query retention and the vendor's cold-storage and deletion position; never describe live retention as deletion.
- Review dependency updates for automatic fields, capture, identity, replay, network metadata, and endpoint changes.
- Re-run the anonymization assessment when any listed review trigger occurs, and separately check the laws and store rules applicable to the actual maintainer location and distribution plan.
- Archive the payload snapshot, network trace, manifest, diagnostics, benchmark JSON, and selected Instruments trace with release evidence.
