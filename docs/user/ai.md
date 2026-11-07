# AI in Airc

Airc's AI features run on your Mac with Apple Intelligence (Apple's on-device Foundation Models). There's no account,
no API key and no cloud service: nothing about your tabs leaves your Mac. They are off until you turn them on in
**Settings → AI**.

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

## Requires Apple Intelligence

The AI features need Apple Intelligence: macOS 26 or later on a Mac that supports it, with Apple Intelligence turned on
in **System Settings → Apple Intelligence & Siri** and its model downloaded. Without it, Settings → AI says what's
missing, the switches are greyed out and every tab shows its page's own title. Airc still runs on macOS 14 and 15; the
features just aren't there.

## Usage data

Turning Tidy tab titles on or off is counted once, as `feature.used` with `ai.tidy_titles` and `on` or `off`
([telemetry.md](telemetry.md)). No title, address or name is ever part of an event.

## Coming later

Arc Max's 5-second link previews and Ask on Page aren't in Airc yet.
