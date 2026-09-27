# Debut privacy notice

Last updated: 27 September 2026.

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
lifecycle evidence. These files are not automatically uploaded.

Exporting diagnostics is user-initiated and writes wherever the save panel
points. The export replaces every window title with the same digest, so a file
attached to a public issue carries no document names, tab titles, or channel
names. Developer demo and isolated test tools deliberately write media and
evidence; those tools are separate from the installed app's preview cache.

## Data leaving your Mac

Debut does not upload analytics, usage data, performance observations,
diagnostics, screenshots, or window information. Local performance observations
are used for `diagnostic.json`, signposts, and developer-run benchmarks only.
The one exception is crash reports, and only with your consent.

### Crash reports

Release builds can send crash and hang reports to [Sentry](https://sentry.io),
the service the maintainer uses to diagnose them. Builds compiled from source have
no reporting destination and never send one.

Nothing is sent without your consent:

- After Debut quits unexpectedly, it asks at the next launch whether to send that
  one crash report. Choosing Don’t Send, or quitting without answering, deletes it.
- **Send crash reports automatically**, in Settings ▸ General, sends crash reports
  and macOS hang reports without asking. It is off by default and can be turned off
  at any time. While it is off, hang reports are never sent.

A report contains the Debut version, the macOS version and Mac model, processor
and memory details, the stack trace of each thread and the list of loaded
libraries at the moment of the crash or hang. Debut removes the Mac's name, the
home-folder name from file paths, and the identifiers Sentry would otherwise
attach to recognize repeat reports from one Mac. Reports contain no window titles,
screenshots, app lists, breadcrumbs of recent activity, or contents of Debut's
local files. Sentry receives the IP address of the connection that delivers a
report; the Debut project is configured not to store it. Reports are retained
according to the Sentry plan in use.

Before it is sent or deleted, a crash report waits in
`~/Library/Caches/io.sentry` on your Mac.

Diagnostic export is user-initiated. Debut writes the redacted JSON file only to
the location chosen in the save panel and does not transmit it. The user decides
whether to share that file afterward. Exports retain technical evidence such as
bundle IDs, process and window IDs, geometry, settings, performance summaries,
and lifecycle events, but replace window titles with installation-specific
digests. Exports contain no preview screenshots.

## Changes and review

Any future feature that transmits app or diagnostic data, or any change to what
crash reports contain, requires an updated privacy review, privacy manifest,
disclosure, and release checklist before it is enabled in a distributed build. See the [privacy release checklist](privacy-release-checklist.md).
