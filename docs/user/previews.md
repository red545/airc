# Tab previews and site previews

Rest the pointer on a tab in the sidebar and a card shows what's there, without leaving the page you're on.

## Tab previews

After a moment on a pinned tab, a Today tab or a Favorite, a card appears beside the sidebar. It shows a picture of
the page, its title and site, and buttons to pin or unpin it, add it to or remove it from Favorites, open it in Split
View next to the page you're on, or Peek at it.

- **The picture:** the page on screen is pictured as it is now. Other tabs show the picture taken the last time they
  were on screen, also after they were unloaded to save memory. A tab you haven't looked at since Airc started shows
  its icon instead.
- **What's kept:** pictures stay in memory only, at most 24 of them, and are gone when you quit. Each one belongs to
  its profile: deleting a profile, or clearing its browsing data, removes its pictures. Private windows have no tab
  previews, so their pages are never pictured.
- **Turning it off:** Settings → Appearance → "Show tab previews". This also forgets every picture.

## Site previews: Notion, Confluence, Figma and Linear

A pinned tab or Favorite of one of these sites shows its own card instead of a picture, as Arc's previews did:

- **Recents:** the pages you visited on that site in this profile, newest first, with how long ago ("Just now",
  "8 minutes ago"). Click one to open it in a new tab.
- **"+"** opens a new page there in a new tab: New Page for Notion and Confluence, New File for Figma, New Issue for
  Linear.
- Before you've visited any, the card says so ("Recent Notion docs appear here.").

The list comes from this profile's own history on your Mac. Nothing is fetched from the site to show it, nothing
is sent anywhere, and another profile's visits never appear. Clearing the profile's browsing data empties it.
Confluence lists the pages of the Atlassian site the tab is on.

## Mail and calendar previews (not yet)

Arc's previews of Gmail, Outlook, Google Calendar and Outlook Calendar showed unread mail and the day's meetings
with Join. These need Airc to connect to your account, which it can't do yet. Until then, those pinned tabs and
Favorites show the page's picture, and a calendar Favorite has [Live Calendar](calendar.md) from the calendars on
this Mac.

## Known differences from Arc

- Each page in a recents list shows the site's icon, not the page's own icon (a Notion page's emoji, for example).
- Arc let you turn each site's preview on or off. In Airc, "Show tab previews" turns all of them on or off together.
- Arc's GitHub preview isn't here: Arc retired it in 2024.
