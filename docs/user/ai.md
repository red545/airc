# AI in Airc

Airc's AI features run on your Mac with Apple Intelligence (Apple's on-device Foundation Models). There's no account,
no API key and no cloud service: nothing you ask, read or download is sent to Apple or anyone else for them. Each is off
until you turn it on in **Settings → AI**:

- [Tidy tab titles](#tidy-tab-titles): short names for long tab titles.
- [Ask on Page](#ask-on-page): a question about the page you're on, answered from its text.
- [Link previews](#link-previews): ⇧ over a link for a short summary of the page it opens.
- [Tidy downloads](#tidy-downloads): a clean name for a download called "IMG_2041 (1).pdf", to choose or applied by
  itself with Undo.
- [Instant Links](command-bar.md#instant-links): ⇧Return in the Command Bar opens the best result directly.

[Tidy Tabs](#tidy-tabs) has no switch: it runs only when you click **Tidy** or choose it in the Command Bar.

## Tidy tab titles

Long or noisy page titles of pinned tabs and Today tabs get a short, clean name in the sidebar, as Arc Max did:

| The page's title | In the sidebar |
|---|---|
| Inbox (3) - someone@example.com - Gmail | Gmail Inbox |
| Pull requests · example-org/example-repo · GitHub | GitHub Pull Requests |
| (12) Home / X | X Home |

- **Settings → AI → Tidy tab titles** turns it on. It's off by default.
- Short, clean titles ("GitHub", "Figma") stay as they are; nothing is asked about them.
- A tab you renamed keeps your name, and its page is never sent to the model.
- The page's own title shows when you rest the pointer on the tab, in the tab preview. With **Show tab previews** off
  (Settings → Appearance), it shows as the tab's tooltip.
- Favorites, folders and split views keep their titles.
- **Private windows are never tidied**: their pages' titles never go to the model.

### What the model sees

For each page: its title with unread counts and email addresses taken out ("Inbox - Gmail"), and the site's host
("mail.google.com"). Never the rest of the address, the page's contents, your history or anything you typed. The model
runs on your Mac; Airc sends nothing to Apple or anyone else for this.

Names are made a moment after a page's title arrives, when you aren't typing or scrolling, a few at a time. Each request
gets at most 4 seconds; a page whose request fails or takes longer keeps its title and is tried again later.

### What's kept

Names are kept in `TidyTitles.json` in Airc's data folder (`~/Library/Application Support/Airc/`), by page address,
with a fingerprint of the title each was made from (its letters, without counts, numbers or email addresses), so a
name stays while only a count changes and a page with a new title gets a new name. The file never holds the titles
themselves; it is never synced, backed up with your Spaces or sent anywhere. It keeps up to 1,000 pages, the least
recently used going first. **Turning Tidy tab titles off deletes it.**

## Ask on Page

Ask a question about the page you're on, as with Arc Max's Ask on Page: **⌘F**, then the ✦ button (or type the
question and press **⌘↩**), or **Ask This Page…** in the Command Bar. Type your question and press **↩**.

- The answer appears under the bar as it's written, in a few sentences.
- Below it are up to three of the page's own sentences the answer is based on. Click one and the page scrolls to it
  and highlights it. A sentence the model "quotes" that isn't on the page, or that shares no words with your question,
  is never shown (words it shares only with the answer prove nothing).
- **The answer is checked against those sentences** in a second, short request to the same on-device model (about
  half a second): do they support it, contradict it, or neither? Sharing words is never taken as proof.
  - Supported: the sentences show under the answer, and the card says it checked them.
  - Contradicted: "The page seems to say otherwise:", with what the page says.
  - Neither, or the check couldn't run: the sentences show as **related text, not proof**, and the card says the
    answer isn't confirmed by the page. A yes or a no is replaced by "Not confirmed by the page." (or "The page
    doesn't say." when the sentences don't mention what you asked), rather than shown bare.
  - No sentence at all: "The page doesn't say." for a yes or a no; for anything else the card says no sentence backs
    the answer up.
- These sentences come in the question's language (English, German, French, Spanish, Italian, Portuguese or Dutch,
  told from the whole question).
- An answer the model stopped writing partway shows as an **Unfinished answer**, with what it had written and why.
- **Esc** or ✕ closes it, and so does switching to another tab. ✦ or **⌘F** goes back to Find. While you ask, typing
  and ⌘G don't search the page.

### What the model sees

The page's visible text, as you'd see it (not hidden parts, scripts or form fields), read when you ask, at most
200,000 characters; the page's title and its site's host; and your question (at most 300 characters). Never the rest of
the page's address, its cookies, your other tabs or your history.

Apple's on-device model reads about 4,000 tokens at a time (a few pages of text). When the page is longer, Airc picks
the parts that share the most words with your question (or the start of the page for "summarize this page"), and the
card says the answer comes from those parts.

### When it doesn't answer

- **Private windows:** never. Their find bar has no ✦.
- **A page with more than 200,000 characters of text** (a book, a long spec): Airc says it's too long and suggests Find.
- **A page without text** (an image, an empty page): Airc says so.
- **Apple Intelligence off or not ready:** the card says what's needed.
- The model has 20 seconds to start answering and 45 seconds in all; one that takes longer is stopped and the card says
  so. Apple's model may also decline a question (its safety guidelines); the card says it couldn't answer.

The text of the page and your question are kept only while the card is open: closing it stops the model at once and
lets go of both. **Clear Data** and deleting a profile (Settings → Profiles) close every Ask card about that profile's
pages, in any window: the answer and its check stop, a page still being read is dropped, and the question is cleared.
Cards about other profiles stay. Nothing is saved. Picking the parts of a long page and finding its sentences again happen in the
background, so the window stays responsive.

## Link previews

Hold **⇧** over a link (move onto it with ⇧ down, or press ⇧ while you're on it), or **press and hold** a link for half a
second, and a card under the link shows the page it opens: its title, a two- or three-sentence summary and its key
points, as with Arc Max's 5-second previews.

- Move away from the link (and the card) and the card goes, and with it the preview's load and summary if they
  weren't finished. Click the card, or its ↗, to open the page in a new tab.
- A card belongs to the page its link is on, in that page's profile: it goes as soon as that page leaves the screen
  (another tab, Space or split shown, the tab closed) or navigates. The same link on another profile's page (a work and
  a personal account at one address) gets its own preview, made in that profile.
- A press and hold that showed a card doesn't also open the link when you let go.
- **⋯ → Never Preview Links on this site** stops previews of that site's links and of links on its pages. Settings → AI
  lists those sites, with **Clear**.

### How a preview is made

- Airc loads the link's page in the background, **in the same profile** as the tab, so pages you're signed in to
  preview as you'd see them. It's an ordinary visit for that site: it may set cookies, as opening the link would, and it
  shows in the engine's own history (chrome://history) on the Chromium engine. It never appears in your sidebar, Airc's
  history or the ⌘T Command Bar. Its sound is muted, and anything it tries to open is closed.
- The model gets the page's title, its host and the start of its visible text (about 2,400 tokens), without menus and
  other short bits. Pages with less than about 30 words get no summary; the card says so.
- Each page is previewed once a session (per profile): ⇧ over the same link again shows it at once. Previews are kept in
  memory only (up to 64) and go when Airc quits, when you turn link previews off, or when you **Clear Data** or delete
  the profile (Settings → Profiles); a preview still loading then stops and is never kept.
- A page has 10 seconds to load and the model 15 seconds to summarize it. At most two previews are made at once:
  sweeping ⇧ over many links works only on the last ones.
- Airc only reacts to your own ⇧ and mouse button: it checks that they're really down and the pointer is over the
  page, so a page can't make Airc load something by itself.

**Private windows never preview links**, and their links are never loaded in the background. Only http and https links
get previews.

## Tidy downloads

When a download with a name that says nothing ("IMG_2041 (1).pdf", "document.pdf", "scan0001.pdf", a long code)
finishes, Airc suggests a clean one, like "Lisbon itinerary.pdf", as with Arc Max's renamed downloads.

- **Library › Downloads** shows "✦ Rename to “Lisbon itinerary.pdf”" on its row with a **Rename** button (also in its
  right-click menu, with **Keep This Name**). Nothing is renamed until you click Rename.
- The file stays in its folder and keeps its type (its extension is never changed). If the name is taken, it gets a
  number ("Lisbon itinerary 2.pdf"). Names never hold `/`, `:` or other characters a disk can't take, never start with
  a dot, and are at most 60 characters.
- Open, Show in Finder and dragging the row use the new name. Airc remembers the rename in `TidyDownloads.json` in its
  data folder, because the engine only knows the old name; the file is never synced or sent. **Clear Data** and
  deleting the profile forget that profile's renames (the files keep their new names) and its suggestions.
- If a rename fails (the folder is read-only, the file was moved), the suggestion stays. Airc's log then says only that
  a rename failed, with the system's error number: never the file's name or folder.
- Files with clear names ("Invoice 8834.pdf") are left alone.

### Rename automatically

Arc's Tidy Downloads renames each download by itself. In Airc that's **Settings → AI → Downloads → Rename
automatically**, under Tidy downloads. It's off by default, and it can only be turned on with Tidy downloads on and Apple
Intelligence available (otherwise the row is greyed out and says why).

- When a download's suggestion arrives, the file takes the name at once, and the window shows **Renamed to
  “Lisbon itinerary.pdf”** with **Undo** for a few seconds. Undo puts the original name back ("Download name
  reverted"); if another file has taken that name meanwhile, it gets a number instead of replacing it.
- Library › Downloads shows the name a renamed file had ("was “IMG_2041 (1).pdf”"), and its right-click menu has
  **Revert to “IMG_2041 (1).pdf”**.
- Disk images, installers, apps and archives (`.dmg`, `.pkg`, `.app`, `.iso`, `.zip`, `.tar.gz`, `.7z`, `.rar` and the
  like) keep their names: an installer or a script may expect them, and an archive may be being opened. Their
  suggestion still shows in the Library, for a click.
- A file another app has open, or that changed in the last second, is left alone and tried again a few times; after
  that its suggestion stays for a click.
- Downloads from before you turned it on aren't renamed. Downloads in private windows never are.
- Unlike Arc, which names a file before it's saved, Airc renames it once it's finished, so the name the site gave
  appears for a moment first.

### What the model sees

The file's current name; the page it came from: its title (without counts or email addresses; from a tab of the
download's own profile, or that profile's history, never another profile's) and its address's host and path (never the
query); and the start of the file's own text: a PDF's first page or two (read with Apple's PDFKit on
your Mac), or a text file's first lines, at most 1,200 characters. Other files (images, archives, apps) are named from
the page alone. Files over 50 MB aren't opened.

Downloads in private windows are never looked at. The file's text is kept only until the model has answered; Airc
keeps no copy of it, nor of the requests it made.

## Tidy Tabs

Arc's broom: one click sorts a Space's Today tabs into folders by topic, named by the model on your Mac, and one ⌘Z
puts them back.

- Rest the pointer on the sidebar: **Tidy** shows in the Today header, left of **Clear** ("Organize Today Tabs"). It
  shows when Today has at least two different web pages. You can also type "tidy" in the Command Bar (⌘T) and choose
  **Tidy Tabs**; it tidies the Space on screen.
- Tabs about the same topic go into a folder with a short name ("Lisbon Trip", "Swift Concurrency"). A folder needs at
  least two different pages. A page that fits no topic stays in Today. Two tabs of the same page go into the same
  folder.
- **Nothing moves until you apply it.** The folders Tidy would make show first in a card at the top of Today, each
  with its number of tabs: **Apply** makes them, **Cancel** leaves Today as it is.
- **The folders go at the top of Today**, as in Arc ("Grouped 6 tabs into 2 folders", with **Undo**). The tabs in them
  are still Today tabs: each archives on its own after the Space's archive time, Clear clears them, and a folder goes
  when its last tab does. Drag a folder above the divider to pin it with its tabs. See
  [folders in Today](sidebar.md).
- Pinned tabs, folders that were already there (and the tabs in them), Favorites and split views are never moved,
  renamed or read. A tab you renamed keeps its name.
- While the model works, the label reads **Tidying…**. Click it (or choose **Stop Tidying Tabs** in the Command Bar) to
  stop: nothing changes. Nothing changes either until the model has answered for the whole list. Tabs you close, pin or
  move while it works are left where they are.
- **Undo** on the message, or **⌘Z** right after, puts every tab back where it was in Today and removes the folders, in one step. After you quit
  and open Airc again, ⌘Z still puts back that Space's last tidy (the tabs that are still in its folders), as long as
  nothing else is left to undo. You can also drag tabs out of the folders by hand, or right-click a folder and choose
  **Ungroup**.
- "No tab groups found" means the model saw no topic shared by two pages: nothing changed.
- **Tidy needs Apple Intelligence.** Without it, Tidy isn't offered: not in the Today header, the tidy card or the
  Command Bar. **Clear** and the tidy card's Archive and Pin still work.
- Long lists are sorted in parts of up to 24 pages (the model's context is small), at most 240 pages per tidy, and each
  part keeps the folder names the earlier parts made. The same tabs get the same folders: the model always picks its
  most likely answer.

### What the model sees

Each page's title (without counts like "(3)" or email addresses, at most 90 characters) and its site's name
("example.com"), numbered. Never its address's path or query, never a pinned tab, Favorite or folder, never another
Space's tabs, and never a private window's page: private windows have their own sidebar, with no Today header and no
Tidy. Airc keeps no copy of the request. What ⌘Z needs after a relaunch (which tabs went where) stays in Airc's data
folder on this Mac: it isn't synced or exported.

## Requires Apple Intelligence

The AI features need Apple Intelligence: macOS 26 or later on a Mac that supports it, with Apple Intelligence turned on
in **System Settings → Apple Intelligence & Siri** and its model downloaded. Without it, Settings → AI says what's
missing, the switches are greyed out and nothing changes: tabs show their pages' titles, ⌘F has no ✦, links get no
previews and downloads keep their names, and Tidy Tabs isn't offered. Airc still runs on macOS 14
and 15; the features just aren't there. No other model stands in on a Mac without Apple Intelligence: the owner decided
on 2026-11-09 that Airc's AI runs only on the model on your Mac.

## Usage data

Turning a feature on or off is counted once, as `feature.used` with `ai.tidy_titles`, `ai.ask_page`, `ai.link_preview`
or `ai.tidy_downloads` and `on` or `off`. Using one is counted as the same feature with `used`: a question asked, a
link preview shown (at most once a minute) or a suggested name applied ([telemetry.md](telemetry.md)). No title,
question, answer, page, address, summary or file name is ever part of an event, and nothing from a private window.
Tidy Tabs sends no usage event.

## ChatGPT in the Command Bar

Arc Max's ChatGPT in the Command Bar is in Airc as a web page, not as AI of Airc's: "gpt" + Tab in the Command Bar
opens your question on chatgpt.com (or Perplexity, or Claude) in a new tab, with no API key
([Ask ChatGPT](command-bar.md#ask-chatgpt)). It's off until you pick a site in **Settings → Site Search → Ask AI**, and
it doesn't need Apple Intelligence. Airc's own AI still uses only the model on your Mac.
