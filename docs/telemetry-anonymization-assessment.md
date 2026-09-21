# Telemetry anonymization assessment

Assessment date: 21 September 2026

Owner: Debut project maintainer

Scope: the direct TelemetryDeck export implemented by `TelemetryPayload`,
`TelemetryDeckClient`, and `TelemetryExporter`

## Data flow and purpose

Debut measures coarse reliability and performance characteristics. After an
explicit opt-in and completed onboarding, it sends allowlisted HTTPS events to
TelemetryDeck's European Union ingestion endpoint. TelemetryDeck receives the
network connection and the event; Debut receives aggregate dashboard results.
The exported records contain no account, user, installation, session, trace, or
device identifier. `clientUser` is deliberately empty.

The detailed allowlist, denylist, rate limits, local queue behavior, recipient,
and retention facts are maintained in the [privacy notice](privacy.md) and
[performance payload contract](performance-observability.md#remote-privacy-contract).

## Risk assessment

### Singling out

Risk is low but not asserted to be zero. A rare combination of app version,
macOS major version, workload class, operation, latency bucket, and receipt time
might distinguish one event in a small dataset. It does not identify the person
or installation and Debut provides no value that can reliably follow that source
over time. Coarse buckets, aggregate counts, low daily volume, and the absence of
free text limit this risk.

### Linkability

Records have no stable join key. Debut sends no user, installation, session, or
trace identifier, and repeated events cannot be reliably linked to the same Mac
from their payloads. An IP address is necessarily visible while an HTTPS request
is routed and accepted. TelemetryDeck states that it does not store or log IP
addresses; this assessment depends on that vendor practice remaining true.

### Inference

The payload can support broad inferences about app performance, such as whether
a class of operation was slow under a coarse workload. It does not contain app
or window names, titles, paths, locale, precise hardware, screenshots, user
content, or behavior histories. It is not suitable for inferring a person's
identity, interests, communications, or activity in another app.

## Conclusion

The current design is reasonably treated as anonymous product analytics for the
maintainer's engineering use because the payload has no stable identifier and
offers little practical means to identify or track a person or installation.
That conclusion is technical, not a blanket legal exemption. The maintainer must
still check the rules that apply to the actual location, distribution, and
product behavior at release time.

## Review triggers

Repeat this assessment before release if any of the following changes:

- an account, user, installation, session, trace, advertising, or device identifier is added;
- the direct client is replaced by an SDK that adds automatic fields;
- IP addresses or other request metadata are stored, logged, or exposed to the maintainer;
- exact timestamps, exact durations, finer buckets, precise hardware, locale, free text, paths, titles, or user content are added;
- event volume increases materially or user-level journeys, funnels, or cohorts are introduced;
- a new recipient, endpoint, hosting region, purpose, or data-sharing arrangement is introduced;
- TelemetryDeck changes its anonymization, subprocessor, network-metadata, or retention practices; or
- Debut begins deliberately targeting a new jurisdiction or distribution channel with different privacy requirements.
