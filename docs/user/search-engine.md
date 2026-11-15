# Your search engine

Each profile has its own search engine, as in Arc. Words you type that aren't a web address search it: in the Command
Bar (⌘T, ⌘L), the URL field, **Paste URL in New Tab** (⌥⌘V), Little Airc and a private window of that profile.

## Choose it

1. Open **Settings → Profiles** and find the profile.
2. Open **Default search engine** and choose one: Google, Bing, DuckDuckGo, Ecosia, Brave, Yahoo, Startpage,
   Perplexity or Kagi. These are the engines Chromium offers across regions, which is the list Arc showed, plus Kagi.

Another profile keeps its own choice. Say Personal searches DuckDuckGo and Work searches Brave: a Space using Work
searches Brave, its private windows too.

Any site can be the default as well: add it in **Settings → Site Search** with a `%s` address and choose it under
**Search with** ([A site search as your default search engine](parity-p07d.md)). While a site is the default,
**Settings → Profiles** says so under **Default search engine**.

## Bring your engines from Arc, Chrome or Brave

Importing from Arc (at first launch, or **Settings → Import**) brings each Arc profile's search engines into the Airc
profile it becomes. Chrome and Brave profiles come over the same way.

- **The default.** If the profile's default is one Airc lists (Google, Bing, DuckDuckGo, Ecosia, Brave, Yahoo,
  Startpage, Perplexity or Kagi), the Airc profile uses it. Any other default comes over as a site search and becomes
  the profile's default, so **Settings → Profiles** says "Searching with …, from Site Search." A profile that never
  chose an engine keeps what it has in Airc.
- **Your own engines.** Engines you added yourself, with their shortcuts, become site searches of that profile
  (**Settings → Site Search**). Type the shortcut, press Tab, then your search, as in Arc's Command Bar: "yt", Tab,
  "lofi".
- **Left out.** Sites Chromium added on its own, which Arc's search settings listed as inactive shortcuts; its built-in
  engines you didn't choose; engines set by an organization's policy; and any engine whose address isn't an https search
  page with the search words in it (a `javascript:` or plain `http:` one, for example). The import's **Details** say how
  many were left out.
- **Already there.** A shortcut you already use in Airc for another site keeps that site. Importing again updates what
  an earlier import brought, and never what you added or edited in Airc.

Airc reads a private copy of the browser's `Web Data` file, so the browser can stay open. Nothing is sent anywhere.

## Search suggestions

While you type in the Command Bar, Airc asks the profile's search engine for suggestions, as Arc did.

- **Include search engine suggestions** (Settings → Profiles) turns them on or off for one profile, as in Arc. It's on
  until you turn it off.
- **Search suggestions** in **Settings → Privacy** turns them off for every profile.
- Only the profile's own engine is asked, without cookies, and each profile is asked separately, so nothing you type in
  one profile shapes another's suggestions. A site search's words are never sent to the engine.
- A private window asks the same engine, under the same switch, and keeps nothing once it closes.
- A site search made the default has no suggestions: nothing is sent while you type.

## Searching selected text

Right-click text you selected on a page and choose **Search DuckDuckGo for “…”** (it names your profile's engine, or
the site you made the default). The results open in a new tab of the same Space, or a new private tab in a private
window. In Little Airc they open in its window; Back returns to the page. On Safari's engine (sites set to play
protected media there) the item reads **Search with DuckDuckGo**.

The engine's own item, which always said Google, is gone. **Look Up** in the same menu is macOS's dictionary, not a
search, and is unchanged.

## Links from other apps

A link from another app opens as the link it is (in Little Airc, or where Settings → Links sends it), never as a search.
Text selected in another app and looked up with Little Airc's shortcut searches the default of the Space's profile.

## Not yet

- An imported engine's own suggestions: Airc asks only the engines it lists for suggestions, so an imported site
  search (a custom default included) has none.
- Instant Links (⇧Return) has been tried on Google and DuckDuckGo's results pages only. Brave, Bing, Ecosia, Kagi,
  Yahoo, Startpage and Perplexity are untried; Perplexity's answer page is likely to fall back to a normal search.
