# Space themes

Every Space has its own colors. Click the Space's name in the sidebar, choose **Theme…**, and drag the handles on the
color disc: up to three colors, **Auto**, **Light** or **Dark**, how strong the color is (intensity) and how much grain.
The window recolors as you drag. Airc draws themes the way Arc did: the colors blend on a diagonal over the macOS window
blur, with the grain on top.

## Light, dark and automatic

**Auto** follows your Mac's appearance, except that a very light theme stays light and a very dark one stays dark, as in
Arc. **Light** and **Dark** keep the theme one way whatever the Mac does.

Whatever the colors, the sidebar's text is kept readable: the theme gives way before the text does. Tab titles have at
least 4.5:1 contrast on every part of the background, secondary labels and icons 3:1, placeholders 2.4:1, also at
intensity 0 and 1 and in a window you're not using (inactive windows dim the ink a little, never below those).

## Reduce Motion and Reduce Transparency

Airc follows **System Settings › Accessibility › Display**:

- **Reduce motion:** switching Spaces doesn't slide, folders open without sliding rows, and other motion becomes a short
  cross-fade.
- **Reduce transparency:** the window stops showing the desktop through it and draws its theme opaque, as soon as you
  turn it on.

## Your theme on web pages

Like Arc, Airc gives every web page the colors of its Space's theme as CSS custom properties, under Arc's own names.
A Boost or a page written for Arc's theme colors works the same way in Airc:

```css
body {
  background: var(--arc-palette-background);
  color: var(--arc-palette-foregroundPrimary);
}
a { color: var(--arc-palette-focus); }
```

| Variable | What it is |
|---|---|
| `--arc-palette-background` | The Space's background color (the window's average) |
| `--arc-palette-backgroundExtra` | The raised surface color (the Command Bar's, menus') |
| `--arc-palette-foregroundPrimary` | Main text color on the background (at least 4.5:1) |
| `--arc-palette-foregroundSecondary` | Secondary text color (at least 3:1) |
| `--arc-palette-foregroundTertiary` | Faint text color (placeholders) |
| `--arc-palette-title`, `--arc-palette-subtitle` | Same as primary and secondary text |
| `--arc-palette-maxContrastColor` | Black on a light theme, white on a dark one |
| `--arc-palette-minContrastColor` | White on a light theme, black on a dark one |
| `--arc-palette-focus` | The theme's accent color (focus rings, links) |
| `--arc-palette-hover` | The hover color on the background |
| `--arc-palette-cutoutColor` | Text color on the accent color |
| `--arc-background-simple-color` | The background as one flat color |
| `--arc-background-gradient-color0` … `2` | Each theme color as the window draws it |
| `--arc-background-gradient-overlay-color0` … `2` | Each theme color, see-through, as the window layers it |

Good to know:

- Each page gets **its own Space's** colors, in the appearance that Space has right now. Changing the theme, the Mac's
  appearance, or moving a tab to another Space updates its pages at once, without a reload. A page moved to another
  window keeps its Space's colors.
- Pages in private windows (and Little Airc) have no Space, so they get none of these variables.
- The variables are on the page's root with the lowest priority: a page that defines a variable of the same name keeps
  its own. Only the top page gets them, not the frames inside it.
- Airc puts the colors on a page as it starts loading. On this build the very first moment of a page can still be
  without them (a few milliseconds); write `var(--arc-palette-background, white)` with a fallback if that matters.
- Nothing about your theme is sent anywhere; the page reads its own colors in your browser, as with Arc.
