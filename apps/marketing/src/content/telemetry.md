# Product usage data

Airc sends anonymous product usage events to PostHog's EU cloud (`eu.i.posthog.com`): which features get used,
and how fast Airc is. It is on by default. Events carry a random ID made on your Mac, never your name, an account,
or anything you browse, type or name. To turn it off, open **Settings → Privacy** and switch off **Share anonymous
usage data**.

## What is sent

Every event carries the same build details: the Airc version and build number, the channel (dev or stable), the
engine (Chromium or WebKit), the macOS version (major.minor, for example 26.6), the processor (arm64 or x86_64), the
language code of your Mac (for example `en`, never the region), and how many days ago the random ID was made, in
ranges (0, 1, 2-7, 8-30 …).

| Event | When | What else it carries |
|---|---|---|
| `app.launched` | each launch, when the first window shows | launch time in ranges, first launch or not, whether the last run ended cleanly or crashed |
| `app.active_day` | once per calendar day you use Airc | how many Spaces, profiles, pinned tabs, Favorites and open tabs, in ranges; the sidebar side; whether Airc is the default browser |
| `onboarding.step` | each step of the first run | the step, and next, skip or back |
| `onboarding.finished` | "Open Airc" | whether you imported from Arc |
| `import.arc` | an Arc import | success or failure; Spaces, tabs and profiles in ranges; whether logins came over |
| `import.browser` | an import from another browser, a bookmarks file or a passwords CSV file | which browser (chrome, brave, edge, vivaldi, opera, chromium, dia, helium, firefox, zen, safari, bookmarks_file or passwords_file); success or failure; profiles, bookmarks, folders, history entries and passwords in ranges; never a bookmark, page, site or password |
| `feature.used` | a feature is used | the feature's name, and for some a variant from a fixed list (below) |
| `perf.daily` | once per day | Command Bar opening time (median and 95th percentile, in ranges), memory use and background CPU, in ranges |
| `process.gone` | a renderer, GPU or utility helper ends abnormally | `process_type`: renderer, gpu, network, storage, audio, utility:data_decoder, utility:video_capture or other; `exit_signal`: SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS, SIGKILL, SIGTERM, exit or other; no URLs or paths |

The features: the Command Bar (new tab or edit URL), split view (made with 2, 3 or 4 panes, pinned, made a
Favorite), Peek (opened, opened as a tab), Little Arc (from the shortcut or a link from another app), picture in
picture (video, call or document), a new Space, a new profile, a new Favorite, an Air Traffic Control rule, Find,
the Back/Forward history menu, a download started or finished, Site Controls, the default-browser prompt (shown,
accepted, declined), an extension installed (never which), an update installed, the sidebar's update button shown
or clicked, a theme change, Live Calendar turned on or a meeting joined from it (never the meeting, its link or
its time), a Boost changed in its editor (never the site, its style or its code), a private window opened
(nothing about its pages, ever), and a tab preview's quick action (pin, unpin, add to or remove from Favorites,
split, Peek; never the tab, its site or its title), a shortcut changed in Settings → Shortcuts (never which
command or key), Tidy tab titles turned on or off in Settings → AI (never a title, a page or a name;
[ai.md](ai.md)), and a Capture copied, saved or shared (feature `capture`, variant `copy`, `save` or `share`; never
the page, its site, the picture or where it went, and nothing from a private window; [capture.md](capture.md)).

Numbers are only ever sent as ranges: "6-10 Spaces", "250-500 ms", never the exact value.

## What is never sent

Web addresses, hosts or domains; page titles; anything you type or search; history; the names or emojis of Spaces,
profiles or folders; account names or emails; extension IDs or names; file names; error messages; your IP
address as a property. Airc's events are built from fixed lists in the code (`packages/AircKit/Sources/AircKit/
Telemetry/TelemetryEvent.swift`), so none of these can reach them: there is no event that takes text. A unit test
serialises every event and fails on any property or value outside a strict list.

PostHog receives each batch over HTTPS from your Mac's internet connection, so like any web server it sees the
address the request comes from. Airc asks it not to look up a location from it (`$geoip_disable`) and marks every
event anonymous (`$process_person_profile: false`), so PostHog keeps no profile of you.

## Crash reports

When Airc or one of its helper processes (a page's renderer, the GPU process) crashes, macOS usually writes a crash
report on your Mac. Airc's main process is often too big for macOS to report, so Airc also writes a small crash record
of its own the moment it crashes, in `CrashRecords` in its data folder (the last three are kept, and every build writes
them). At the next launch, Airc sends its own new crash reports to PostHog's error tracking as `$exception` events,
with the same random ID and build details as the usage events. A crash that both macOS and Airc recorded is sent once:
the two are matched by build, time and process, and macOS's report goes when it's there. If **Share with app
developers** is on in macOS (**System Settings → Privacy & Security → Analytics & Improvements**), macOS also hands
Airc reports of hangs and of too much CPU or disk use (MetricKit), and Airc sends those the same way.

A crash report carries:

- the crashed thread's stack: for each frame, the binary it's in, the offset into it, and the function name macOS
  worked out (Airc's own record has no names: PostHog finds them, below);
- the names of those binaries (only Airc's own, Sparkle's and macOS's; any other binary shows as `other`), their
  UUIDs and where they were loaded;
- the exception type, signal, the signal's code and termination code (for example `EXC_BAD_ACCESS`, `SIGSEGV`), and
  which process it was (the browser, a renderer, the GPU process, another helper);
- the Airc version and build that crashed, and the macOS version (for example 26.6);
- where the report came from (`crash_source`: `signal` for Airc's own record, `ips` for macOS's, `metrickit`).

Airc's own record holds no more than that: the build, the signal, its code and the address that faulted, the crashed
thread's return addresses, and the name, UUID and load address of each of Airc's and macOS's binaries those fall in.
The faulting address and the process ID stay on your Mac, as they do from macOS's reports: Airc uses them only to tell
one crash from another.

It never carries file paths (they can hold your user name: binaries go by their file name only), the environment,
thread or queue names, the crash or exception message (it can quote a web address or what a page held), registers or
memory, or anything about what you were browsing. Airc reads only crash reports of its own processes, only those
written since it last looked, at most 10 a launch, and only while sharing is on: a crash from while it was off is
never sent. The strings in a report (binary and function names) are checked against strict formats, and a unit test
(`packages/AircKit/Tests/AircKitTests/CrashReportTests.swift`) fails on any key or value outside a strict list.

PostHog turns the offsets into function names and source lines with Airc's debug symbols, which the build uploads.
When a renderer, GPU or utility helper ends abnormally, Airc also counts it (`process.gone`, in the table above) with only the kind
of process and the signal.
Crash reports show in **See what Airc sends** like every other event. To stop sending them, switch off **Share
anonymous usage data** (below): the same switch covers both.

## See what Airc sends

**Settings → Privacy → See what Airc sends → Show…** lists the last 100 events, newest first, as the exact JSON
that goes to PostHog. The list updates live while it's open.

## How it is sent

Events wait on your Mac in `~/Library/Application Support/Airc/Telemetry/queue.json` (at most 1,000) and go out in
batches: 30 seconds after the first one, at once when 20 are waiting, and when you quit. If PostHog can't be reached,
Airc tries again later, waiting longer each time, and drops events older than a day. Nothing runs while no event is
waiting. The random ID is in `install.json` in the same folder.

## Turning it off

- **Settings → Privacy → Share anonymous usage data.** Turning it off throws away anything still waiting.
- **For good, from Terminal**, which also locks the switch off:

  ```bash
  defaults write "$(osascript -e 'id of app "Airc"')" AircTelemetryEnabled -bool false
  ```

  `defaults delete "$(osascript -e 'id of app "Airc"')" AircTelemetryEnabled` undoes it.
- **With an environment variable**: `AIRC_TELEMETRY_ENABLED=0` when you start Airc from a shell. Apps opened from the
  Finder or the Dock don't read your shell profile; `launchctl setenv AIRC_TELEMETRY_ENABLED 0`, then quit and reopen
  Airc, sets it for them until you log out.

**Reset** next to **Anonymous ID** in the same place makes a new random ID; nothing waiting under the old one is sent.

Builds without a PostHog project key (`infra/release/telemetry.json`, empty in source checkouts) record and send
nothing. Scripted and automated test runs never send to PostHog.

## For contributors

An event is a case of `TelemetryEvent`; a feature is a case of `TelemetryFeature` with an optional variant from a
closed enum. Count a feature at its one dispatch point with one line:

```swift
Telemetry.shared.record(.featureUsed(.splitCreate(panes: 2)))
```

Recording only hands the event to Airc's telemetry queue; it is safe on the main thread. Add the new case to the
allowlist in `packages/AircKit/Tests/AircKitTests/TelemetryEventTests.swift` and to this page. Numbers go through
`TelemetryBucket`; never add a case that takes a `String`.

A crash report is a `CrashReport` (`Telemetry/CrashReport.swift`), parsed from an `.ips` file, a MetricKit payload or
one of Airc's signal records (written by `apps/browser/Sources/AircCrashLog/CrashLog.c`, async-signal-safe, in every
build) and recorded with `Telemetry.shared.record(report)`. A new field goes through a format check there and into the
allowlist in `CrashReportTests.swift`. A published build keeps its dSYMs in `build/dSYMs` on the build Mac
(`scripts/build-app.sh`), and `infra/updates/upload-symbols.sh` sends new ones to PostHog after each publish.

Developer Mode records only its setting toggle: `feature.used`, feature `developer_mode.toggle`, closed variant
`on` or `off`. Inspect, Hard Reload and the console badge add no events. No host, URL, message text or error count
is collected. See [Developer Mode](devmode.md).
