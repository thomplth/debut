# Debut privacy and anonymous performance data

Debut uses Accessibility and Screen Recording locally to manage windows and render previews. Screenshots, window titles, app names and bundle IDs, window/process IDs, paths, raw diagnostics, free-form errors, and precise device identity are never sent.

When “Share anonymous usage and performance data” is enabled, Debut may send bucketed operation counts, latency ranges, workload class, app version, and macOS major version. Records contain no persistent user or installation identifier. The initial transport is designed for TelemetryDeck's EU-hosted ingestion, with automatic capture, user identification, advertising, cross-app tracking, fingerprinting, and session replay disabled by construction.

The queue is bounded to 100 records and delivery is capped at 20 events per day. Unsent records are deleted immediately when sharing is disabled. Local `diagnostic.json` remains available and is never uploaded. Because anonymous records have no stable identifier, they cannot later be found for per-user deletion.

Operational access is limited to maintainers shipping Debut. Aggregate records are retained for at most 90 days. A privacy incident pauses export, preserves local evidence, rotates credentials, audits the allowlist, and documents remediation. Removing a vendor means disabling its endpoint, deleting its dashboard data, removing credentials, and re-running the release checklist. Contact the project maintainer through the public repository for privacy questions.

This engineering disclosure is not jurisdiction-specific legal advice.
