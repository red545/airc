# Command Bar

**⌘T** opens the Command Bar. It creates no tab until you choose something: type to search your open tabs, pinned
tabs and Favorites, your history, Spaces and commands, or press Return to search the web with the profile's search
engine. **⌘L** opens it on the current page's address. Type **/** (or press **Tab** in the empty field) to list only
commands. Esc closes it.

Return opens the highlighted row: the top match as you type. The pointer only highlights a row once you move it, as in
Arc and native menus, so a pointer resting where the bar opens never changes what Return opens. Each key you type puts
the top match first again.

Results always come from the current Space's profile: another profile's history and tabs never show.

## Site Search

Search a site directly, without opening its front page first, as in Arc:

1. Press **⌘T**.
2. Type the site's shortcut (**yt** for YouTube) or the start of its name (**you**, **google m**). The row
   **Search YouTube · Press Tab** shows which site Tab will search.
3. Press **Tab**. The field empties and the site's name leads it ("Search YouTube…").
4. Type what you're looking for and press **Return**. Your pages on that site that match show under the search.

To go back to the plain Command Bar, press **Backspace** in the empty field (what you typed before Tab comes back)
or **Esc**. Click the site's name in the field to switch to another site (**Change Site Search**), to leave it
(**Remove … Site Search**), or to open its settings.

When a shortcut is also the start of an address the bar completes inline ("you" → youtube.com), Tab searches the
site; press **→** to accept the completion instead, or Return to open it.

Built-in sites, with their shortcuts:

| Site | Shortcut | Site | Shortcut |
|---|---|---|---|
| Google Drive | drive | YouTube | yt |
| Gmail | gmail | Wikipedia | wiki |
| Google Maps | maps | Reddit | reddit |
| Google Calendar | gcal | SoundCloud | soundcloud |
| Google Docs | gdocs | Asana | asana |
| Dropbox | dropbox | LinkedIn | linkedin |
| Amazon | amazon | Apple Music | music |
| GitHub | gh | Spotify | sp |
| Figma | figma | X | x |

These are the sites Arc seeds, with their search addresses as Arc has them. Arc's shortcuts for them aren't
public, so these are Airc's.

### Your own sites

**Settings → Site Search** (or type "Site Search Settings" in the Command Bar) lists the current profile's sites.
To add one, give it:

- a **name** ("YouTube");
- a **shortcut**: one or two letters work best ("yt"). No spaces, not starting with "/", and not one another site
  of the same profile already has;
- the **URL with %s in place of query**. Search the site for a word, copy the address from the address bar and
  replace the word with `%s`: `https://www.amazon.com/s?k=socks` becomes `https://www.amazon.com/s?k=%s`.

Airc refuses an address it can't search with: one without `%s`, with `%s` in the site's name, with spaces in it, or
one that isn't a web page (`javascript:`, `data:`, `file:` and the like). An address without `https://` gets it
added. Chrome's `{searchTerms}` works too and is shown as `%s`.

**Edit** changes a site, **–** removes it, and **Restore Default Sites** puts back built-in sites you removed (your own
stay).

### Profiles

Each profile has its own sites, like its own history and search engine: a site added in one profile isn't in the
others, and two profiles can use the same shortcut for different sites. Pick the profile at the top of
**Settings → Site Search**. A private window searches the sites of the profile it was opened from.

### Space or Tab

**Settings → Site Search → Start a site search with** chooses, per profile, **Tab** (the default, as in Arc) or
**Space or Tab**. With Space, a space typed right after a whole shortcut ("yt ") starts the site's search; after a
name or anything else a space is just a space, so a search like "you know" stays a search.

### How the search words are sent

Airc puts your words into the address exactly as Chromium does for its search engines, so a site gets the same
address it gets from Chrome or Arc: after a "?" spaces become "+" and every character but letters, digits and
`!'()*-._~` is encoded (`c++ & 50%` → `c%2B%2B+%26+50%25`); before it (`open.spotify.com/search/%s`) spaces become
`%20` and "/" stays. Words in other scripts are sent as UTF-8 (東京 → `%E6%9D%B1%E4%BA%AC`).

A site search's words go only to that site: they aren't sent to your search engine for suggestions.

### Bangs

As on DuckDuckGo, a word starting with **!** searches a site straight away: type **!yt cats** (or **cats !yt**) and
the first row says **Search YouTube for “cats”**; Return opens YouTube's results. The bang can go anywhere in what you
type, in any case (**!YT**). A bang alone (**!yt**) and Return or Tab starts the site's search, as its shortcut and
Tab do.

Every shortcut in **Settings → Site Search** works as a bang (**!gdocs**, or **!lb** for a site you added), and Airc
knows the common DuckDuckGo bangs too:

| Bang | Site | Bang | Site |
|---|---|---|---|
| !g | Google | !so | Stack Overflow |
| !gm, !maps | Google Maps | !r, !reddit | Reddit |
| !gt | Google Translate | !imdb | IMDb |
| !gi | Google Images | !x, !twitter, !tw | X |
| !gn | Google News | !ddg | DuckDuckGo |
| !gs | Google Scholar | !b, !bing | Bing |
| !yt | YouTube | !npm, !pypi, !crates | npm, PyPI, crates.io |
| !w, !wiki | Wikipedia | !mdn | MDN Web Docs |
| !a, !amazon | Amazon | !hn | Hacker News |
| !ebay, !etsy | eBay, Etsy | !wa | WolframAlpha |
| !gh | GitHub | !sp, !spotify | Spotify |
| !applemaps | Apple Maps | !applemusic | Apple Music |
| !li, !linkedin | LinkedIn | !pin, !twitch | Pinterest, Twitch |

Your own site with the same shortcut comes first. Bangs are looked up on your Mac: nothing is sent to DuckDuckGo to
find the site, and the words aren't sent to your search engine for suggestions. Google Translate translates into your
Mac's first language. A bang Airc doesn't know stays part of the search, so if your profile searches with DuckDuckGo,
DuckDuckGo's own bangs keep working.

## Ask ChatGPT

Ask ChatGPT (or Perplexity, or Claude) from the Command Bar, as Arc Max's "ChatGPT in the Command Bar" did:

1. Turn it on for a profile: **Settings → Site Search → Ask AI → Ask from the Command Bar**, and pick **ChatGPT**,
   **Perplexity** or **Claude**. It's **off** by default, as in Arc, where it was off until you opted in to Arc Max.
2. Press **⌘T**, type **gpt** (or **chatgpt**, **pplx**, **claude**, or the first four letters of the name) and press
   **Tab**. The row **Ask ChatGPT · Press Tab** shows what Tab will do. The site's name leads the field ("Ask ChatGPT…").
3. Type your question and press **Return**. It opens on the site in a **new tab** of the Space's profile, with the
   question filled in, even when the bar was opened with ⌘L:

   | Site | Address |
   |---|---|
   | ChatGPT | `https://chatgpt.com/?q=…` |
   | Perplexity | `https://www.perplexity.ai/search?q=…` |
   | Claude | `https://claude.ai/new?q=…` |

A question typed in the plain bar (three words or more, or with a "?") also gets an **Ask ChatGPT** row at the end of
the list. The command **New ChatGPT Message** (type it in the Command Bar) opens the bar ready to ask. Backspace in
the empty field or Esc goes back to the plain bar; click the site's name for **Stop Asking ChatGPT** or its settings.

- Airc needs no account and no API key. You're signed in on the site as you are when you open it yourself.
- Nothing is sent until you press Return. The question is in the page's address, so it's kept where any page you open
  is: in the profile's history. A private window keeps no history, and uses the choice of the profile it was opened
  from.
- Each profile has its own choice. Long questions are cut at 2,000 characters.
- Tried on 2026-11-10, signed out: ChatGPT opens with the question in its message field, and Perplexity searches it
  straight away. Claude asks you to sign in first and keeps the question in the sign-in address; whether it's filled in after
  signing in wasn't checked (no account was used).

## Instant Links

Type what you're looking for and press **⇧Return** to open the best result directly, as Arc Max's Instant Links did.
Ask for several ("top 3 pizza places in Lisbon", "best five hiking trails") and that many open, at most five.

1. Turn it on: **Settings → AI → Instant Links**. It's off by default and needs Apple Intelligence.
2. Type your search in the Command Bar. The row **Open the Top Result ⇧↩** (or **Open the Top 3 Results**) under the
   search row shows it's ready.
3. Press **⇧Return**. The bar says **Finding the best result…** for a moment, then shows what will open: the page, or
   **Open 3 Results** above the three. Nothing has opened yet.
4. Press **Return** (or ⇧Return again) to open them. The first opens where Return would open a result (a new tab with
   ⌘T, or the current tab with ⌘L); the others open as tabs under it. Click one page to open only that one, or the last
   row to search normally instead. **Esc** goes back to what you typed; Esc while it's still finding cancels it, and
   nothing opens.

How Airc finds the pages:

- Your words go to the profile's **default search** (its search engine, or the site search you made the default), as
  a search does. Its results page loads in the background in the same profile and only its links are read, on your
  Mac. That page doesn't go into Airc's history.
- When the page marks its results (a result's title in a heading, as results pages do), the first results are what
  opens, one per site where there are enough. The search engine's own links, ads and trackers are left out. No AI is
  used for this.
- When the page doesn't mark them (a site search's results, for example), Apple's on-device model picks from the
  links' titles. It sees only the titles and sites, and runs on your Mac.
- Only web pages open (`http` and `https`). `javascript:`, `data:`, `file:` and other addresses never do. A search
  engine's redirect link opens where it leads, if that's a web page.
- If nothing usable is found, the results page is too slow (8 seconds) or the model can't pick (4 seconds), Airc does
  a normal search instead.

Which search engines work (tried on 2026-11-10, on both of Airc's engines):

- **Google.** Its results go through Google's own redirect (`google.com/goto?url=…`), which says where it leads only
  once it's followed. Airc keeps a result only when Google printed its site under it, and the preview shows that site,
  marked **as shown by Google** ("github.com › swiftlang · as shown by Google"). Confirming opens the redirect, exactly
  as clicking the result on Google's page would; nothing is opened or fetched before that. In the test every page opened
  on the site the preview named, about a second after ⇧Return.
- **DuckDuckGo's results page.** To use it, add a site search with the address `https://html.duckduckgo.com/html/?q=%s`
  in **Settings → Site Search** and choose it under **Search with**. A top result in about 1.5 seconds.
- Bing, Kagi, Ecosia, Brave, Yahoo, Startpage, Perplexity and DuckDuckGo's regular page (the profile's built-in
  DuckDuckGo) haven't been tried yet. Perplexity shows an answer rather than a list of results, so expect a normal
  search there.

Without Apple Intelligence (macOS before 26, a Mac that can't run it, or it's turned off), the switch stays off, there's
no ⇧↩ row, and **⇧Return searches** what you typed with the profile's default search. Private windows never use
Instant Links: ⇧Return searches there too.

## Icons, row kinds and official sites

Every site in the Command Bar shows its own icon: an open tab's, or the one Airc or the engine kept when you last
visited it (imported history included, on the Chromium engine). Typing never fetches an icon: a site you haven't
visited shows its first letter on a colour of its own until you open it. Private windows show only those letters and
read no icon store.

Rows you haven't highlighted say what they are at their right end: **Website**, **Open Tab**, **Pinned Tab**,
**Favorite**, **Search**, **Space** or **Command**. The highlighted row shows what Return does instead.

A few sites carry a small check mark: the **Chrome Web Store** (marked **Supported in Airc**: extensions install from
it), Google's sign-in and apps, YouTube, GitHub, Apple Support and aircbrowser.com (marked **Official**). The mark comes
from a short list built into Airc, never from the page itself. It shows only for the exact address over https, so
`chromewebstore.google.com.evil.example`, a look-alike spelled with other alphabets, an IP address or plain http never
get one. The row shows the site's full address next to the mark, so you can always see where it goes.

## Removing a suggestion

To remove a page from the suggestions (and from the profile's history), highlight it and press **⌥⌘⌫**, Arc's key. The
first row counts as highlighted. **⇧⌫** works too, but only on a row you moved to with the arrow keys or the pointer,
so holding ⇧ while you delete text still deletes text. Only history suggestions can be removed: open tabs, pinned
tabs, Favorites, commands and search rows stay. Pointing at a history row shows a **✕** at its right end that does the
same. You can give the key another one in **Settings → Shortcuts → Command Bar** ([details](parity-p03b.md)).

## Typing in Japanese, Chinese and other input methods

While an input method is composing (the underlined text), the Command Bar leaves it alone: nothing is completed over
it, Tab, Space, Backspace and Return go to the input method, and no site search starts. Once you commit the text, it
is searched like anything typed, in the plain bar and in a site search.

## Not in Airc yet

- Arc's toast suggesting a site search for a site you search often.
