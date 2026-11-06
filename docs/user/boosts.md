# Boosts

A Boost changes how one website looks for you, every time you visit it: a softer color, a darker page, a font you
like, without the parts you never want to see. Like Arc's Boosts, without an account: they stay on your Mac.

## Make one

Open **Site Controls** (the slider button in the URL field) and choose **Boost this site**, or use
**View → Boost This Site…**. The Boost editor opens over the corner of the page, and everything you change shows on
the page at once.

- **Colors:** a tint (pick a hue, then how strong), brightness, contrast, and **Invert** for a quick dark mode.
  Pictures and video keep their own colors when the page is inverted.
- **Font:** one of a few fonts that come with macOS, and a size. The size scales the page's text and pictures
  together, so the layout keeps its proportions.
- **Zap:** choose **Zap Elements**, point at something on the page and click it. It's hidden from now on, on every
  visit. The list under the button shows what you zapped: undo one, or **Reset Zaps** for all of them. Press Esc or
  **Done Zapping** to stop.
- **Code:** your own CSS and JavaScript for the site. Press **Save** (or ⌘S) to apply them. CSS applies at once;
  JavaScript runs once each time a page loads, after the page is parsed. A changed script runs when the page reloads.
  - JavaScript runs only on the host you saved it on (`www.nytimes.com`, not `cooking.nytimes.com`). Switch on
    **All of nytimes.com** under the code to run it on every page of the site. Saved on another host of the site, it
    offers **Run Here Instead**.

A Boost's colors, font, zaps and CSS are for a whole site: one made on `www.nytimes.com` also applies to
`cooking.nytimes.com`, but not to any other site. Boosts are the same in every Space and profile.

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
- Only code you write in the editor ever runs. Airc never downloads Boost code. (Arc's Boosts lived on Arc's server,
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

- Boosts style the page itself, not the frames inside it (an embedded video or map keeps its own look).
- The style is in place before the page first appears, so a boosted page never flashes its old look.
- CSS `@import` doesn't work in a Boost; `@font-face` with your own font file does, if the site allows fonts from
  elsewhere.
