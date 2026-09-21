# Privacy release checklist

Verify the packaged build against [the privacy notice](privacy.md) and the local
performance boundary in [performance observability](performance-observability.md).

- Confirm `PrivacyInfo.xcprivacy` matches the binary and dependency inventory and declares no collected data.
- Confirm the packaged app contains no analytics endpoint, routing identifier, remote metrics queue, or analytics SDK.
- Confirm onboarding and Settings contain no usage-data sharing control or disclosure.
- Confirm local `diagnostic.json`, lifecycle evidence, state, and tombstones are never uploaded automatically.
- Confirm diagnostic export remains user-initiated, redacts every window title, and contains no screenshot pixels.
- Verify disabling previews clears the in-memory cache and prevents new window captures; no production wallpaper capture should occur.
- Review dependency updates for automatic analytics, identity, capture, replay, network metadata, and endpoint changes.
- Archive the manifest, redacted diagnostic export, benchmark JSON, and selected Instruments trace with release evidence.
