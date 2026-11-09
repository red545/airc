# Scripting Airc

Airc speaks Arc's AppleScript dictionary. A script written for Arc works when you change `tell application "Arc"` to
`tell application "Airc"`, and so do tools that script Arc this way (launchers, Shortcuts, Keyboard Maestro). Open
Script Editor's File › Open Dictionary… and choose Airc to see every term.

The first time an app scripts Airc, macOS asks whether to allow it (System Settings › Privacy & Security ›
Automation).

## What a script can reach

- **Windows**: browser windows and private windows, front to back. Each has `name`, `id`, `index`, `active tab`,
  `active space`, `incognito` and `mode` (`"normal"` or `"incognito"`), its `tabs` and its `spaces`.
- **Spaces**: `title`, `id`, `profile` (the profile's name; Airc's addition), and their `tabs`. `focus` shows a space.
- **Tabs**: `title`, `URL` (setting it loads the address), `id`, `loading`, and `location`:
  - `topApp`: a Favorite;
  - `pinned`: a pinned tab, also in folders and pinned splits;
  - `unpinned`: a Today tab, or a private window's tab.

  A window's tabs are every space's, each once; a space's tabs are its own Favorites, pinned and Today tabs, in sidebar
  order. A pinned tab or Favorite keeps its `id` whether its page is loaded or not.
- **Commands**: `select`, `go back`, `go forward`, `reload`, `stop`, `close` and `execute … javascript` on a tab;
  `close` on a window; `focus` on a space; `make new window` and `make new tab`.

Closing a tab works as ⌘W does: a Today tab closes, a pinned tab or Favorite unloads and keeps its row. `go back`,
`reload` and the rest need the tab's page to be loaded; `select` it first.

## Examples

```applescript
tell application "Airc"
    -- the page on screen
    set pageURL to URL of active tab of front window
    set pageTitle to title of active tab of front window

    -- a new tab in the window, or in its second space
    tell front window to make new tab with properties {URL:"https://example.com"}
    tell space 2 of front window to make new tab with properties {URL:"https://example.com"}

    -- every tab, with where it sits in the sidebar
    repeat with t in tabs of front window
        log (title of t) & " — " & (location of t)
    end repeat

    -- find a tab by its id and show it
    tell (first tab of front window whose id is "…") to select

    -- show a space, by name
    tell (first space of front window whose title is "Work") to focus

    -- a private window
    make new window with properties {incognito:true}

    -- a Little Arc window
    make new tab with properties {URL:"https://example.com"}
end tell
```

## JavaScript

`execute` runs JavaScript in a tab's page and answers with text: a string as it is, anything else as JSON.

```applescript
tell application "Airc"
    execute active tab of front window javascript "document.title"
end tell
```

It's off until you turn it on with **View › Allow JavaScript from Apple Events**, as in Arc and Chrome, because it lets
any app you've allowed to script Airc read and change your pages. The switch covers every profile. Airc never runs
JavaScript from scripts in private windows; scripts can still read their tabs and open or close them.
