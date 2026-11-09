# Command Bar

**⌘T** opens the Command Bar. It creates no tab until you choose something: type to search your open tabs, pinned
tabs and Favorites, your history, Spaces and commands, or press Return to search the web with the profile's search
engine. **⌘L** opens it on the current page's address. Type **/** (or press **Tab** in the empty field) to list only
commands. Esc closes it.

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

- ChatGPT in the Command Bar (Arc Max's "gpt" + Tab).
- Instant Links (⇧Return opening the top results).
- Arc's toast suggesting a site search for a site you search often.
