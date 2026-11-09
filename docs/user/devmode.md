# Developer Mode

Arc's Dev Tabs. A site in Developer Mode shows its **full URL** in the URL field (scheme, host, port, path and query;
never a user name or password), Arc's developer toolbar below it, and an outline on its selected row or Favorite tile
(yellow in dark themes, near-black in light ones). Its rows keep the site's own icon.

## The toolbar

- **Inspect** opens Developer Tools at Elements (Web Inspector on WebKit).
- **Network** (the globe; Chromium) opens it at its Network panel.
- **Reload** is a hard reload (⇧⌘R), bypassing the cache. Control-click it for **Clear data for <domain> and its
  subdomains and reload**: the site's cookies, storage and caches, in this profile only, then a reload. The Command Bar
  has it too. Private windows are never touched.
- The **console badge** opens the Console.

Each of them selects its panel in an inspector that's already open, which keeps its state: its console history, what
you were inspecting. WebKit selects only its Console; its Inspect opens Web Inspector as you left it.

## The menu bar

Arc's developer commands, in Arc's places. They work on any page, in Developer Mode or not, and in private windows on
the private page itself. The Command Bar finds each by name.

- **View › Clear Cookies and Refresh** removes the site's cookies (the site and its subdomains), keeps its storage and
  cache, and reloads the page. Signed-in sites sign you out.
- **View › Clear Cache and Refresh** removes the site's cached files, keeps its cookies and storage, and reloads past the
  cache.
- Both touch only the store of the page's own window: in a private window, its private session's, never your profile's.
  Other sites keep everything.
- **View › Developer**: View Source ⌥⌘U, Developer Tools ⌥⌘I, **Inspect Elements ⌥⌘C** (Developer Tools at Elements,
  picking an element on the page), JavaScript Console ⌥⌘J, **Network Inspector** (Developer Tools at Network) and
  Developer Mode for This Site ⌃D. Settings → Shortcuts can change their keys. WebKit can't choose a panel: Inspect
  Elements and Network Inspector open Web Inspector, and you pick its tab or its element picker there.

## Task Manager

**Help › Troubleshooting › Open Task Manager** lists Airc's processes as Chrome's Task Manager does: each tab, extension,
worker and helper with its profile, memory footprint, CPU and network use and process ID. Tabs that share a process show
its numbers on the first of them. Click a column to sort. **End Process** ends the selected rows' processes (their pages
show that they stopped; reload them). The browser itself can't be ended. The window updates once a second while it's
open and costs nothing when it's closed. ⌘W closes it.

- Private windows: opened from a regular window, the Task Manager shows their processes as "Private tab" or "Private
  window process", with no title or URL, and can't end them. Opened from a private window, it names that private
  session's own pages and can end them.
- WebKit lists Airc and each page's web content process. It doesn't report network use per page, and its shared network
  and GPU processes aren't listed.

## Which sites

- **localhost is on by itself**, as in Arc: `localhost`, its subdomains (`app.localhost`) and the loopback addresses
  (127.0.0.1, ::1). Settings → General → Developer Mode → "Turn on automatically for localhost" turns that off.
- **Any other site** is one switch away: Site Controls (the button in the URL field) → Developer Mode, **⌃D** (Arc's
  key; Settings → Shortcuts can change it), or the Command Bar's "Turn On Developer Mode for This Site".
- A site is its **host**: on for `localhost` means every port and path of it, in every tab, Space, window and profile.
  Airc remembers it. Turning off localhost is remembered too. Settings lists the sites you turned on, with Remove, and
  the localhost hosts you turned off, with Reset.
- **Private windows never use Developer Mode.** Their pages get no counter, no strip and no outline, and ⌃D and Site
  Controls don't offer it there. Nothing about a private page is remembered.
- **Upgrading** from the earlier Settings switch (on or off): localhost is on by itself, and no other site is turned on
  for you, including the `.test`, `.local` and LAN addresses that switch covered. Turn those on per site.

## The console badge

It counts the page's **top-frame `console.error` calls** since the document loaded or Developer Mode was turned on,
saturating at 9999+. A click opens the console. Counts stay in memory and never include what was logged. A dash means
there's no count for this page.

How it counts, and why call sites stay true: the page script only reports that a document started. Airc then decides
for that document (its origin, never a private page) and only then wraps `console.error`, as a native-forwarding Proxy
that leaves no Airc frame above the page's own call. The console shows the page's file and line, with the inspector
closed or open, and an ignore-list source map keeps the wrapper out of debugger stepping. A site that's off, frames
below the top and private pages get no wrapper at all; with no site able to be on (localhost automatic off and no site
turned on), nothing is installed. Errors logged in the first few milliseconds of a document, before Airc has answered
it, aren't counted. Workers, iframes, uncaught exceptions and network errors aren't counted; pages that replace
`console.error` can bypass the counter. Open the console for the full record.

## Usage data

Turning Developer Mode on or off (for a site, or the automatic switch) records `feature.used` with
`feature: developer_mode.toggle` and the closed variant `on` or `off`, subject to Settings → Privacy. No hosts, URLs,
console contents or counts are sent.
