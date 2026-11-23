# Opening links

Right-click (or Control-click) a link in a page for ways to open it besides a click.

## Open Link in Space

**Open Link in Space ›** lists your Spaces in sidebar order, each with its icon, including Spaces of your other
profiles. Pick one and the link opens there as a new tab in Today. The window switches to that Space and shows the
tab, and the page you right-clicked stays as it was.

- The tab uses the chosen Space's profile, so it's signed in to whatever that profile is signed in to.
- A blank window (⌃⌘N) lists only its own Space.
- Private windows and Little Airc have no Space list: their links stay where they are.
- This works the same with either engine, also on pages that use Safari's engine for protected media.

## Peek and "another site"

In a pinned tab or a Favorite, a link to **another site** opens in Peek, a card over the page; a link on the **same
site** opens in place. ⇧-click opens any link in Peek, in any tab. Meeting links (Google Meet, Zoom, Teams, Webex,
Around) skip Peek and open in a new tab, as in Arc; ⇧-click one to Peek it anyway.

A site is a registrable domain, the way browsers draw the line for cookies and security (the Public Suffix List,
bundled with Airc):

- `docs.google.com` and `mail.google.com` are one site; so are `bbc.co.uk` and `news.bbc.co.uk`.
- `alice.github.io` and `bob.github.io` are two sites, because anyone can have a `github.io` name. The same goes for
  `a.co.uk` and `b.co.uk`, and for blogspot.com, vercel.app and the other shared hosting names.
- Addresses (`127.0.0.1`, `[::1]`) and single names (`localhost`, `intranet`) only match themselves. Ports don't
  count, and international names match their `xn--` form.

### Air Traffic Control and Peek

Rules in **Settings → Links** ("URL contains …" or "is equal to …" → a Space) apply to links from other apps, and, as
in Arc, to links that would open in Peek: a pinned tab's or Favorite's link to another site, a ⇧-clicked link, or a link
you follow inside Peek. When a rule matches, the link opens as a new tab in the rule's Space, signed in with that
Space's profile, instead of in Peek. Other links you click in a page never consult the rules, so a rule doesn't pull
an ordinary link out of the Space you're working in; neither do same-site links. Private windows and Little Airc keep
their own links.

## Other ways to open a link

- **⌘-click** opens the link in a background tab, and **⇧-click** opens it in Peek.
- **⌥⌘-click** opens it in Little Airc (see [Little Airc](little-arc.md)). Arc had this one modifier, ⌥⌘, and so
  does Airc. Turn it off in **Settings → Links → Little Airc**.
- **Settings → Links** decides where links from other apps open, and Air Traffic Control rules send a site's links to
  a Space.

## Links that open another app

A page can hand you to an app: a desktop app's sign-in ("You're signed in, return to the app"), a Zoom or Slack link,
`mailto:`. Airc asks first, as Chrome does: **Open “App”?**, naming the site that asked, with **Open** and **Cancel**.
On a secure site you can tick **Always allow … to open links of this type in the associated app**; that site's next
link of that kind opens the app without asking, in that profile only (never in a private window). Nothing opens until
you answer, and a link no app on your Mac handles says so instead.

Signing in to a desktop app through Airc works like in Chrome when Airc is your default browser, whether or not Airc
was running: the app's sign-in page opens in Little Airc (or where **Settings → Links** sends it), and its last page
either opens the app (after **Open “App”?**), sends you back over a `http://127.0.0.1` address the app listens on, or
closes itself.
