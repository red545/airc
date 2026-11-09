# Keyboard: Cycle Tab, Esc, removing suggestions, other keyboard layouts

Four keyboard details that work as they did in Arc. The full list of keys is in [Shortcuts](shortcuts.md).

## Cycle Tab (⌃⌘→ and ⌃⌘←)

**Cycle Tab Forward** (⌃⌘→) goes through every tab of the Space, starting with the one you used before this one, then
the one before that, and so on. **Cycle Tab Backward** (⌃⌘←) goes the other way. Both wrap around at the end. Both are
in the **Tabs** menu.

- Unlike ⌃Tab, which stops after the five most recent tabs, Cycle Tab goes through all of the Space's open tabs:
  Favorites, pinned tabs and Today tabs.
- You can let go of the keys between presses and the cycle carries on in the same order. It starts again from the
  latest order after you show a tab some other way, for example by clicking it, pressing ⌘1 or opening a new tab.
- Only the tab you stop on counts as used, so the tabs you pass keep their place.
- A tab you close mid-cycle is skipped. Each Space has its own cycle.
- Cycle Tab never shows a private window's pages, and in a private window the keys don't affect your other windows.

## Esc closes one thing at a time

Esc closes the surface on top and nothing else. If several are open, each press closes the next one, in this order:

1. the Command Bar (first its completion, then a site search, then the bar itself)
2. a Peek
3. the find bar
4. full screen: press Esc twice, or hold it
5. the sidebar's keyboard focus (⌃Space): the page gets the keyboard back

For example, with the find bar open while the sidebar has the keyboard, the first Esc closes the find bar and the
sidebar keeps the keyboard. The second Esc gives the keyboard back to the page.

## Removing a suggestion: the ✕ and your own key

In the Command Bar, point at a page from your history and a **✕** appears at the right end of its row. Click it to remove
the page from the suggestions and from the profile's history. The bar stays open and keeps what you typed. Search rows,
open tabs and commands have no ✕.

The key for the same thing is Arc's **⌥⌘⌫**. You can change it in **Settings → Shortcuts → Command Bar** ("Remove
Suggestion from History"). The ✕'s tooltip shows the current key.

## Keyboard layouts without [ and ]

Some keyboard layouts type [ ] { } only with ⌥, for example German, Austrian, French, Swiss, Spanish and the Nordic
layouts. On these layouts the bracket shortcuts work in two ways, as in Arc and in macOS's own menus:

- **The key where a US keyboard has the bracket.** On a German or Austrian keyboard, ⌘Ü goes Back and ⇧⌘Ü goes to the
  previous tab. ⇧⌘\* (the key right of Ü) goes to the next tab.
- **The bracket typed with ⌥.** On German or Austrian, ⌥⌘5 is ⌘[ (Back) and ⌥⌘6 is ⌘] (Forward). ⌥⌘8 and ⌥⌘9 are ⌘{ and
  ⌘} (previous and next tab).

An extra key never takes over a key that already does something on your layout. On German and Austrian keyboards, ⌘+
stays Zoom In, so Forward uses ⌥⌘6. If you move ⌘[ to another key in Settings → Shortcuts, the extra keys follow it. On
layouts that type the brackets directly, such as US and UK, nothing changes. When you switch your input source, the
keys update straight away.

## Not yet

- Cycle Tab stays within the Space. Whether Arc's cycle crossed Spaces hasn't been checked against Arc yet.
- Arc showed nothing on screen while cycling, and neither does Airc. There's no switcher panel.
