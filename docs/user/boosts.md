# Boosts

A Boost changes how one website looks for you, every time you visit it: a softer color, a darker page, a font you
like, without the parts you never want to see. Like Arc's Boosts, without an account: they stay on your Mac.

## Make one

Open **Site Controls** (the slider button in the URL field) and choose **Boost this site**, or use
**View → Boost This Site…**. You can also choose **New Boost…** in the sidebar’s **+** menu or Command Bar, or press **⌃⇧B**. With no website open, Airc asks for a site. The Boost editor opens over the corner of the page, and everything you change shows on
the page at once.

- **Colors:** a tint (pick a hue, then how strong), brightness, contrast, **Original Saturation** (how much of the
  page's own color stays; at 0 % the page is grey under your tint), and **Invert** for a quick dark mode. Pictures and
  video keep their own colors when the page is inverted.
- **Font:** one of a few fonts that come with macOS, a size, and a **Case**: the site's own, Title Case, CAPITALS or
  lowercase (fields and code keep theirs). The size is the page's zoom, the same zoom ⌘+ and ⌘− change, so the page
  reflows to fit the window as it does when you zoom: a page built to fill the window still fills it, not more. If you
  zoom a boosted page yourself, Airc leaves your zoom alone (the editor says so), and puts the page back to 100 % when
  you remove the size or the Boost.
- **Zap:** choose **Zap Elements**, point at something on the page and click it. It's hidden from now on, on every
  visit. The list under the button shows what you zapped: undo one, or **Reset Zaps** for all of them. Press Esc or
  **Done Zapping** to stop. Zap works inside the page's frames of the same site too (an embedded editor or comments
  box of the site): what you zap there is hidden in those frames, and the list says **In a frame**. A frame of another
  site (an ad, an embedded video) is zapped whole: point at it and click.
- **Code:** your own CSS and JavaScript for the site. Press **Save** (or ⌘S) to apply them. CSS applies at once;
  JavaScript runs once each time a page loads, after the page is parsed. A changed script runs when the page reloads.
  - JavaScript runs only on the host you saved it on (`www.nytimes.com`, not `cooking.nytimes.com`). Switch on
    **All of nytimes.com** under the code to run it on every page of the site. Saved on another host of the site, it
    offers **Run Here Instead**.

The Boost's name at the top of the editor opens its menu: **Rename This Boost…**, **Reset All Edits** (every setting,
zap and line of code back to none), **Share Boost…** and **Delete This Boost**.

A Boost's colors, font, zaps and CSS are for a whole site: one made on `www.nytimes.com` also applies to
`cooking.nytimes.com`, but not to any other site. Boosts are the same in every Space and profile, as in Arc, which
never had Boosts for one Space or profile ("we don't support applying Boosts to specific Profiles").

### What counts as a site

Airc uses the whole [Public Suffix List](https://publicsuffix.org/), the list Chromium uses to keep sites apart. It
includes addresses where anyone can get their own site, such as `github.io`, `duckdns.org` or `uk.com`. So
`alice.github.io` and `bob.github.io` are two sites, and a Boost made on one never applies to the other.

An address that is itself on the list (`github.io`), an IP address, or `localhost` is a site of its own: just that
address, without the sites under it.

## Turn it off or delete it

On a boosted site the URL field shows a small brush, and Site Controls shows **Boosted** with a switch. Switching it
off puts the page back the way the site made it; a page where your JavaScript already ran reloads. The switch in the
editor does the same, and **Delete** removes the Boost.

## Privacy and safety

- Boosts are stored in `Boosts.json` in Airc's data folder, readable only by you. They're never synced or sent
  anywhere, and the usage data never names a site, its style or its code (see [telemetry.md](telemetry.md)).
- Only code you save in the editor or explicitly install after reviewing a shared file runs. Airc never downloads Boost code. (Arc's Boosts lived on Arc's server,
  which once let other people run code in Arc users' browsers.)
- Your JavaScript is sent only to pages of its own site, and runs only where the page's address is exactly the one the
  browser loaded: the site comes from the browser, never from what the page claims.
- Changes you make while a page is open go only to that page. A page that has since been replaced (by another page, a
  file or a `blob:` page) gets nothing, and another page can't pick up a Boost's style by tampering with JavaScript.

### Boosts from earlier versions

Earlier test builds of Airc knew only part of that list. If one of them kept a Boost for a shared address, such as
`duckdns.org` for the site `you.duckdns.org`, that Boost is now paused: it applies nowhere and its code doesn't run.
Open the editor on your site and choose **Use for you.duckdns.org**, or **Delete It**. Every other Boost works as
before, with its code on the whole site.

## Good to know

- **Frames:** a Boost also styles the frames of its own site inside the page (a site's embedded editor, comments or
  sign-in box on another of its hosts): the font, case, hidden elements and your CSS. A frame of another site keeps its
  own look, even if that site has a Boost of yours: an embedded video or map is part of someone else's page. Your
  JavaScript stays in the page itself. Pages of streaming services that play in Safari's engine
  ([Protected media](protected-media.md)) work the same way, frames included.
- The style is in place before the page first appears, so a boosted page never flashes its old look.
- **`@import` in your CSS** loads only from the page's own site or from a `data:text/css` URL, written at the top of
  the CSS as CSS requires. An import from another site (a web font's stylesheet, say) is skipped, and never
  requested: paste that CSS in instead. The Code section lists each import and whether it loads; a page whose security
  policy forbids loading it, or a file that isn't CSS, is listed there too. A site's own imports apply once they have
  loaded, like the site's own stylesheets.
- `@font-face` with your own font file works, if the site allows fonts from elsewhere.
- **Your Space's colors:** every page has its Space's theme as Arc's CSS variables, so a Boost can use
  `var(--arc-palette-background)`, `var(--arc-palette-foregroundPrimary)` and the rest ([Space themes](themes.md#your-theme-on-web-pages)).
- **Private windows:** Boosts are off there, as in Arc: a page in a private window shows the site as it is, from its
  first moment, and isn't resized. Your Boosts are untouched, and you can't make or edit one from a private window.

## Share a Boost

Choose **Share…** in the editor (or **Share Boost…** in its menu or in **Settings → Boosts**). Give it a name, your
own name if you like (anyone can type any name, so Airc marks it as not verified), and a line about what it does. If a
page of the site is on screen, a screenshot of it goes along: check it shows nothing private, or switch it off.

- **Copy Link** puts a link on the clipboard: `https://aircbrowser.com/boost#…`. The whole Boost is in the part after
  `#`, which a browser never sends anywhere, so the link works without any server, and opening it in Airc sends the
  Boost nowhere. Links are for small Boosts and carry no screenshot; a big one (lots of CSS) is shared as a file.
- **Save File…** saves a `.airc-boost` file, with the screenshot.

Shared Boosts need a registrable site; Boosts for IP addresses, localhost or public suffixes can't be shared. A Boost
with JavaScript can be shared, but whoever installs it sees all of the code and has to allow it. (Arc didn't let
Boosts with JavaScript be shared at all.)

**Changing a shared Boost:** as in Arc, a change you make after sharing reaches nobody by itself. Share it again and
the new link or file is the next version of the same Boost: anyone who added an earlier one is offered it as an
**update**. A Boost you added from someone else and share on becomes a new Boost of yours.

## Add a Boost

Open a link (in Airc, or from another app with Airc as your browser), open a file in Finder, drag it onto the
browser's background, choose **File → Open…**, or pick one in the **Boost Gallery**. Airc first shows a review, as
Arc's "Add this Boost?" did: its name, who says they made it, its screenshot (or a sketch of its colors and font), what
it changes in words, the hidden elements, all CSS and all JavaScript, with a note if it's for a site you haven't visited
in a while. **JavaScript can read and change pages and send data to other websites.** Only allow code you understand
and trust.

- **Try It On** shows its colors, font, size, hidden elements and CSS on the site's pages while the review is open (it
  opens the site if it isn't on screen). Its JavaScript never runs before you add it. **Cancel** takes it off again and
  changes nothing.
- **Add Boost** (**Add and Allow Code** for one with JavaScript) adds it in every Space and profile, and shows the site
  with it on.
- A newer version of a Boost you added says **Update this Boost?** with the two versions; if you changed your copy
  since, it says that updating replaces your changes. An older version says it's older.
- When the site already has another Boost, the review shows that one's settings and full code too; **Replace**
  overwrites it. Reload pages where its JavaScript already ran.

## The Boost Gallery

**File → Boost Gallery…**, the Command Bar's **Boost Gallery**, or **Settings → Boosts → Browse Gallery…** open
Airc's starter Boosts: a calmer Wikipedia, a night one, a comfortable Hacker News, a focused YouTube, a wide GitHub and
others. Each is style only, no JavaScript. **Get** opens the same review, with Try It On. Arc's gallery was a website of
community Boosts; Airc has no server for Boosts, so the community's come as links and files.

Settings → Boosts lists every saved Boost with where it came from (shared by you, from someone, from the gallery,
edited since), an on/off switch, Edit, Share and Delete.

## The file format

Strict JSON, version 2, at most 512 KB (128 KB each for CSS and JavaScript, up to 200 hidden elements, a JPEG or PNG
screenshot of up to 300 KB). Besides the site, name, date, colors, font, hidden elements, CSS and JavaScript (with its
host), it can name the shared Boost's id and version, its author and a line about it. Version 1 files from earlier
builds still open. Unknown fields, invalid settings, newer versions and invalid sites are refused before review.
