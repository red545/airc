# Shortcuts: pages, editors and Arc's map

Checked 2026-11-06 with `--script shortcuts` (`apps/browser/Sources/Airc/Debug/ShortcutsCheck.swift`) on both engines.
Owner report: "cmd+shift+v doesn't work … any shortcut like cmd+b". Sources: spec CB-2 and CB-3,
`docs/research/arc_behavior_spec.md` §7 and Chrome 156's own tables (`accelerators_cocoa.mm`,
`global_keyboard_shortcuts_mac.mm`, Blink's `editing_behavior.cc`).

## How keys are routed

1. `KeyMonitor` (App/Commands.swift) sees every key first. Browser-first keys run their command at once: ⌘T ⌘W ⌘N ⌘Q,
   ⇧⌘W, every ⌥ and ⌃ combination, ⌘{ ⌘}. With several windows (WIN-7) a key goes to the browser window it was typed
   in (`event.window`); a menu click goes to the key browser window, else the one used last.
2. Other ⌘ and ⇧⌘ keys Airc binds (⌘D ⌘L ⌘S ⇧⌘C …) go to the page first (CB-3). A page that calls
   `preventDefault` keeps the key. Pressing it again within 1 s runs Airc's command. If the page doesn't use the key,
   the command runs once. ⌥⌘V is page-first too, because Docs uses it for Paste Formatting.
3. Every other key goes the AppKit way for a key window: the page view's `performKeyEquivalent:`, then the main
   menu, then `keyDown:`. Page keys the page doesn't use come back from the engine (Chromium's unhandled-key callback,
   WebKit's resend) and go to the main menu. The Edit menu's Copy, Paste, Undo and Paste and Match Style then reach the
   page view.
4. Chrome's delayed keys ⌘← ⌘→ are text navigation in any field. Outside a field they're Back and Forward, but only
   when the engine hands the key back unused (`KeyMonitor.pageDidNotUse`). They have no menu item: AppKit lets a
   matching item, even a disabled one, take the key from our own text fields.
5. ⌘Z undoes in any field being edited, ours or the page's. With the page focused outside a field, the page gets ⌘Z
   first, so a canvas app's own undo works. If the page doesn't use it, ⌘Z reopens the closed tab (SB-23, SB-40).
6. Private windows (PW-1) follow the same order with their own commands (`PrivateWindowController.handleKeyPageFirst`):
   the keys they bind go to the page first by the same rule, ⌘Z and Paste and Match Style go the AppKit way to the
   page. `--script private` checks ⌘F and ⌘L (page uses / doesn't), ⌘Z in a page field and ⇧⌘V on both engines.

## Your own keys: Settings → Shortcuts (CB-4)

Every key in this file is a default. Settings → Shortcuts (`Settings/ShortcutsSettings.swift`) lists every command by
menu (the app menu, File, Edit, View, Spaces, Tabs, with the hidden second keys and ⌘← ⌘→ under Tabs), keyless ones
too. A click on a key records a new one: Esc cancels, Delete (⌫ or ⌦) removes it. Each changed row has a reset arrow,
and Reset All brings the whole table back.

- **The model** is AircKit's `ShortcutMap` (`packages/AircKit/Sources/AircKit/Shortcuts.swift`, unit tests in
  `ShortcutMapTests`): today's table as defaults, the user's changes on top. A key belongs to one command at most;
  the user's choice wins over a default.
- **Conflicts.** A key another command has asks first: **Swap** gives the other command this one's old key (or none),
  **Replace** takes the key away from it. Resetting a row whose default someone else has now asks the same.
- **Refused:** a key without ⌘, ⌥ or ⌃, and macOS's or every app's own: ⌘Q (hold to quit stays), ⌘H ⌥⌘H ⌘M,
  ⌘Tab ⇧⌘Tab, ⌘ with the key above Tab (switching windows), ⌘Space ⌥⌘Space ⌃Space ⌃⌥Space ⌃⌘Space, ⌃⌘Q, ⌥⌘Esc, ⌥⌘D, ⌃⌘F (Enter Full Screen), ⌘C ⌘V ⌘X ⌘A
  ⇧⌘Z, ⇧⌘3/4/5 and ⌃⇧⌘3/4, ⌃← ⌃→ ⌃↑ ⌃↓. The recorder says why and keeps listening.
- **Allowed with a note:** keys pages use themselves: ⌘B ⌘I ⌘U ⌘K ⌘Z ⇧⌘V ⌥⇧⌘V ⌥⌘V ⌘↩ ⌘/ ⌘⌫. Those are
  page-first, whatever command has them (unless that command is Airc first, below): a page that uses one keeps it,
  and a second press within a second runs Airc's command. ⌘Z given to a command still undoes in any field being
  edited, and no longer reopens closed tabs (⇧⌘T still does).
- **Key order** otherwise follows the key, as with the defaults: ⌘ and ⇧⌘ keys go to the page first except Chrome's
  reserved ⌘T ⌘W ⌘N ⌘Q, ⌥ and ⌃ keys to the browser. The commands with a fixed order keep it (⌘{ ⌘} browser-first,
  ⌘← ⌘→ after the page).
- **Websites first / Airc first** (Arc's "Prefer Websites / Prefer Arc"): every row whose key a page could have first
  (the ⌘ and ⇧⌘ keys above, the page keys, ⌥⌘V's Paste URL, and a row of its own for ⌘Z's Reopen Closed Tab outside
  text fields, shown while no command has ⌘Z) has a two-way switch. **Websites first** is the default and CB-3's rule.
  **Airc first** runs the command at once and the page never sees the key (`KeyMonitor.pageMayUse`, so the main window,
  several windows, blank windows and private windows alike; Little Arc's few keys are always Airc's). Fields still
  keep their own ⌘Z and ⌘A ⌘C ⌘V ⌘X. The switch belongs to the command: it moves with it when its key changes, and
  rows whose key a page can't have (⌥ ⌃ keys, ⌘T ⌘W ⌘N ⌘Q, ⌘← ⌘→, the app menu's own) don't show it. A row's reset
  arrow puts both the key and Websites first back.
- **Live everywhere.** `App/ShortcutCenter.swift` holds the map: the key monitor reads it on every key, the main menu's
  items get their new keys at once, and private windows and Little Arc, whose key tables spell the defaults, look a
  typed key up there (`defaultKey(forTyped:)`), so a moved key works and the old one goes to the page. The Command
  Bar's action hints show the user's keys too.
- **Menus spell ⇧ letters in upper case** ("L" with ⌘, not "l" with ⇧⌘). AppKit's own matcher gave a freed ⌘L to an
  item spelled "l" + ⇧ (Library), so a key that left its command still ran another one.
- **Storage:** `settings.json`'s `shortcuts`, command id → `"alt+cmd+l"`, `""` for none, and `"<id>:first": "airc"`
  for Airc first (builds before it read that as an unknown command and skip it). Only changes are kept: an untouched
  command follows a new default in a later version, an entry equal to its default, an unknown command or an
  unreadable or refused key is dropped. Ids are stable (`file.openLocation`, `tabs.library`, `spaces.3`,
  `file.reopenOnUndo` for ⌘Z's fixed row …; Commands.swift).
- **Telemetry:** `feature.used` `shortcut.remap` per change made in the page (a key or a switch), never which command
  or key.

`--script shortcutremap` (`Debug/ShortcutRemapCheck.swift`, in build-app.sh's suite on both engines) records ⌥⌘L for
Open Location in the Settings window (⌘L then reaches the page and opens nothing; ⌥⌘L opens the address editor;
AppKit's menu takes no freed ⌘L), swaps Pin with Library's ⇧⌘L (⇧⌘L pins, ⌘D opens the Library), refuses ⌘H, warns
about ⌘B, clears with Delete, checks a private window and Little Arc, resets Pin into a conflict and then everything,
and checks the menus and settings.json after each step. Then Airc first on ⌘L, on a page that claims ⌘L: with Websites
first the page keeps it; with Airc first the page never sees it and the address editor opens, in the main window and in
a private window; back to Websites first, the page has it again and nothing is stored.

## Page and editor keys (both engines)

The loopback editor page has a contenteditable, a textarea and an input, plus a keydown/keyup/beforeinput/paste
logger. All of these pass on WebKit and on Chromium:

| Keys | Result |
|---|---|
| ⌘B ⌘I ⌘U | Format the contenteditable selection (`<b>`, `<i>`, `<u>`). Chromium does this itself. On WebKit, which has no such keys, the page script runs `execCommand` unless the page prevented the key. |
| ⌘K ⇧⌘X ⇧⌘7 ⇧⌘8 ⌘/ ⌘↩ ⇧⌘↩ ⇧⌘E ⇧⌘L ⇧⌘R ⇧⌘C ⇧⌘K ⇧⌘S ⌥⌘1–6 | Reach the page once. When the page uses them, nothing else happens: no Library, reload, copied URL, Clear, Save or sidebar. |
| ⇧⌘V, ⌥⇧⌘V | Edit › Paste and Match Style (new). Plain text lands in the contenteditable from a rich clipboard. ⌘V keeps the formatting. |
| ⌘A ⌘C ⌘X ⌘V ⌘Z ⇧⌘Z | Work in page fields. The page sees the keydown and the copy, cut, paste and historyUndo/Redo events. |
| ⌘← ⌘→ ⌘↑ ⌘↓ ⌥← ⌥→ ⌃A ⌃E ⌃K ⌘⌫ ⌦ | Text navigation and deletion in a textarea. Never Back/Forward. |
| ⌘D ⌘E ⌘L ⌘S ⌘Y ⌘F ⌘G ⌘O ⌘P ⌘[ ⇧⌘C ⌥⌘V ⌘Z | A page that uses them keeps them, even past the 1 s answer timeout. Without that, the command runs once: pinned, not pinned again, one step back. A second ⇧⌘C within 1 s copies the URL. |
| Our fields (Command Bar ⌘T, ⌘L, Boost code editor) | ⌘A ⌘C ⌘X ⌘V ⌘Z ⇧⌘Z ⇧⌘V ⌘← ⌘→ ⌥← ⌥→ ⌃A ⌃E ⌃K ⌘⌫ work. The bar stays open. |
| Focus | After a Space switch (⌃n away and back) and after a click on the page's sidebar row, the page has the keyboard. |

Not covered: a real key window. Scripted runs never activate the app, so the check makes its window report itself
key and replays AppKit's key-window order (see the check's header). Also not covered: password fields, where the page
view has no text input context, so ⌘Z there acts as outside a field.

## Airc against Arc

Status: **works** (already there, checked), **added** (this pass), **different**, **missing**.

| Arc | Key | Airc | Status | Notes |
|---|---|---|---|---|
| New tab (Command Bar) | ⌘T | Command Bar | works | Browser-first, as Chrome reserves it |
| Edit URL | ⌘L | Command Bar on the URL | works | Page first (CB-3) |
| New window / incognito / blank window | ⌘N / ⇧⌘N / ⌃⌘N | File › New Window, ⇧⌘N New Private Window, ⌃⌘N New Blank Window | ⌘N added, ⇧⌘N works, ⌃⌘N added | Browser-first. ⌘N (WIN-7) opens a window on the key window's Space with the Command Bar, also with no window open and from a private window or Little Arc (from a blank window: an ordinary one). In a private window ⇧⌘N opens another of the same session. ⌃⌘N opens Arc's blank window: a window on a Space of its own (its Today tabs are its own, no other window lists them), with the Command Bar. `--script windows` checks ⌘N and ⌃⌘N |
| Close tab (archive) | ⌘W | Archive Tab | works | |
| Close window | ⇧⌘W | File › Close Window | added | Browser-first, in the window the key is for (`--script windows`). Closing the last window leaves Airc running, as Arc and Chrome; ⌘N or the Dock brings it back |
| Close other tabs | ⌥⌘W | File › Close Other Tabs | added | The other Today tabs go to the Archive, as with Clear. Pinned tabs and Favorites stay. Per the lead, Arc's key. Not in the research notes |
| Reopen closed tab | ⇧⌘T, ⌘Z | Reopen Closed Tab | works, fixed | ⌘Z used to reopen tabs even while typing in a page, so Docs and form undo never happened |
| Pin / unpin | ⌘D | Pin / Unpin Tab | works | Page first |
| Show / hide sidebar | ⌘S | Toggle Sidebar | works | Page first (Docs' ⌘S stays Docs') |
| Clear Today | ⇧⌘K | Clear Today | works | Page first (Slack's ⇧⌘K) |
| Copy URL / as Markdown / as quote | ⇧⌘C / ⌥⇧⌘C / ⌃⇧⌘C | Copy URL, Copy URL as Markdown | works / missing | ⌃⇧⌘C missing: the research doesn't say what the quote looks like |
| Paste URL as new tab | ⌥⌘V | Edit › Paste URL in New Tab | added | Page first, so Docs' Paste Formatting still works. Text that isn't a URL is searched |
| Space N | ⌃1–9 | Space n | works | |
| Previous / next Space | ⌥⌘← / ⌥⌘→ | Previous/Next Space | works | |
| Previous / next tab | ⌥⌘↑ / ⌥⌘↓, ⌘{ ⌘} | Previous/Next Tab | works / added | ⌘{ ⌘} and Chrome's ⌃⇞ ⌃⇟ added (hidden menu items). On a QWERTZ layout ⌘{ ⌘} need ⌥, as in Arc and Chrome |
| Sidebar item N / last | ⌘1–8 / ⌘9 | Sidebar Tab n | works | Page first |
| Recent tab | ⌃Tab | Last Used Tab | works | |
| Focus sidebar | ⌘. | — | missing | Unconfirmed in Arc (2021); ⌘. is Stop on macOS |
| Reveal current tab | ⌃Space | — | different | macOS input-source switch owns ⌃Space |
| Library | ⇧⌘L | Library | works | Page first (Docs' left align) |
| Little Arc / open in Space / move | ⌥⌘N / ⌘O / ⌥⌘O | Little Arc | works | Little Arc's own keys |
| Split add / close / focus | ⌃⇧= / ⌃⇧− / ⌃⇧1–4 | New Split View, Close Pane, Focus Pane n | works | |
| Show / hide toolbar | ⇧⌘D | — | missing | Airc has no toolbar |
| Developer Mode | ⌃D | — | missing | No Developer Mode. ⌃D is also delete-forward in text fields |
| Join meeting | ⌃⌘J | Tabs › Join Next Meeting | added | The meeting the sidebar offers to join (Live Calendar). Beeps without one |
| Capture | ⇧⌘2 | — | missing | No Capture feature |
| New note | ⌃⇧N | — | missing | No Notes |
| Remove a Command Bar suggestion | ⌥⌘⌫ | — | missing | Needs history removal in the bar |
| Extensions | ⌘E | Extensions | works | Page first |
| History | ⌘Y | History | works | Chromium: chrome://history. WebKit: the Command Bar |
| Full screen | ⌃⌘F | Enter Full Screen | works | Esc goes to the page first |
| Quit | ⌘Q (hold) | Hold to quit | works, fixed | A tap shows "Hold ⌘Q to Quit". It quits only if Q and ⌘ are still down at 0.7 s. On Chromium the key-up never reaches the app's monitor, so a tap used to quit |

Chrome's keys where Arc doesn't override them:

| Chrome | Key | Airc | Status |
|---|---|---|---|
| Reload / ignoring cache | ⌘R / ⇧⌘R | Reload, Reload Ignoring Cache | works (⇧⌘R page first) |
| Back / forward | ⌘[ / ⌘] | Back, Forward (in a split: the panes) | works |
| Back / forward | ⌘← / ⌘→ | Back, Forward outside a field | added (Chrome's delayed keys) |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G | Find | works |
| Zoom | ⌘+ ⌘− ⌘0 | Zoom | works |
| DevTools / console / source | ⌥⌘I / ⌥⌘J / ⌥⌘U | View menu | works |
| Inspect element | ⌥⌘C | — | missing |
| Print / Settings | ⌘P / ⌘, | Print, Settings | works |
| Paste and Match Style | ⇧⌘V, ⌥⇧⌘V | Edit › Paste and Match Style | added |
| Search tabs | ⇧⌘A | Tabs › Search Tabs… (the Command Bar) | added |
| Save page | ⇧⌘S | Save Page As… | works (Arc moved it from ⌘S): Airc's save panel with Web Page, Complete / HTML Only / Single File on Chromium; Print → Save as PDF where the engine can't save the page |
| Reading mode | ⌥⌘R | — | missing (no reading mode) |

Other keys in the request that neither Arc's map nor Chrome has: ⌘\, ⇧⌘⌫ (Clear is ⇧⌘K) and ⌥⌘T. They aren't bound.

## Keyboard layouts

`KeyMonitor` matches characters (`charactersIgnoringModifiers`), as AppKit's menus do. On a German or Austrian
layout, ⌘Z is the key labelled Z, wherever it sits. Chromium rebuilds key events from their key codes, so the check
posts what the build Mac's layout really produces (`ShortcutsCheck.Layout`). On Chromium it skips keys the layout
can't type without ⌥ (⌘[ ⌘{ ⌘} on QWERTZ).
