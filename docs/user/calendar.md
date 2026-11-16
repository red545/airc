# Live Calendar

With a web calendar in your Favorites (Google Calendar, Outlook, Proton Calendar or Fastmail), Airc shows your next
meetings there, as Arc's Live Calendar did. Nothing leaves your Mac. Where the meetings come from:

- **Google Calendar or Outlook in your Favorites or pinned tabs:** the meetings are read from that calendar's own page,
  signed in, in its profile (see [Site previews](previews.md)). Only those: meetings in this Mac's Calendar app don't
  show, even at the same time, because they can be another calendar altogether. Open the calendar once after starting
  Airc; while its page isn't open, the meetings read last stay. A meeting's Join link (Meet, Zoom, Teams or Webex) is
  the one the calendar page shows for it. When the page shows a meeting without its call (Google puts Meet calls in the
  event, not on the grid), Airc reads the next meeting's own page in the background, out of sight and read-only, to
  find it; tracking parameters are left off.
- **Otherwise** (no web calendar, or only Proton Calendar or Fastmail, which Airc doesn't read): the calendars synced
  to this Mac (System Settings → Internet Accounts).

## Turning it on

Point at the calendar Favorite and choose Turn On, or use Settings → General → Calendar → "Show upcoming meetings".
macOS asks once for calendar access, unless your meetings come from a Google Calendar or Outlook page. It's off until
you turn it on.

## Which meetings count

As in Arc, Live Calendar leaves out meetings you declined, all-day events and out-of-office time. Meetings you said
"maybe" to, or haven't answered yet, count. Cancelled meetings never show.

## What it shows

- **Countdown:** from an hour before a meeting, the Favorite counts down ("in 5m"), then says "now".
- **Join under your Favorites:** before a meeting with a video call (Meet, Zoom, Teams, Webex or Around, the event's
  own video conference, or a web link in it), its title and a Join button appear under your Favorites until five minutes
  after it starts. ✕ dismisses it.
- **Preview:** resting the pointer on the calendar Favorite lists your next meetings under "Today", then "Tomorrow"
  when the next 24 hours reach into it. Meetings starting within ten minutes get a prominent Join. "+" opens your
  calendar's page for a new event, and clicking a meeting opens its day in the calendar Favorite. A Google Calendar or
  Outlook calendar Favorite shows that calendar's own day instead (read from its page, see
  [Site previews](previews.md)), never this Mac's calendars, and says "Open Google Calendar" while its page isn't
  loaded; this list is for calendar Favorites Airc doesn't read, such as Proton or Fastmail.
- **⌃⌘J** (Join Next Meeting, also in the Command Bar) joins the meeting that's about to start or is on now, else the
  next one with a call, any time. From a Space whose profile has no calendar Favorite, it goes to the calendar's Space,
  so the call opens signed in to that account. If the call is already open there, it shows that tab.

## Each Favorite's own settings

Right-click the calendar Favorite:

- **Show Time to Next Meeting**, **Show Next Meeting Link** and **Show Hover Preview** turn its countdown, its Join
  and its preview on or off for that Favorite.
- **Show Meeting Link** sets how early the Join appears: Ten, Five or Two Minutes Before (the default), or On Start.
  It's also in Settings → General → Calendar → Show Meeting Link.
- **Disable Live Calendar** turns the whole feature off.
