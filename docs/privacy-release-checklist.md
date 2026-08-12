# Privacy release checklist

- Confirm `PrivacyInfo.xcprivacy` matches the binary and dependency inventory.
- Snapshot the exact enabled payload and compare every key with `TelemetryPayload`.
- Verify disabled mode produces zero DNS, TCP, and HTTP telemetry traffic.
- Verify opt-out deletes the on-disk queue without restarting.
- Search payload evidence for the documented denylist and stable identifiers.
- Confirm the endpoint region, 90-day retention, dashboard access, and daily cap.
- Review dependency updates for automatic fields, capture, identity, replay, and endpoint changes.
- Archive the payload snapshot, network trace, manifest, diagnostics, benchmark JSON, and selected Instruments trace with release evidence.
