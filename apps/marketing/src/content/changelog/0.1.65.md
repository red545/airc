# Airc 0.1.65 public beta

Airc is an Arc-style browser with a native macOS interface on Chromium 156.0.8078.109.
This update lets Airc Agent tasks in the background rest when nothing needs them, so they barely use any power, and
makes finished tasks' cards show their page. It includes everything from 0.1.64. The release manifest records the
exact build, source and checksums.

- **Mac:** Apple silicon only, macOS 14 or later. Tested on macOS 26.
- **Installing:** open the signed, notarized DMG and drag Airc to Applications.
- **Updates:** Stable checks automatically. Choose Nightly in Settings → General to try newer builds.
  Switching back never downgrades your data.

## New since 0.1.64

- **Background agent tasks barely use any power now.** When an Airc Agent task works in a tab you're not looking at
  (or one you started with ⌥↩), its page now rests whenever the agent hasn't needed it for 5 seconds, and wakes the
  moment the agent acts. With three such tasks, their pages went from about a fifth of a processor core (Safari
  engine) or two-fifths (Chromium) to almost nothing. Tasks run just as fast.
- **Finished tasks' cards show the top of the page.** In the Command Bar's Ask, the Recent tasks cards now show the
  top of the last page a task saw, and keep a good picture of it. Before, a short page could show up as an empty
  card.
- **Links from other apps open a little sooner with Chromium.** When you click a link in another app and Airc has to
  start, Airc now gets ad blocking ready before anything else, so the page shows a little sooner.

## Included from 0.1.64

- **The Airc Agent can now work on several tasks at once.** Start another task while one works (✎ New in the pane, or
  Ask in ⌘T): each runs in its own tab, with its own row in the Agents folder, its own approvals and its own Stop.
  Stopping one leaves the others running. Up to 3 run at the same time; more wait as Queued and start by themselves
  when one ends. You can change the limit in Settings › AI › Agent.
- **Start a task in the background with ⌥↩.** In the Command Bar's Ask, press ⌥↩ instead of ↩. The task starts in its
  own tab, which shows up as a row in Today, and your page stays where it is.
- **A busy AI service no longer ends a task.** When your AI provider says it's busy or you've hit its rate limit, the
  task waits, says how long, and tries again by itself. Stop still ends it at once.
- **Capture Full Page gets the whole page, however long.** On both engines, Capture Full Page (F in Capture, or View
  › Capture Full Page) now takes very long pages from top to foot. Parts that stay put while you scroll, like a
  site's header, show once, where the window shows them. With Chromium, very long pages no longer come out washed out
  or with thin lines across them.
- **Switching tabs is quicker with the Safari engine.** Picking a tab no longer redraws the whole sidebar before the
  tab shows, so with the Safari engine (WebKit) the new tab appears about a quarter sooner.
- **Settings say how to quote with Shared Quotes off.** Settings › General › Shared Quotes now says that with Shared
  Quotes off, ⌃⇧⌘C (Copy URL as Quote) still copies the page's link with your selection as a quote, as in Arc.
- **Fix: after you go to an agent task that needs you, your typing stays there.** Before, when you got there twice in
  a row (say, from the Dock and then ✦), the first one could take the keys back a moment later.

## Included from 0.1.63

- **iCloud sync now works without iCloud Keychain.** On a Mac that syncs, Settings › Sync › Recovery key › Show…
  shows a recovery key after you enter your Mac's password or use Touch ID. On a Mac where iCloud Keychain is off, or
  whose key got lost, choose Use Recovery Key… and type it in. Keep the key somewhere safe, like a password manager.
- **If no Mac has the sync key any more, you can start over.** Start Over… in Settings › Sync backs up this Mac's
  sidebar first, then starts sync again from it. Nothing in iCloud is deleted. Your other Macs keep their sidebars:
  once they have the new key, they offer to merge, and nothing shows up twice.

## Included from 0.1.62

- **A new agent task no longer starts on a blank white page.** Until the Airc Agent opens its first page, its tab
  shows “Starting…”, and the tab is named after your task instead of “about:blank”.
- **Turning on iCloud sync always backs up this Mac first.** Before the first sync merges anything, Airc backs up
  this Mac's sidebar. If the backup folder you chose is gone (say, on a drive that isn't plugged in), the backup goes
  to the default folder, as every other backup already did. If Airc can't save a backup at all, nothing is merged or
  sent, and the first-sync screen tells you why.
- **Ask in the Command Bar says where the agent works.** Ask mode and the device chip now say the Airc Agent works in
  a tab of this window, not in a window of its own.

## Included from 0.1.61

- **The Airc Agent now works right in your window.** When you give it a task, its page opens as a tab in Today, with
  a soft glow in your Space's colour and a bar on top with **Take over** and **Stop**. While it works, your clicks
  and typing on that page wait; scrolling to look is fine. Switch tabs whenever you like: the agent keeps going, and
  the agent pane shows a live picture of its page until you come back. A task you start in one window stays in that
  window.
- **⌘T over a full-screen video now leaves full screen on Chromium pages too.** The Command Bar opens in your window,
  as it already did on Safari-engine pages. And switching tabs or Spaces away from a Safari-engine page in full
  screen no longer leaves it stuck there.
- **Quitting no longer waits on an empty Apple ID sheet.** On Safari-engine pages, Apple's Apple ID sign-in extension
  could leave an empty sheet on the window, and quitting Airc then took about 16 seconds. Airc now leaves that
  extension out, so Apple ID pages show their own sign-in form, and Airc quits right away.
- **Backups still happen when your chosen backup folder is missing.** If the folder you chose in Settings › General
  is gone (say, on a drive that isn't plugged in) or can't be written, Airc saves the backup to its default folder
  instead and keeps your choice for next time.

## Included from 0.1.60

- **Typing after ⌘T over a full-screen video no longer pauses or controls the video; the Command Bar takes the keys.**
  Keys you type while the Command Bar opens no longer reach the page behind it, so a video doesn't pause or pop out.
  On a Safari-engine page in full screen, ⌘T now leaves full screen first.
- **Tab switches between Search and Ask in the Command Bar again.** Tab and ⇧Tab switch with your text kept, and a
  "Tab to switch" hint shows wherever it works. After a site shortcut such as "yt" or "gpt", Tab still searches that
  site, as in Arc.
- **Grain on dark Spaces now looks like Arc's.** A Space's grain texture now darkens its colour as lightly as Arc's
  does, in light and dark Spaces; on dark Spaces it used to brighten them instead.

## Included from 0.1.59

- **Sign-in buttons always respond.** A first click on a page in Little Airc while Airc is in the background now reaches the
  page, instead of only bringing Airc forward. Where Airc blocks a pop-up and its address-field icon can't be seen (Little
  Airc, private windows, Peek, a hidden sidebar), a "Pop-up blocked" note with an Open button says so. Sign In in
  Settings › Profiles and in onboarding now always opens a window or says what went wrong.
- **Each agent task shows once in the sidebar.** A task you give Airc Agent has one row, instead of a second row
  for the page it works on; agents in other apps get one row per session.
- **Scrolling the sidebar no longer leaves tabs highlighted.** When the list scrolls under a resting pointer, only
  the tab under the pointer shows its highlight and close button.

## Included from 0.1.58

- **Airc Agent no longer stops after 25 steps; it keeps going until the task is done or you stop it.** Approvals, Stop and
  Take over work as before. If you want a limit, choose one under **Stop after** in Settings › AI › Agent (25, 50, 100
  or 200 steps); it is off by default. When a task stops or fails, one note under its last step says why, and long
  tasks shorten their older screenshots and tool answers so they keep fitting the model's context.

## Included from 0.1.57

- **Spaces imported from Arc keep their sand, denim or tweed texture, and you can pick them yourself.** Click the
  Space's name in the sidebar, choose **Theme…**, and use the swatches beside the grain dial: Grain, Sand, Denim and
  Tweed. Turn the dial to set how strongly the texture shows. Each draws at Arc's own strength, in light and dark
  Spaces.
- **Switching Spaces is smoother.** A Space switch now skips fewer frames: the sidebar no longer redraws its hidden parts on
  every switch, and it updates after the new Space is on screen instead of holding it up.
- **Watch keeps showing what the agent is doing, even after you stop and continue it.** Continue starts the agent in a new
  window, and Watch used to stay blank on the stopped run; it now follows the agent to the page it is working on. On
  the WebKit engine, Watch and the agent's card no longer freeze on an old picture after a stop.

## Included from 0.1.56

- **In full screen on a MacBook with a notch, nothing of Airc hides behind the notch any more.** The sidebar
  with its address field and ✦ button, the Library and the page now start just below the camera, where they could sit
  behind it before. On Macs without a notch nothing changes.
- **Watch shows what an agent is doing live, and asks you when its page wants a passkey.** Watch no longer stays
  blank or shows an old picture for an agent using Airc: the page stays live as the agent moves between sites, goes
  back, or while Airc is in the background. When an agent's page asks for a passkey, Airc tells you which agent and
  site want it and asks in Watch, over the page; if Watch isn't open, the agent's row says Needs you and opens Watch
  with the question.

## Included from 0.1.55

- **Signing in to desktop apps through Airc works now.** When a website wants to open an app, as an app's sign-in
  does when it hands back to the app through its own link, Airc now asks "Open “App”?" first, like Chrome. On a secure
  site, **Always allow** remembers your choice for that site in this profile. Before, nothing happened and the app
  never heard back. It also works when Airc wasn't open yet.

## Included from 0.1.54

- **Point at Clear to see exactly which tabs it will archive.** With the pointer on **Clear** in
  the Today header, the tabs it would move to the Archive light up, and so do the Today folders it would leave empty.
  When the tab on screen is the only Today tab, Clear now archives it too, and a small ↓ before Clear warns of that,
  as in Arc. **Undo** in the message, or ⌘Z, brings it back.
- **The tidy card now appears as soon as Today gets long.** The card that offers to tidy Today
  used to show up only after the sidebar redrew once more; it now shows with the tab that makes Today overflow.
- **Fixes: sidebar menus follow a dark Space, and note pictures are kept for backups in a folder you chose.** In a
  dark Space while Airc itself is light, the sidebar's right-click menus, pop-ups and scroll bars were light; they now
  follow the Space. With a backup folder chosen in Settings › General (Back up to), Airc could delete note pictures
  that only those backups used, so restoring one showed "Picture not on this Mac". They are kept now.

## Included from 0.1.53

- **Fix: the live page in the agent pane no longer flashes blank when the agent opens a new page.** On the
  Chromium engine, the agent pane's live picture of the page could show one blank frame each time the agent went to a
  new page. It now keeps showing the last frame until the new page is ready.

## Included from 0.1.52

- **Fix: closing windows on the Chromium engine no longer leaves their memory behind in some cases.** A window
  that Airc closed itself, rather than through your close (⌘⇧W, the close button or Close Window), kept its pages and
  views in memory until you quit Airc. They are now freed when the window closes.

## Included from 0.1.51

- **Today tabs can now stay until you close them: auto-archive can be set to Never, or to 1 or 6 hours.** In
  **Settings › Profiles** (Archive Today tabs after) or the tidy card's **Archive after**, choose **Never** to keep
  Today tabs until you close or clear them, or a shorter time. **Clear** still works, with Undo. If you sync with a
  Mac still on Airc 0.1.49 or older, update it first: it resets Never to 12 hours on all your Macs.

## Included from 0.1.50

- **When Airc Agent asks for your OK, a Return you type in a web page can no longer approve it by mistake.** Right
  after an agent's request appeared, Return pressed in a page's text field could allow the agent's action. Now only
  a Return or click on the request itself allows it.
- **"Needs you" from a task you started with Ask now opens the right window and Space.** For a task started from
  ⌘T's **Ask** or from a task's reply box, the request could open in another window or Space, even another profile's.
  It now opens where you started the task.
- **Fixes: a small memory leak when closing windows, and a wrong "couldn't play here" message on some video sites.**
  Closing a window could leave its Share Quote button running. With FairPlay on in a Chromium tab, Netflix or
  Disney+ could show "couldn't play here" while you were only browsing.
- **Airc reads newer auto-archive settings safely.** If a newer Airc on another Mac syncs an auto-archive time this
  version doesn't offer yet, Airc keeps your setting working instead of failing to read it.

## Included from 0.1.49

- **Ask Airc Agent about something you read earlier or a tab you have open.** In the agent pane (⌥⌘A or ✦), ask
  about a page you saw, such as "the hotel page I looked at yesterday": Airc Agent can now search your history, your
  open and pinned tabs and your Favorites to find it, and the task shows what it searched, with results you can click.
  It searches only the profile you're in, and never in a private window.
- **Finished agent tasks keep their pictures after you restart Airc.** The page pictures in a task's steps used to
  disappear when you quit Airc; now they are still there when you reopen the task.
- **⌘Z after a Clear undoes the whole Clear in one step, and no longer reopens a Peek by mistake.** In a long
  session, ⌘Z (or the toast's **Undo**) could reopen a Peek you had just closed instead of undoing your Clear, Tidy or
  Archive, and a Clear that waited for a "Leave site?" page took several ⌘Z to put back.

## Included from 0.1.48

- **When Today gets long, Airc offers once a day to tidy it.** A card at the top of Today offers, in one click, to
  archive the tabs you haven't looked at for hours, to pin your most-used site to Favorites, or to choose when Today's
  tabs archive themselves. Each choice can be undone, and **Not now** puts the card away until tomorrow. With Apple
  Intelligence, the card also offers **Tidy** into folders.
- **Tidy shows its folders before it moves anything, and Tidy and Clear can both be undone.** With Apple Intelligence,
  Tidy (in the card, the Today header or the Command Bar) first shows the folders it would make, with **Apply** and
  **Cancel**. **Clear** now says how many tabs it moved to the Archive. After either, **Undo** (or ⌘Z) puts every tab
  back where it was.

## Included from 0.1.47

- **The ✦ button now sits in the toolbar.** The Airc Agent button moved to the top of the sidebar, next to Back
  and Forward, so the agent is one click away (or press ⌥⌘A). In a narrow sidebar, ✦ is the last button to give way.
- **Share Quote appears inside the address bar.** Select text on a page and **Share Quote** slides in at the right
  end of the address bar. It no longer pushes the sidebar around: nothing below the address bar moves.
- **The Feedback button stays visible however many Spaces you have.** As in Arc, the Space icons at the bottom of
  the sidebar get narrower instead (the others turn into dots when room is short).
- **Little Airc windows come back properly from Stage Manager and the Dock.** A Little Airc that opened over a
  full-screen app now comes to the front when you choose it in Stage Manager, Mission Control or the Dock, and Little
  Airc windows are listed in the Window menu.
- **When an agent needs you, one click takes you there.** Click its notification, its row in the Agents folder, ✦
  or the Dock icon, and Airc brings up the right window with the agent's question (**Allow once** is the default)
  or the page that needs you, such as a sign-in. The live page in the agent pane no longer flickers while the agent
  works.
- **Fewer sites blocked by mistake.** Sites you open yourself are no longer blocked by Airc's tracker lists unless
  a rule names the page itself. This fixes sentry.io and similar sites that showed "blocked by Airc" because a list
  names them as trackers; trackers inside pages stay blocked, in both engines.

## Included from 0.1.46

- **Airc Agent tasks get their own view.** Open a task from the sidebar, a Recent tasks card or the Command Bar and
  it fills the page: every step on a timeline with what it found, the answer as it's written, and the page the agent
  is working on, live, beside the steps (click it to watch, or **Take over**). Reply below to keep going, or choose
  **Deny** or **Allow once** when it asks first. The **Agents** folder in the sidebar lists your tasks, with a spinner
  while one works, ✋ while it waits for you and a blue dot when it has finished; **Show all** opens every task.
  The agent pane (⌥⌘A or ✦) stays the compact form of the same task.
- **⌘T can Ask as well as Search.** Press ⌘T, type what you want done and press **Tab** (or click **Ask**). Chips
  under the field show what the task gets and who runs it: use your ChatGPT subscription through Codex, your own Claude
  Code, or an API key. **Recent tasks** shows this Space's newest tasks as cards, and **Return** starts the task in its
  own tab. Tab still does what it did before wherever it has another job, such as a site's search or a completion.

## Included from 0.1.45

- **Spotify opens in Airc's Safari engine, where it plays.** Spotify's web player plays only through Safari's own
  protected-media support, so with the FairPlay setting on it couldn't play in a Chromium tab and Airc offered nothing. Spotify now always opens in
  Airc's Safari engine (WebKit), whatever the protected-media setting says. Netflix and Disney+ still play in a
  Chromium tab when **Settings › Privacy › Protected content › Play protected media in Chromium with FairPlay** is on, and if a site can't
  play there, Airc offers **Open in Safari's engine**.
- **The Command Bar answers your first keystroke sooner.** Airc now prepares the Command Bar's icons, commands and
  text field while you're idle, so the first letter you type after ⌘T shows sooner: in our tests on the build Mac
  about 6 ms instead of about 10 ms with Chromium, and about 5 ms instead of 8 ms with WebKit.

## Included from 0.1.44

- **A faster Chromium engine.** Airc's Chromium engine is now built the way Chrome is: optimised from profiles of how
  it really runs, and across the whole program when it is linked. In our tests on the build Mac, a Chromium window became usable
  about a quarter sooner after launch, a busy animated page used nearly a quarter less CPU, and the
  engine is about 200 MB smaller, so Airc takes less space on your Mac. Your tabs, sign-ins and settings stay as they are.
- **Sites you type in are no longer blocked by mistake.** In Chromium tabs, some sites you open yourself, by typing
  the address or from a bookmark, showed "blocked by Airc" because a tracker list names them, such as
  analytics.google.com (about 5,400 sites in the default lists). Airc now opens the site you asked for, and
  trackers inside pages stay blocked as before.
- **Google Tag Assistant and Tag Manager preview work with Airc's content blocking on.** On Google's own tag tools
  (Tag Assistant, Tag Manager and Analytics), Airc now lets Google's tag and analytics scripts through, so preview and
  debug mode connect to your site. Everywhere else they stay blocked as before.

## Included from 0.1.43

- **Use your ChatGPT subscription in Airc Agent.** The pane's **Connect your AI** card (the ✦ button or **⌥⌘A**) now
  starts with **Use your ChatGPT subscription**: connect your own Codex with **Sign in with ChatGPT**, on ChatGPT's own
  sign-in page. You can also use your own Claude Code (it uses your Claude account) or an Anthropic or OpenAI API key.
  Airc never sees your sign-in.
- **Netflix and Disney+ play in a Chromium tab with FairPlay.** Turn on **Settings › Privacy › Protected content › Play
  protected media in Chromium with FairPlay** (off by default, the same setting as Spotify). Netflix and Disney+ then
  stay in a Chromium tab, with your extensions, and their video plays with Apple's FairPlay, with picture in picture
  and the sidebar's media controls. If a title can't play, Airc offers to open the page with Safari's engine. With the
  setting off, nothing changes.

## Included from 0.1.42

- **New ✦ button opens Airc Agent.** It's at the bottom of the sidebar, next to the Archive button, or press **⌥⌘A**.
  Click it again to close the pane; while a task runs, the button shows a dot. Right-click it for **New Task**,
  **Watch** or **Settings › Agents**. New users see a short hint over the button once.
- **Connect your AI right in the pane, with no trip to Settings.** If nothing is connected yet, the pane shows
  **Connect your AI**: your own Claude Code, your own Codex sign-in, or an Anthropic or OpenAI API key. A key is kept in your Mac's Keychain and sent only to that provider. The task you typed
  before connecting goes on by itself once you're connected.
- **Play Spotify in a Chromium tab with FairPlay.** Turn on **Settings › Privacy › Protected content › Play protected
  media in Chromium with FairPlay** (off by default). Spotify then stays in a Chromium page, with your extensions,
  and plays with Apple's FairPlay; the sidebar's media controls, Now Playing and the keyboard's media keys follow it. If
  a track can't play, Airc offers to open the page with Safari's engine. With the setting off, nothing changes.

## Included from 0.1.41

- **New profiles get a short setup: pick the Space's colour, sign in, done.** After **Create Profile** (from a Space's
  **Set Profile › New Profile…** or **Settings › Profiles**), the same card asks for a colour for the Space you ticked,
  and the window shows each colour as you pick it (**Skip** or Esc keeps the old one). Then **Sign in to Google** opens
  Google's sign-in page in the new profile (**Another site…** opens a new tab for any other account). Once you're
  signed in, the card shows your account's picture and name and closes by itself.
- **Your account's picture and name show up right away, including after signing in from the sidebar.** Signing in
  from a new profile's **Sign in to Google** card in the sidebar (or during the setup above, or the first-run setup)
  now puts the account's picture beside the Space name, in **Set Profile ›** menus and Manage Spaces, and in
  **Settings › Profiles** ("Signed in as …") without a relaunch. Resting on a Space's icon at the bottom of the
  sidebar names its profile and account.
- **When Claude uses Airc, its notice no longer covers the window's close and minimize buttons.** While an AI app
  such as Claude works in Airc, the sidebar shows **✦ Claude is using Airc** (with the app's name) in a row just under
  the window's buttons, never over them. Click it to see what it means, **Watch** what the app is doing, or **Stop**
  it.

## Included from 0.1.40

- **Your saved passwords and cookies are safe if macOS can't unlock the keychain.** When the keychain is locked, you
  denied access, or the key there doesn't match the one your data was saved with, Airc now asks you to **Try Again**
  instead of starting over: you can also continue without saved passwords for now, or quit. Nothing is deleted, and
  no new key replaces yours, so once the keychain opens again your logins and cookies are all there. (Before, a key
  that couldn't be read could be replaced and the saved cookies signed out.)
- **Every window can be closed.** With the sidebar hidden, move the pointer to the window's top-left corner and the
  window buttons appear there; they also show in the sidebar when it slides out. **⌘W** on a window's last tab closes
  the window, as in Arc (your last window stays open with its empty page). Windows you made by dragging a tab out
  close the same way.
- **Typing in the Command Bar is quicker.** Each keystroke no longer checks files on disk for every row's icon, and
  the first keystroke after opening the Command Bar no longer waits for its symbols and text system to load.

## Included from 0.1.39

- **Developer Tools dock inside the window you're inspecting.** Press **⌥⌘I** (**⌥⌘J** for the Console, **⌥⌘C** to
  pick an element) and DevTools open next to the page in the same window, at the bottom or the side like Chrome:
  **⇧⌘D** switches the side, you can drag the divider, and you can undock them into their own window and back. Every
  panel works, including the **»** list of more panels and right-click menus. With Safari's engine, Web Inspector
  stays with its tab: it hides when you switch tabs and comes back with the tab.
- **The agent pane can set up your own Claude Code or Codex.** If one isn't installed, **Install…** shows the install
  command from its own documentation, with Copy and Open in Terminal (the command runs only after you press Return).
  **Sign in…** starts that tool's own sign-in, and the task you typed goes on by itself once you're signed in; Airc
  never sees a password or token. **Hand back** now gives the agent the same tab, with what you typed, the scroll
  position and the tab's history kept.
- **The agent pane uses far less power while it's thinking.** The moving "Thinking…" text now animates on Core
  Animation instead of redrawing the window every frame, so the pane's CPU use while the agent works drops from about
  16% of a core to under 1%.

## Included from 0.1.38

- **The Stop button in the agent pane shows in dark Spaces.** While the Airc Agent works, the round Stop button next
  to the message field used to be a white square on a white circle in a dark Space; the square now always contrasts
  with its circle.

## Included from 0.1.37

- **The Airc Agent opens beside the page.** Press **⌥⌘A**, or type a task in the Command Bar and pick **Ask Airc
  to…**, and the agent's pane opens next to the page you're on instead of a floating panel (drag its edge to make it
  wider; **⇧⌥⌘A** starts a new task). While the agent works, the pane shows the page it's on, live, above the
  conversation: click it to Watch, or **Take over** to use the page yourself. Each step is one line with the site's
  icon, and when it's done the steps fold into "Done in …". It runs on your own Claude Code or Codex, or your own
  Anthropic or OpenAI API key. Hand to Claude Desktop and Hand to Claude Code were part of the old panel and are gone;
  to have those apps drive Airc, set up the connector in Settings › Agents. Details: `docs/user/agents.md`.
- **Watch any working agent from the sidebar.** Hover over a working task in the Agents folder and click the eye to
  watch its page live, even one running in the background.
- **Search in Settings.** Type in the field at the top of the Settings sidebar, or press **⌘F** in Settings: it finds
  panes, settings and their descriptions, and common words for them ("dark", "password", "adblock"). Pick a result
  and Settings opens that pane, scrolls to the setting and highlights it.
- **Settings stays put.** Switching panes no longer moves the layout; Appearance used to shift a little to the left.

## Included from 0.1.36

- **Security update: Airc's Chromium engine is now 156.0.8078.109.** It has Chrome's latest security fixes, from
  Chrome's Extended Stable updates 156.0.8078.96, 156.0.8078.100 and 156.0.8078.109: 83 security issues in Chrome's
  posts for .96 and .100, 4 of them critical, plus whatever .109 fixes (Chrome hasn't posted its list yet). Details:
  [156.0.8078.96](https://chromereleases.googleblog.com/2026/11/extended-stable-update-for-desktop_0910980127.html),
  [156.0.8078.100](https://chromereleases.googleblog.com/2026/11/extended-stable-update-for-desktop_01570615041.html).
  Nothing to do: the update installs it.
- **Granola starts notes for your calls.** Granola starts notes by itself only in browsers on its own list, and Airc
  isn't on it yet. Turn on **Start Granola notes when a call starts** in Settings › General › Calendar, and when a
  Meet, Zoom, Teams, Webex or Whereby tab turns on your microphone, Airc asks Granola to start a note, once per call
  and never in private windows. The switch is off by default and only appears when Granola is installed. Airc sends
  Granola nothing about the call. Details: `docs/user/call-notes.md`.

## Included from 0.1.35

- **Your password manager fills logins on its own.** Turn off **Offer to save and fill passwords** for a profile in
  Settings › Passwords, and Airc no longer fills in a site's saved login when the page loads either, so your password
  manager's extension, such as 1Password or Proton Pass, fills it instead. With the switch on, Airc fills as before.

## Included from 0.1.34

- **Import from Dia.** Choose Dia on the first launch or in Airc › Import from Another Browser… to bring over its
  profiles, bookmarks, history, search engines and extensions (as a checklist to reinstall). With the Chromium engine,
  choose Import logins and allow macOS to use the "Dia Safe Storage" key once, and your saved passwords, cookies and
  sites' data come over too. Dia's sidebar (its pinned and open tabs) can't come over: Dia keeps it encrypted where only
  Dia can read it. Details: `docs/user/import-from-dia.md`.
- **Rules for each connected app.** In Settings › Agents › Apps, Rules… next to an app sets the one profile it may use
  and sites it may never open. Agents can now upload files to a page, only from that app's own folder or the folder you
  choose in Settings › Agents › Files, and what an agent's page downloads goes to Downloads › Airc Agents › the app's
  name instead of your Downloads list.
- **Agents tell you when a page needs you.** When an agent reaches a sign-in page or a captcha, its row in the Agents
  folder says Needs you, the folder gets a badge, and a few seconds later Airc sends a notification (if you allow
  them). Open the row and Take over to sign in; the agent can go on afterwards.

## Included from 0.1.33

- **Dark mode works.** Settings › Appearance › Airc has Auto (follows your Mac), Light or Dark, for the whole app:
  windows, the sidebar, Settings and every web page, live. Spaces follow it unless you give a Space its own Light or
  Dark in Edit Theme Color…; those Spaces are listed under Settings › Appearance, each with a **Follow Airc** button to
  undo that. Arc's light Space colours, such as cream and pastels, no longer stay light when your Mac is dark.

## Included from 0.1.32

- **Password-manager extensions work better.** 1Password's **Unlock 1Password** button on its in-page cards now opens
  the extension's popup, under its button as in Chrome. Extension popups such as Proton Pass's, Bitwarden's and
  1Password's open at the full size the extension asks for instead of being cut off. 1Password's extension can now
  find the 1Password app on your Mac: Airc uses the connection files the app installed for Chrome, Arc, Chromium, Edge
  or Brave. If the extension still stays locked, add Airc once in the 1Password app under Settings › Browser › Add
  Browser…. A new page, Settings › Passwords, has **Offer to save and fill passwords** for each profile: turn it off
  and Airc stops asking to save logins and stops listing its saved logins under fields there, so your password
  manager's extension has them to itself. The first time a profile has a password manager's extension on, a small card
  asks once whether to let it handle passwords there or keep both.

## Included from 0.1.31

- **Security: Airc now asks every app or script once before it can use the browser.** Airc recognises an app by
  what actually runs, not by the name it reports: a signed app by who signed it, a script by its file and contents, an
  unsigned program by its code, and a connection over SSH by the computer it comes from. Before, a plain script on your
  Mac could use the approval of the app that started it. Code Airc can't pin down, such as `python3 -c`, is asked every
  time. Some apps you already allowed, mostly scripts and tools run with `node` or `python3`, are asked once more.
  Allowed apps are listed in Settings › Agents › Apps. Thanks to the person who reported it.
- **Run the Airc Agent on your own Claude Code or Codex.** In Settings › AI › Agent › Use, choose Your Claude Code or
  Your Codex instead of an API key. Airc runs the copy installed on your Mac with the login you made in it, and Airc
  never sees that login. It gets only Airc's browser tools and still asks before it pays, sends, posts or deletes.
  Settings shows the version Airc found and whether you're logged in, with the fix if not.

## Included from 0.1.30

- **The Agents folder tidies itself.** When Claude or another AI app uses Airc, each row in the sidebar's Agents
  folder now says what the agent did: the site and the kind of work, such as "Gmail · read 3 pages" or "Corner Shop ·
  filled a form", or your task for the Airc Agent. Finished rows close by themselves after 5 minutes; choose 1, 5 or
  30 minutes, or until you clear them, in Settings › Agents › Keep finished agents for. A row you're watching stays,
  and Settings › Agents › Activity still lists what agents did. Apps that only connect, or only open a blank window, no
  longer add empty rows.

## Included from 0.1.29

- **Copy Quote Link, like Arc.** Select some text on a page, then choose Copy Quote Link in the page's right-click
  menu (right after Copy), click Share Quote under the address, or use the button in the offer that appears after ⌘C.
  The link opens the page scrolled to that text, highlighted, and Airc confirms with Arc's "Copied Link · With Quote"
  toast. Where a quote link can't work (a PDF, a page that always opens at its top, or a page in a private window),
  you get the page's plain link instead.

## Included from 0.1.28

- **Notification sounds stay out of the sidebar player.** Short pings from pages such as WhatsApp or Slack no longer
  pop up the sidebar's mini player or Now Playing. Music and videos still get their player, and the tab's speaker
  icon still shows that the page made a sound.

## Included from 0.1.27

- **Command Bar fixes.** The Ask rows no longer jump around while you type: once shown, they stay put. "Ask This
  Page…" is offered on every page and either works or says why, with a button to Settings › AI when it's off.
  "Ask Airc to…" shows even before you've added an API key and opens the Airc Agent's setup with your task filled in.
  And choosing a command in the Command Bar never leaves you unable to type.
- **WebKit's first launch is fast too.** With the WebKit engine, a link opened on Airc's very first launch now shows in
  about a second; it took about four. Airc ships its ad and tracker blocking rules ready to use instead of preparing
  them first.
- **Boosts sync between your Macs.** With iCloud sync on, your Boosts follow you to your other Macs. A Boost's
  JavaScript never runs just because it arrived: if you allowed it on one Mac, the next one asks for a quick confirm
  that names that Mac; code that no Mac vouched for needs Show Code before it can run. A tab you unpin on one Mac also
  keeps its Archive timer on the others. Turn it off in Settings › Sync › Sync Boosts.
- **The first launch after an update is a little quicker.** Once an update has downloaded and been checked, Airc starts
  the new version once in the background, so macOS's first-run checks are done before you open it. You'll notice it
  from the update after this one.

## Included from 0.1.26

- **Search suggestions from your imported search engines.** Search engines you brought over from Arc, Chrome or Brave
  now suggest as you type in the Command Bar, like the built-in ones: your imported default, and one of your imported
  shortcuts once you've picked it with Tab. They follow the same switches, Settings › Privacy and the profile's
  "Include search engine suggestions". In private windows they don't suggest.
- **"New ChatGPT Message" from the second letter.** The Command Bar now shows the "New ChatGPT Message" command (or
  "Ask Claude…" and "Ask Perplexity…") from the second letter you type, which keeps the first keystroke fast.

## Included from 0.1.25

- **Every launch is quick now.** About every other launch used to wait up to a second inside macOS before Airc even
  started, so a link from another app could take close to two seconds to show. That wait is gone with the Chromium
  engine, the default.

## Included from 0.1.24

- **Links open fast when Airc is closed.** Click a link in another app while Airc isn't running and its page shows in
  about a second; it used to take up to 6 seconds. With the Chromium engine (the default) that holds even on Airc's
  very first launch; with the WebKit engine, the very first launch took a few seconds once while it prepared its
  blocking rules, until 0.1.27. The page no longer waits for all of the ad and tracker blocking to be set up: only its own
  requests wait until the rules are in force, so nothing slips through.
- **Airc Agent (beta) gets better.** Replies now stream in as they're written, and Stop ends them at once. The
  approval card also shows in the Agents folder's Watch, so you can answer there. Optional memory (off by default,
  Settings › AI › Agent › Memory) keeps short Markdown notes between tasks that you can read, edit, undo or clear; it
  refuses to keep passwords, codes or card numbers. Type a task in the Command Bar and pick "Ask Airc to…". And if
  you'd rather use your Claude app, the panel offers "Hand to Claude Desktop" or "Hand to Claude Code" (once Airc is
  connected to it; the task is also copied to the clipboard). Airc's own agent still needs your own Anthropic or
  OpenAI API key.

## Included from 0.1.23

- **Pages follow light and dark.** Web pages now use their Space's light or dark look, so a dark Space shows sites in
  their dark style and a light Space in their light one. When the look changes, open pages switch at once, without a
  reload: when macOS switches automatically between light and dark (Appearance: Auto), when you change a Space's theme
  or move a tab to another Space. That includes background tabs, Peek and Little Airc; private windows follow macOS.

## Included from 0.1.22

- **Airc Agent (beta).** Press ⌥⌘A (or View › Airc Agent), describe a task, and Airc does it in your signed-in sites
  with your own Anthropic or OpenAI API key: add it in Settings › AI › Agent, where it stays in your Keychain. Before it
  pays, sends, posts or deletes, it asks you first, and you choose Allow Once or Deny. Pick Quick (up to 25 steps and 3
  minutes) or Keep going (up to 200 steps and 30 minutes), and Stop any time. Its runs show in the Agents folder, where
  you can watch or take over.

## Included from 0.1.21

- **Settings sync between your Macs.** With iCloud sync on, the settings you change follow you to your other Macs:
  your theme, shortcuts, Site Searches, search engine, Ask AI, link and Little Airc choices, blocking and more. If you
  change the same setting on two Macs, the later change wins. Things that belong to one Mac stay on it: folders and
  paths, Developer Mode, memory settings, extensions and the approvals you gave apps. Turn it off in Settings › Sync ›
  Sync settings (on by default while sync is on).
- **Ask Claude or ChatGPT from the Command Bar.** Type a question or a prompt after ⌘T, press ↓↓ to the Ask Claude (or
  Ask ChatGPT) row and Return: a new chat opens with your prompt, in the same profile. Choose Claude, ChatGPT,
  Perplexity or Off in Settings › AI › Command Bar › Ask AI. Automatic, the default, uses the chat site you keep pinned
  or as a Favorite, else the one you visited in the last 90 days, else none.

## Included from 0.1.20

- **Signing in to a new profile from the sidebar** now picks up the account's picture and name: the profile and its
  Space header show them. The sign-in card then offers Gmail, Calendar and Drive for that account as Favorites, with
  Add or Skip. A second Google account gets its own Gmail, Calendar and Drive, not the first account's.
- **The Feedback button sits next to +.** The speech bubble in the sidebar's bottom row moved from beside the Library
  button to just left of +, after your Space icons. Click it to write to the Airc team.

## Included from 0.1.19

- **Sign in with Google works inside Airc.** On pages that use Chromium, "Continue with Google" shows Google's account
  chooser over the page again, so you pick an account without a separate sign-in window. 0.1.18 had switched it off
  to fix a crash.
- **Your Google or Outlook calendar drives Join.** With a Google Calendar or Outlook calendar Favorite or pinned tab,
  the meeting countdown, Join and ⌃⌘J use that calendar's events and their call links (Meet, Zoom, Teams, Webex),
  not the calendars on your Mac.
- **Bangs in the Command Bar.** Type "!yt cats", "cats !yt", "!gm vienna" or your own Site Search keyword to search
  that site straight away. A bang Airc doesn't know stays part of your search.
- **Search suggestions no longer flicker.** While you type in the Command Bar, the last suggestions stay in place
  until new ones replace them.
- **Restart to Update waits for busy pages.** Every page gets a few seconds to finish. If a tab has unsaved work,
  Airc shows which one and asks, with Restart Anyway and Cancel.
- **⇧⌘R hard refresh** now also works in Little Airc and in an open Peek, and reloads the page in front.
- **Lighter and quieter.** With WebKit, Airc's main process uses far less memory after launch. Switching Spaces is
  smoother, and an idle Airc no longer wakes up on repeating timers.
- Fixes: no more crashes in a few rare Chrome dialogs (warnings about look-alike sites, Cast mirroring and passkey
  sign-in). Reset Tabs no longer asks twice about leaving a page.

## Included from 0.1.18

- **Use Airc from your other devices.** Claude Code or another AI app on another computer on your Tailscale network
  can use Airc on this Mac. Turn it on in Settings › Agents › Other devices (it's off until you do), then press Pair a
  Device: each device pairs once with a one-time code, and Revoke ends its access at any time. The first time, each
  device asks for the same one-time approval as an app on the Mac. Airc listens only on the Mac's Tailscale
  addresses.
- **Fixed a crash when signing in with Google on some sites (e.g. Pinterest).** With the Chromium engine, "Continue
  with Google" could quit Airc. Sign-in now opens Google's own sign-in window instead.
- **Calendar previews fit Arc's six hours.** Rest on a pinned Google Calendar or Outlook calendar tab to see six hours
  without scrolling, with all-day events and tomorrow's events on one line each. A Google or Outlook calendar Favorite
  now shows that calendar's own day, not the calendars on your Mac. A Gmail preview that says Open Gmail asks
  again as soon as you rest on it.
- **Typing in the Command Bar is lighter again.** Each letter takes about 1 ms less work on the test Mac, with the
  same results. macOS Services (like "Ask Claude") no longer show up as Command Bar commands that do nothing.
- **AI apps see page headings.** When Claude or another AI app reads a page, Airc lists its headings with their levels
  and leaves hidden ones out, on both engines.
- **Update downloads come straight from aircbrowser.com.** Airc and its updates now download through
  aircbrowser.com itself, so they no longer stall on networks where the old download host did.

## Included from 0.1.17

- **Connect Claude in one step.** Type "claude" (or "mcp", "agent") in the Command Bar, choose Help › Use Airc with
  Claude…, or use the sidebar's + menu: each opens Settings › Agents with Add to Claude Desktop first. Settings ›
  Agents › Access now says what's true, such as "On · Claude connected now". The + menu offers Connect Claude… until
  an app has connected.
- **Calendar previews show Arc's hour grid again.** Rest on a pinned Google Calendar or Outlook calendar tab to see
  six hours from just before now, with overlapping meetings side by side and a line at the current time; scroll for
  the rest of the day. All-day events and Join for a meeting about to start are above the grid, and tomorrow's events
  are under it.
- **Updates retry by themselves.** If an update download stalls, Airc gives up after 20 seconds instead of a minute
  and quietly tries once more, while automatic updates are on.
- **Export All Easels.** The card at the top of Library › Easels saves every Easel as a web page, all in one ZIP, with
  a page that lists them. You can keep working while it exports, and Cancel leaves no file behind. File › Export
  Easel… now uses the same panel as the Easel's menu, with a Format menu for Image (PNG) or Web Page (ZIP).
- **Dark site icons stay visible.** In a dark theme, a site icon that is itself dark sits on a small light plate, as
  in Arc, in tabs, Favorites, the Command Bar and previews. Colourful and light icons look as before.
- **What's New's Show me goes further.** It now also opens Settings › AI and Settings › Shortcuts, and a release can
  list up to seven things.

## Included from 0.1.16

- **See what your AI agent is doing.** When Claude or another AI app uses Airc, an Agents folder appears in your
  sidebar with each agent tab ("Claude · Mailbox"). Click one to watch it live, with each click and the field it types
  into highlighted. Take over to make the page your own tab, or Stop to end the agent's session. A banner tells you
  when an agent starts. Settings › Agents › Activity lists what agents did in the last 7 days: the sites and the kinds
  of actions, never what they read or typed. An option in Settings › Agents shows agent pages in front.
- **What's New in Airc.** After an update, a tab explains each new thing in a sentence or two, with a Show me button
  that takes you to it. In Settings › General › Automatic Updates › After an update, choose a tab, a card in the
  sidebar, or nothing.
- **Dark mode reads better.** All text in dark mode now meets standard contrast (WCAG AA), in every Space colour: the
  sidebar's labels and address, the Command Bar's rows, the Library and Settings. Dark Spaces are a little deeper,
  and Midnight is less see-through.
- **Tidy Downloads renames automatically.** Turn on Rename automatically in Settings › AI › Downloads, and a download
  with an unclear name such as "IMG_2041 (1).pdf" gets a clear one by itself, on your Mac, with Undo right after.
  Installers, disk images and archives keep their names. It's off until you turn it on and needs Apple Intelligence.
- **Share Quote.** Select a few words on a page and a Share Quote button shows under the address. Click it to copy a
  link that opens the page at that text. Turn it off with Enable Shared Quotes in Settings › General.
- **Change the Edit and Help menu shortcuts.** Settings › Shortcuts now lists the Help menu and the Edit menu's
  Spelling and Grammar, Substitutions, Transformations and Speech items, so you can give them keys of your own.
- **Typing in the Command Bar is lighter.** Each letter you type takes less work to reach the screen: on the test
  Mac, about 2.7 ms less with Chromium and 1.5 ms less with WebKit.

## Included from 0.1.15

- **The Command Bar opens instantly.** ⌘T shows the Command Bar in the next frame on screen, about 8 ms on the test
  Mac, down from about 16 ms, with either engine. Keys you type right away all reach it.
- **More app icons.** Settings › Appearance › App Icon now has six of Airc's own icons: Sunset, Ocean, Midnight and
  Graphite join Holographic and a redrawn Outline. The Finder shows your choice too, and it stays after an update.
- **Splits sync between your Macs.** With iCloud Sync on, pinned and Favorite splits reach your other Macs with their
  pages in order, side by side or stacked, at their sizes. An older Airc keeps them aside and shows them once it's
  updated.
- **Calendar previews.** Rest on a pinned Google Calendar or Outlook calendar tab to see today's and tomorrow's
  events, read from your signed-in page; click one to open it there. Switch it off per site in Settings › Appearance
  › Site Previews.

## Included from 0.1.14

- **Opens faster.** Airc's window appears right away instead of waiting for ad and tracker blocking to get ready.
  Pages still wait for their blocking rules, so nothing loads unprotected. On the test Mac, from opening Airc to its
  window on screen: about 1.2 s with Chromium and 0.65 s with WebKit when Airc has run before (0.1.13: about 1.5 s
  and 1 s), and about 5–6 s on the very first start of a new copy (0.1.13: about 9.5–10.5 s).
- **Arc import, complete.** With the Chromium engine, your saved logins, cookies (partitioned ones included), sites'
  stored data and the passwords for websites' own sign-in boxes come over from Arc. If you deny Keychain access,
  everything else still imports, and Try Again asks once more. Not imported: sites' databases (IndexedDB), offline
  caches, session storage and password notes; the results list them. Arc stops on December 22, 2026.
- **Notes and Easels open in Peek.** Click a note or an Easel in the Library and it opens in Peek over your page,
  ready to edit; Open in Space takes it home. Easels have Arc's Export as Image… and Export as Web Page…, and Library
  › Easels has Delete Easel…: the Easel goes to the Trash, and ⌘Z brings it back.
- **Clear Archive by age.** Clear everything, or only tabs older than 7 or 30 days, from every Space, with Undo right
  after.
- **See a Boost's code first.** Importing a Boost shows its code in full before anything runs. A Boost with code is
  installed switched off until you turn it on.
- **Choose what opens at launch.** Settings › General › When Airc starts: your windows and tabs from last time, or a
  new window. After a crash or an update's restart, your windows always come back.
- **A haptic tap when reordering tabs.** With haptics on, the trackpad taps each time a tab you drag moves to a new
  place.

## Included from 0.1.13

- **Let Claude use your browser.** Airc has an MCP connector built in, on by default. Claude Desktop, Claude Code
  and other AI apps can open pages, read them, click and type, in the sites you're signed in to, in windows of their
  own. Airc asks once per app, never shows an app your saved passwords, and never lets one into private windows.
  Set it up from Settings › Agents in one click.
- **What's new, in Airc itself.** After an update, a card in the sidebar shows what changed, with See All for the
  full notes. From now on, Restart to Update also previews the next version's highlights before you restart.
- **A Feedback button in the sidebar.** Send Feedback has a button at the bottom left of the sidebar, and typing
  "feedback" in the Command Bar (⌘T) finds it too. Attach up to five pictures by pasting, dropping, choosing a file
  or capturing the window.
- **Copy a link from the sidebar.** Every tab has a copy button next to its ×. Click it to copy the tab's link; the
  tab stays where it is.
- **New windows in full screen.** When your window is in full screen, ⌘N, ⌘⇧N and Move to New Window open the new
  window in a full-screen Space of its own, instead of floating over the one you're in.
- **Sidebar menus, as in Arc.** Control-click opens the menu everywhere in the sidebar, as a right-click does.
  Before this update, Control-clicking a tab's × closed the tab. Favorites and folders get Move to ›, which lists
  your Spaces by profile. Folders get Reset Folder and Turn into Space. The menus follow Arc's order.
- **Shared Quotes land on whole words.** A link to a quote you copied always starts and ends on whole words, so it
  finds and highlights the text.
- **Peek, on every engine.** ⇧-click opens a link in Peek with either engine. Links inside Peek follow your Air
  Traffic Control rules, and meeting links open as a tab instead of in Peek.
- **A steadier Command Bar.** A pointer resting over the Command Bar no longer picks a row; only moving it does.
  Typing puts the top match first.
- **Updates wait for a busy page.** Airc no longer restarts by itself for an update while a page is too busy to
  answer. Before this update, text you had typed on such a page could be lost.
- **Call recorders can recognise Airc.** Airc's helpers now identify as Airc (com.aircbrowser.Airc.helper), so
  recorders such as Granola can recognise Airc calls once they add Airc to their list.

## Included from 0.1.12

- **Right-click menus on web pages.** Right-clicking or Control-clicking a web page now opens its menu, on a link
  and on the page itself. Before this update, these menus didn't appear on most pages.
- **Open Link in Space, in every link menu.** Right-click a link and choose Open Link in Space › to open it as a
  new tab in any of your Spaces, other profiles' Spaces included. The window switches to that Space and the page you
  were on stays as it was. Private windows and Little Airc don't list Spaces.
- **Every extension to reinstall, when you import from Arc.** The import checklist shows each extension with its
  Chrome Web Store button. With many extensions, the list scrolls, and its last row peeks out so you can tell.
  Settings › Import shows the same list.
- **Your Spaces are saved as soon as you quit.** Airc writes your Spaces and tabs the moment a quit is accepted.
  On a busy Mac, quitting can take a few seconds; nothing is lost.
- **No more "held" tabs.** A click in the sidebar that ends outside the window no longer leaves a tab stuck to
  the pointer.

## Included from 0.1.11

- **Favorite badges, as in Arc.** An X Favorite shows its notification count ("3", "20+", "99+"), and Slack shows
  a red @ when someone mentions you or writes to you directly. The Calendar Favorite's countdown pill turns bright
  from five minutes before a meeting. A Favorite in a call shows a green camera badge, and one you're sharing into
  a call shows two green windows. Right-click a Favorite and uncheck Show Unread Badge to turn its X or Slack badge
  off; Show Time to Next Meeting does the same for Calendar's pill.
- **Your search engines come along.** Importing from Arc, Chrome or Brave, at first launch or in Settings → Import,
  brings each profile's default search engine and the search shortcuts you made yourself. Shortcuts become Site
  Searches, so "yt", Tab, then your search works in the Command Bar as it did in Arc.
- **Add to Airc for shared Easels.** A shared Easel's page (aircbrowser.com/e/…) has an Add to Airc button, and the
  link also opens in Airc when you click, paste or type it. You see the Easel and the Space it goes to first; Add Easel
  then adds a copy of your own. Changed your mind? Click the sidebar and press ⌘Z to take it back.

## Included from 0.1.10

- **Send Feedback.** Choose Help › Send Feedback…, or type "Send Feedback" in the Command Bar (⌘T), to write
  to the Airc team. You choose what to include: a screenshot of the window and the app's details are off until
  you tick them, and "What will be sent" lists every part before you click Send. A screenshot shows that window's
  tabs and the page in it. Offline, the message waits on your Mac and goes later.
- **Tab previews show their age.** Resting on a tab shows a picture of it. When that picture is older, a small
  label says so, for example "Not loaded · pictured 12 min ago".
- **Turn off one tab's preview.** Right-click a pinned tab or Favorite and uncheck Show Hover Preview, as in Arc.
  The other rows keep theirs.
- **VoiceOver reads tab previews.** A preview is read as "Preview of" the page, with the picture's age, and its
  buttons can be pressed.
- **Preview cards stay put.** A hover card no longer jumps to other rows while you move the pointer to its buttons.

## Included from 0.1.9

- **Unread mail without switching tabs.** Rest on a pinned Gmail or Outlook tab to see your unread mail,
  newest first. Click a message to open it in Peek; when no page from that account's profile is open,
  it opens in the mail tab itself. Tabs › Peek Email… is there too. Airc reads your own signed-in page.
  Turn previews off per site in Settings › Appearance › Site Previews.
- **Copy a tab into a new window.** Hold ⌥ as you drag a tab out of the window to make a copy.
  Drag without ⌥ to move the live page without reloading it.
- **Older features stay on the website.** The features page and changelog keep every shipped version's
  history as new updates arrive.

## Included from 0.1.8

- **⌘T responds from the first keystroke.** The first character now takes about 8 ms to process,
  down from about 160 ms, so you can start typing straight away.
- **Fold a Space's pinned tabs.** Click a Space's name to fold its pinned tabs away, and click again
  to bring them back. The chevron turns with the rows, and each named Space remembers its state.
- **Move an inactive window at once.** Drag from any empty window margin on the first press,
  even when another app is in front. Dimmed sidebar text stays readable against each Space's colours.
- **See What's New opens the changelog.** Release notes open at the right version on the website,
  instead of downloading an HTML file.

## Included from 0.1.7

- **History stays in ⌘T during cleanup.** Suggestions from the history you keep remain available while
  Airc removes older entries. Deleted history and Clear History still disappear straight away.
- **YouTube ads blocked too.** Airc blocks supported pre-rolls and ad slots on YouTube. Turn blocking
  off for YouTube in Site Controls, or for the whole profile in Settings.
- **Window margins work like a title bar.** Double-click an empty margin to zoom or minimize,
  following your Mac's title-bar setting.

## Included from 0.1.6

- **Passkeys always ask for you.** Signing in with a passkey now requires Touch ID or your Mac password,
  including on Macs without Touch ID or with the lid closed. This fixes a security issue in 0.1.4 and 0.1.5
  where Continue could complete a passkey sign-in without asking for your Mac password.
- **Your search engine, per profile.** Choose Google, Bing, DuckDuckGo, Ecosia, Brave, Yahoo, Startpage,
  Perplexity or Kagi. Search suggestions have their own per-profile switch, and searching selected text
  uses that profile's engine too.
- **Calendar meetings that count.** Live Calendar skips declined meetings, all-day events and out-of-office
  time, keeps tentative meetings, and groups its preview under Today and Tomorrow. Calendar accounts
  still need to be added to your Mac; Airc doesn't sign in to them itself yet.
- **History suggestions keep working.** ⌘T recovers promptly when browsing history reaches its storage
  limit, instead of leaving you waiting for suggestions.

## Please know

- **Short sounds:** a clip of 5 seconds or less still gets the sidebar player when its page gives it media details
  (a title with artist, album or artwork), as a music page would.

- **The first launch after you install Airc from the DMG** can take a few seconds longer, while macOS checks the new
  copy once. Updates through Airc do that check before Airc restarts.

- **Boost sync** was tested between two copies of Airc with a stand-in for iCloud on the build Mac, not with real
  iCloud yet. Older versions of Airc don't get synced Boosts until they're updated.

- **WebKit's fast first launch** was measured on macOS 26. On other macOS versions WebKit may still prepare its
  blocking rules once on the first launch.

- **Light and dark pages:** a site that has no dark style stays light in a dark Space. macOS's automatic switch was
  checked on the build Mac with a simulated change, not the real sunset switch yet.

- **The Airc Agent is a beta.** It needs your own Anthropic or OpenAI API key, and the provider bills its usage to that
  key. It hasn't been tried against every site yet, so watch its first runs on a new site. Its memory filter errs on
  the safe side and may refuse an ordinary number, such as a postcode.

- **Settings sync** was tested between two copies of Airc with a stand-in for iCloud on the build Mac, not with real
  iCloud yet. Older versions of Airc don't get synced settings until they're updated.

- **Arc import's Keychain prompt** was tested in simulation only: the real macOS prompt, and choosing Deny in it,
  haven't been tried on a real Arc import yet.

- **Launch with Chromium** takes about 1.2 s on the test Mac when Airc has run before, still above its 1 s goal.

- **A link opened while Airc is starting** shows its window at once; its page waits until ad blocking is ready.

- **If you click Check for Updates yourself** and the download stalls, Sparkle's error still shows before the quiet
  retry.

- **Signing in to a new profile from the sidebar** was tested with a stand-in for Google's sign-in on the build Mac,
  not real accounts yet.

- **Signing in with Google** was tested with a stand-in sign-in provider on the build Mac, using the same account
  chooser Google's real pages show.

- **Using Airc from your other devices** was tested with Claude Code on a Linux computer over Tailscale and with test
  devices on the build Mac.

- **Watching an agent** is live on the Chromium engine. On WebKit, the picture updates about 15 times a second.

- **Tidy Downloads' automatic rename** was tested with a stand-in model, not Apple Intelligence itself.

- **In dark mode,** a selected tab's grey text is held to a lower contrast (3:1) while the pointer rests on it.

- **Using Airc from AI apps** was tested with Claude Code and test apps on the build Mac. Claude Desktop hasn't been
  tried with a released build yet.

- On pages that use Chromium, the link menu item reads "Open link in Space" with a small "l"; a later update
  matches the rest of the menu.

- An Easel added from a link is a copy of your own, not a live shared Easel as in Arc: later changes to the original don't reach it.

- Slack's mention badge depends on Slack's page title, so it can be missed if Slack changes how its title marks mentions.

- **Calendar previews and Join** were tested on look-alike Google Calendar and Outlook pages, not real accounts yet,
  and they read the page's English event text. When an event's call link isn't on the calendar page, Airc reads the
  event's own page for it once, which can take a few seconds.

- Mail previews read only the page you've signed in to; Outlook's preview has been tested on a look-alike page, not a real account yet.

- YouTube may change its ads; if one gets through, it'll be blocked in an update.

- **Safe Browsing remains off. Do not rely on Chrome-equivalent phishing or download protection.**
- **Passkeys now always ask for Touch ID or your Mac password.** iCloud Keychain passkeys still need Apple's
  approval. Safari-engine pages don't offer passkeys yet.
- **Automatic updates:** a real update from 0.1.15 to 0.1.16 worked in our test, with the small delta download
  (3.6 MB). The signed download is always available for manual installation.
- **Cast was tested without a real receiver.** Discovery, audio/video on a TV and actual Local Network permission
  changes still need device testing. Safari-engine pages use their own AirPlay support, not Chromium Cast.
- **Easels:** export, links and Live Captures are included. Easels don't sync between Macs yet, there's no freehand
  drawing, and a shared Easel can be viewed but not edited together.
- **GitHub Live Folders:** public repositories work without an account; private and personal lists need a personal
  access token. Built-in GitHub device sign-in awaits the OAuth app setup. Live Folder settings don't sync.
- **iCloud Sync:** Notes sync was exercised with real iCloud on the build Mac. Two-Mac iCloud Keychain delivery
  remains unqualified. Today tabs stay on this Mac.
- **Library recent files:** reading a Desktop folder still needs your macOS permission. That permission journey
  across a relaunch has not been qualified.
- **Instant Links:** tested live on both engines with Google and DuckDuckGo's HTML results page, configured as
  a site search. Bing, Kagi, Ecosia and the built-in DuckDuckGo results page are untried. Claude's question
  prefill after sign-in has not been verified.
- The full test suite is not green. Releases use a focused check; broader testing continues separately.
- **Capture Full Page** stops at 32,000 pixels or 48 megapixels on very long pages and says so. Protected video
  may appear black.
- **Protected content:** Widevine certification and licensing clearance remain pending. Subscription playback
  is not qualified. Disable Play protected content in Settings → Privacy if you don't want Widevine installed.
- **Anonymous usage data and crash reports:** on by default, never browsing content. Turn them off, or see what
  is sent, in Settings → Privacy.
- **No Chrome Sync.** Signing in to Google websites is separate from browser sync.
- **Arc import:** unreadable encrypted data and unsupported records are skipped with a reason.
- **Smoothness:** 120 Hz animation and zero idle work remain goals, not measured promises.

Source: `c2069afac928d5467d218b4e4b5b28fcf557addb`. Build: `202611170206`. Channel: stable.

Source: `ef878a1ef0f67d52c0ec1c67cf22352116bb9e9a`. Build: `202611170359`. Channel: stable.

Source: `0a5f5855b0ad09fc32b134c3471ed81b17f0453e`. Build: `202611170628`. Channel: stable.

Source: `d19d7715733c04a3055fa2e3013eaa11eb41af1b`. Build: `202611170915`. Channel: stable.

Source: `32b71c325bb83eed113928365b88002a7ac55853`. Build: `202611171442`. Channel: stable.

Source: `40bcc58995139d047af2e3e33b2f13fd6b158c6e`. Build: `202611171945`. Channel: stable.

Source: `9d102758d7059dd385f18d7bc2a4970c06c07c6e`. Build: `202611172236`. Channel: stable.

Source: `f930c80c2818eb6bf034d0c5e26ac3f4f4027a07`. Build: `202611180104`. Channel: stable.

Source: `be46a6d44ea224e21b3b63b21ef4ff472b36707a`. Build: `202611180334`. Channel: stable.

Source: `cf89c99efbf785953a14c4329b0b337232bc2ca5`. Build: `202611180649`. Channel: stable.

Source: `ba4c2862fde68d2e1b31c1dc953ff14c26f0661e`. Build: `202611181244`. Channel: stable.

Source: `d3016be304ded4d83b04b6fc2fe1a63afc370102`. Build: `202611181536`. Channel: stable.

Source: `6d59d8c8591e57a478b14c1eb7f43cbe172321ad`. Build: `202611181828`. Channel: stable.

Source: `a0e197dc2e4120ca42dc7ecf779ec37fc65443f3`. Build: `202611190200`. Channel: stable.

Source: `35f49f84cd2840b63c5e0e7873d57177a9d8904d`. Build: `202611190422`. Channel: stable.

Source: `42f92268662a36b0ee3b69395a4f9f90d5d69132`. Build: `202611190830`. Channel: stable.

Source: `d5b37cf4529435c56188c1e282fb4ec4245d1416`. Build: `202611191644`. Channel: stable.

Source: `e8aaf24ab43d385258fd3333412e42cba292ea79`. Build: `202611192232`. Channel: stable.

Source: `6265e36e66c2c964c796c26641769380c3e267ce`. Build: `202611200250`. Channel: stable.

Source: `d384973d52c1a72f15ea1309612452f80cc46ac6`. Build: `202611200840`. Channel: stable.

Source: `7fe40b24ca536cb520ac86099f623106bb7413ab`. Build: `202611201407`. Channel: stable.

Source: `e66fd734687e06822304d76a9d6a1c71f120f1e5`. Build: `202611202114`. Channel: stable. Engine: official.

Source: `66a83bd8d20414c2fc584621bb031bbee16880c8`. Build: `202611210133`. Channel: stable. Engine: official.

Source: `ec9a93692770b83f46a3fa42c9d92599cbf2b199`. Build: `202611210945`. Channel: stable. Engine: official.

Source: `9992b5664322a5d6a3b6df4764af7a28f41e66a9`. Build: `202611211626`. Channel: stable. Engine: official.

Source: `11b82ab08ead648d966deb9bff22ee95c8674e19`. Build: `202611212123`. Channel: stable. Engine: official.

Source: `f2c558030a0f89f6f40d16729282c64f31a6a3b7`. Build: `202611220357`. Channel: stable. Engine: official.

Source: `dc14f7a948782772da54b79af31405ac7a65e1e9`. Build: `202611220848`. Channel: stable. Engine: official.

Source: `fc3e0391f1ee2ca6860f08f294fce86f7d19a8f3`. Build: `202611221309`. Channel: stable. Engine: official.

Source: `f9609b2253783b58a0ba7fee0eece637e7f1a104`. Build: `202611222125`. Channel: stable. Engine: official.

Source: `0c1f3c2c950f71fa161ab798669f6f192a6505b3`. Build: `202611230318`. Channel: stable. Engine: official.

Source: `5d8fa9dbd490a8c19928af6fe0855d4c7c0bf49f`. Build: `202611230853`. Channel: stable. Engine: official.

Source: `ca0f2fc1348e6207ad977f18723b8d2e6b2ece2d`. Build: `202611231455`. Channel: stable. Engine: official.

Source: `db46f9018d915a7363668b50ffb591c3888dc4b7`. Build: `202611240050`. Channel: stable. Engine: official.

Source: `b02f84a1751243e3fa95f4ace52bd8671ed99f09`. Build: `202611240914`. Channel: stable. Engine: official.

Source: `75f5c922c3e40a27bf1c8eb3559f3bbcb6f2e3a5`. Build: `202611241608`. Channel: stable. Engine: official.

Source: `ae94cd3d3052796fa0674f76d09dc7d00ad42081`. Build: `202611242213`. Channel: stable. Engine: official.

Source: `ea292247f74b9713c3f17a1755d9e5b5a7e7ff7c`. Build: `202611250702`. Channel: stable. Engine: official.

Source: `aedd795e8c965b8bdfdf2d6513d9f469f5fa8511`. Build: `202611252306`. Channel: stable. Engine: official.

Source: `10f50403292d0b4ece92f93c375110c567d68928`. Build: `202611261155`. Channel: stable. Engine: official.

Source: `53d0867e341dcf3eb6e0d4b5f32d7063f02a5cfd`. Build: `202611261832`. Channel: stable. Engine: official.

Source: `1c1488b03c738328b3d6ef429c13d017eba42461`. Build: `202611270639`. Channel: stable. Engine: official.
