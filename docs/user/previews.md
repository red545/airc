# Tab previews and site previews

Rest the pointer on a tab in the sidebar and a card shows what's there, without leaving the page you're on.

## Tab previews

After a moment on a pinned tab, a Today tab or a Favorite, a card appears beside the sidebar. It shows a picture of
the page, its title and site, and buttons to pin or unpin it, add it to or remove it from Favorites, open it in Split
View next to the page you're on, or Peek at it.

- **The picture:** the page on screen is pictured as it is now. Other tabs show the picture taken the last time they
  were on screen, also after they were unloaded to save memory. A tab you haven't looked at since Airc started shows
  its icon instead.
- **How old it is:** a picture that may be out of date says so in a small label on it. A tab that isn't loaded says
  "Not loaded · pictured 12 min ago"; a loaded tab's picture says "Pictured 5 min ago" once it's a minute old.
- **What's kept:** pictures stay in memory only, at most 24 of them (about 24 MB), and are gone when you quit. With
  more tabs than that, the ones you looked at longest ago lose their picture first. Each one belongs to its profile:
  deleting a profile, or clearing its browsing data, removes its pictures. Private windows have no tab previews, so
  their pages are never pictured.
- **Turning it off for one tab:** right-click a pinned tab or a Favorite and uncheck **Show Hover Preview**, as in
  Arc. That row gets no card (no picture and no site preview); the others keep theirs. A calendar Favorite with Live
  Calendar on has the same switch among its calendar options.
- **Turning it off everywhere:** Settings → Appearance → "Show tab previews". This also forgets every picture.
- **Keyboard and VoiceOver:** the card follows the pointer only, as in Arc, so moving through the sidebar with the
  keyboard (⌃Space) shows none. The same actions are in the row's menu, which VoiceOver opens with VO-Shift-M. While
  a card is up, VoiceOver reads it as "Preview of" the page, with the picture's age, and can press each button.

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

## Mail previews: Gmail and Outlook

A pinned tab or Favorite of Gmail or Outlook shows your **unread mail**: the sender, the subject and the start of the
message, newest first, with how long ago it came. The row under it counts them ("3 Recent", "Several Recent").

- **Click a message** and it opens in Peek over the page you're on, in the same profile (Arc's Peek Email). Open it
  as a tab from Peek, or close Peek to go back. If no page from that account's profile is in front, the message opens
  in the mail tab itself instead.
- **"+"** writes a new message in the same account.
- **Where it comes from:** like Arc, Airc reads it from the site's own page, already signed in, in that profile.
  Gmail's page is asked for its inbox feed (the unread messages Gmail gives a signed-in page); if that gives nothing,
  Airc reads the inbox list on the page. Outlook's message list is read on the page. Airc has no account of its own,
  asks for no sign-in or password, and sends nothing anywhere. Reading changes nothing: no message is marked read.
- **Freshness:** while the page is loaded (pinned mail tabs stay loaded), the list is read again about once a minute,
  so the card is ready before you rest on it. Before the page has been opened since Airc started, the card says
  "Open Gmail to see your unread messages here", with a button that opens it.
- **Signed out:** the card says so; Sign In opens the site in its tab.
- **Accounts and profiles:** each Gmail account (`/u/0/`, `/u/1/`) and each profile has its own card. An account
  you haven't opened in a profile is never read. Private windows are never read, and visits there open nothing.
- **Turning one off:** Settings → Appearance → Site Previews has a switch for each site. Off, that site shows the
  page's picture, its row has no count, and nothing of it is read.

### Peek Email on a sign-in page

On a page that just emailed you a sign-in code or link, Tabs → Peek Email… (also in the Command Bar) puts the code from the site's newest
email into the field you're in, or opens the link in Peek. It uses the same mail previews.

## Calendar previews: Google Calendar and Outlook

A pinned tab or Favorite of Google Calendar (calendar.google.com) or Outlook's calendar (outlook.live.com/calendar,
outlook.office.com/calendar) shows **your day as an hour grid**, as Arc's calendar preview did. It shows six hours
starting a quarter of an hour before now, with a line at the current time, without scrolling: the card is a little
taller than the mail card, and the hours fit the room left by the Join button, the all-day events and tomorrow. Each
meeting is a block at its time, with its title, time and call. Meetings that overlap sit side by side. Scroll the grid
to see the rest of today, or past midnight late in the evening. Today's all-day events sit in one line above the hours
(two, then "+1" for the others), and **tomorrow's** first event sits in one line under the grid, with "+2" for the
others. The row under the card's item says what's next ("Event in 9m", "Event at 3:00 PM").

- **Click an event** (a block, an all-day event or tomorrow's) and it opens in the calendar's own tab:
  Google Calendar's page for that event, Outlook's event.
- **Join:** a big Join button above the grid for a meeting with a Meet, Zoom, Teams, Webex or Around link that starts
  within ten minutes or is on now. **"+"** opens a new event in the same account.
- **Ended events** of today stay in the grid, dimmed, above the current time; declined events aren't shown.
- **Light and dark:** the card follows the window's theme. With VoiceOver, each event reads its title, time and call,
  and the grid is labelled "Today". The grid opens already scrolled, without animation.
- **Where it comes from:** like the mail previews, Airc reads the calendar's own page, already signed in, in that
  profile. It reads only what the page shows (its events and their screen-reader text); it asks the calendar for
  nothing, has no account of its own, asks for no sign-in and sends nothing anywhere. Declined events are left out.
- **Days the page doesn't show:** if the page is on its day view, today is read again and tomorrow keeps what was read
  before. Pinned calendar tabs stay loaded, so the card is ready before you rest on it.
- **Before the page is opened** since Airc started, the card says "Open Google Calendar to see your events here",
  over the tab's last picture when there is one, with a button that opens it.
- **Signed out:** when the calendar's tab is on its sign-in page, the card says so; Open loads the calendar in its tab.
- **Accounts, profiles and private windows** work as for mail: each account and profile has its own card, an account
  you haven't opened in a profile is never read, and private windows are never read.
- **Turning one off:** Settings → Appearance → Site Previews, "Google Calendar" or "Outlook Calendar".
- **Favorites too:** a Google Calendar or Outlook calendar Favorite shows the same card, its page's day, even with
  Live Calendar on: never the meetings from this Mac's calendars, which may be another calendar altogether. The events
  read from its page are also Live Calendar's countdown, Join and ⌃⌘J, alone: this Mac's calendars don't join them
  ([Live Calendar](calendar.md)).

## Known differences from Arc

- Each page in a recents list shows the site's icon, not the page's own icon (a Notion page's emoji, for example).
- Outlook's list is read from the page's markup, which Microsoft changes from time to time; if Outlook's card stays
  empty while you have unread mail, it's a bug to report.
- Gmail's card lists at most the 20 newest unread messages in the inbox (what Gmail's feed gives).
- Arc's calendar preview signed in to Google and Microsoft. Airc's reads the calendar page instead (no sign-in), so it
  knows only the days the page has shown. Arc's grid showed only the six hours from a quarter hour before now and had
  nothing for tomorrow; Airc's grid shows the same six hours, scrolls over the whole day and adds a line for tomorrow
  under it. Events are read
  from the page's English text (times like "10am to 11am", dates like "November 14, 2026"); in another language, or
  where Google or Microsoft change their markup, the card may stay empty: please report it.
- An event spanning several days with times (not all-day) isn't listed.
- Arc's GitHub preview isn't here: Arc retired it in 2024.
