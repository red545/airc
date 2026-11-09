# Ads and trackers

Airc blocks ads and trackers by default in every profile. This update also turns
blocking on for existing profiles without an explicit choice. The migration runs
once; a profile you explicitly turn off stays off across restarts and updates.
There is no prompt to turn blocking on. The update preserves your selected lists,
site exceptions, and third-party cookie setting.

Open **Settings → Profiles** to change **Block ads and trackers**. EasyList and
EasyPrivacy are selected by default. **Block cookie banners** and regional lists
are optional downloads. Blocking cookie banners can break consent dialogs or
parts of a page; turn that list off if a site stops working.

In **Site Controls**, use **Block Ads & Trackers** to turn blocking off or back on
for the current site. Airc reloads the page after applying the change. **N blocked
on this page** counts confirmed blocked network requests since the last full
navigation or reload. Cosmetic hides do not increase the count. The Command Bar
also has **Turn Off Blocking for This Site**, **Turn On Blocking for This Site**,
and **Ad & Tracker Blocking Settings…**.

Site exceptions apply to the exact hostname in that profile. See and remove them
under **Sites where blocking is off**. Removing an exception takes effect on the
next reload. Other profiles keep their own settings and exceptions.

Private windows use the profile’s protection and lists. Site Controls is beside
the private window’s address. Changes there last for that private session: they
are shared by its private windows and forgotten when the last one closes. Private
exceptions never enter the ordinary profile’s settings or disk rules cache.

## Other blocker extensions

If Airc finds another enabled blocker extension, it offers **Keep Both** or
**Turn Off Other Blockers**, naming the extensions it will change. Airc disables
those extensions only after you choose the latter. Turning Airc’s blocker off
does not disable, remove, or re-enable extensions. You can manage extensions
separately.

## Lists and privacy

The app includes seed copies of EasyList and EasyPrivacy, so protection works
offline. Selected lists refresh directly from their authors’ HTTPS hosts every
four days, or later if a list’s expiry asks Airc to wait. Airc uses ETag or
Last-Modified validators when available. **Update Now** requests a refresh sooner.
A failed download or compilation keeps the previous working rules.

These requests reveal your IP address to the list hosts. They contain no browsing
history, site-exception list, or blocked-request log. They use no account, cookies,
or saved credentials. Current sources are shown in **Lists…**:

- EasyList and EasyPrivacy: `easylist.to`.
- EasyList Cookie List: `secure.fanboy.co.nz`, only when selected.
- EasyList Germany: `easylist.to`, only when selected.
- Liste FR: `easylist-downloads.adblockplus.org`, only when selected.

Blocked counts stay in memory. Airc does not store the blocked URLs. Scripted
checks disable list-host downloads and use local fixtures.

**Block third-party cookies** is a separate switch, off by default. It can affect
embedded sign-ins and other cross-site features. Turning it off does not remove
private browsing’s or Safari’s engine’s existing cookie protections. A managed
browser policy may prevent changing Chromium’s setting.

## Engine differences

Both engine integrations use Brave’s adblock-rust to interpret lists. Chromium
checks network requests with their resource type, initiator and party context;
it also applies supported parameter-removal and content-security-policy rules.
Pages using Safari’s engine use cached WebKit content rules converted from the
same selected lists. Both apply ordinary hostname and generic cosmetic selectors,
including cosmetic exceptions, through Airc’s document-start page scripts.

The WebKit conversion cannot express every EasyList feature. Full regular
expressions, resource redirects, CSP, parameter removal, some domain constraints,
and some request types/options are omitted. Cosmetics are handled separately by
Rust on both engines, so WebKit’s CSS conversion cannot override cosmetic
exceptions or generic-hide exceptions. WebKit evaluates first/third-party context
against the top page; Chromium uses the requesting frame’s initiator. A request
inside a cross-site iframe can therefore receive a different decision. Airc does not run
list-supplied scriptlets or procedural cosmetic actions on either engine, and
ships no uBlock scriptlet/resource bundle. Generic cosmetic discovery is bounded
to protect page responsiveness. A list’s presence does not guarantee every rule
in that list applies to every page.

Counts cover requests the engine can attribute to the page. Browser background
traffic and work without a live page cannot always be attributed to a tab. The
WebKit count is based on WebKit’s confirmed blocking callbacks, not failed loads
or predicted matches. Airc has no special YouTube exception.

## Attribution and converted rules

**The EasyList authors** — <https://easylist.to/> — provide the bundled EasyList
and EasyPrivacy under **CC BY-SA 3.0 or later**. Airc distributes them under that
license. Their source lists, the converted WebKit and native rulesets, conversion
report and SHA-256 manifest are published inside each app at
`Contents/Resources/BlockingLists`; the release build also writes copies to
`build/blocking/published`. The `.deflate` artifacts use zlib compression.
Conversions are offered under the same CC BY-SA license. The converter source is
in `engine/core/blocking-rust`.

Brave’s adblock-rust is MPL-2.0; its source and dependency notices are included in
Airc’s source tree, with license texts in the app’s Licenses folder. Airc bundles
no GPL filter lists and no uBlock Origin Lite. Optional lists download from their
authors only after the user selects them and retain their own licenses.
