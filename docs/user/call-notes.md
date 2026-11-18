# Call notes with Granola

Granola starts notes by itself for calls in browsers it knows, and Airc isn't on its list yet. Until it is, Airc can
start Granola for you.

Turn it on in **Settings › General › Calendar › Start Granola notes when a call starts**. The switch is off until
you turn it on, and it only appears when Granola is installed on your Mac.

## What happens

- When a tab on a call site (Google Meet, Zoom on the web, Microsoft Teams, Webex, Whereby, Jitsi Meet, Gather or
  Around) starts using your microphone, Airc asks Granola to start a new note. Granola starts recording into it, as
  it does when you click its own "New note".
- Once per call. A second tab of the same call, muting, or leaving and rejoining within five minutes don't start
  another note. A different meeting does. (A site that turns the microphone off while you're muted for longer than
  five minutes may start a second note when you unmute.)
- Never in private windows.
- Granola comes to the front when it starts the note. That's Granola's own behaviour, and Airc can't keep it in
  the background.
- **Stopping is up to Granola.** It stops by itself when the call's audio ends, or when you stop it. Airc never stops
  a note, and it doesn't send Granola the call's title, the page's address or anything else about the call.

## Good to know

- Airc uses a link Granola registers (`granola://new-document`) that Granola doesn't document. A Granola update
  could change or remove it. If notes stop starting, turn the switch off and start notes from Granola's menu bar
  icon, and tell us via Help › Send Feedback.
- You need to be signed in to Granola. If Granola is already recording another note, it may start a new one.
- Granola's calendar reminders keep working as before; they don't depend on the browser.
- Once Granola adds Airc to its own list, its detection works without this switch; turn the switch off then, so
  you don't get two notes.
