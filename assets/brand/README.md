# Airc brand

The Airc mark: an "A" with an arc running through it (in front of the right leg, behind the left) and the dot of
an "i" cutting into the right leg. It's drawn in code (`build.py`) from exact geometry, so it stays symmetric and
crisp at every size.

| File | Use |
|---|---|
| `airc-holographic.svg` / `.png` | **App icon** (macOS squircle, holographic ring), 1024px PNG |
| `airc-outline-squircle.svg` / `.png` | Plain outline icon on white, 1024px PNG |
| `airc-mark-outline.svg` | The bare outline mark (monochrome contexts, menu bar, favicons) |
| `airc-color.svg` / `.png` | Flat-colour mark. **On hold:** older proportions and a placeholder palette, to be redone |

Final proportions: element thickness 138, outline 16px and border 12px on the 600px icon canvas.
The SVGs use only plain gradients and masks (no blend modes or filters), so they render in any viewer.

Regenerate the SVGs with `python3 build.py`. For the PNGs, screenshot each SVG at 1024x1024 with a transparent
background, for example
`google-chrome --headless --default-background-color=00000000 --screenshot=out.png --window-size=1024,1024 file://$PWD/airc-holographic.svg`.

## App icon

`AppIcon.icns` and `AppIcon.appiconset/` (Xcode asset catalog, `Contents.json` included) are generated from
`airc-holographic.svg`. Every macOS size is there: 16, 32, 128, 256 and 512 pt at @1x and @2x (16 to 1024 px).
They sit on the macOS icon grid: the squircle is the 824 px body of a 1024 px canvas, with a soft drop shadow
and transparent corners. To wire one in, add `AppIcon.appiconset` to an asset catalog, or copy `AppIcon.icns`
into `Contents/Resources/` and set `CFBundleIconFile` to `AppIcon`.

**Small sizes.** At 16 and 32 px the icon's 16 px outline (on the 600 px canvas) falls below half a device pixel
and disappears, and the ring blurs into the face. So `icon_16x16.png`, `icon_16x16@2x.png` and `icon_32x32.png`
(16 and 32 px) use **`airc-icon-small.svg`** instead. It's drawn by `appicon.py` with `build.py`'s own functions
(`icon`, `vector_outline`, `squircle`):
- no ring;
- the face fills the whole squircle;
- the mark scales up with the face;
- a 40 px outline and a 22 px border.

At those sizes the A reads as a solid letter with its dot. From 32 pt @2x (64 px) up, the full icon is used.

Regenerate on the build Mac (WebKit renders the SVGs at 1024 px through the AircDesign gallery's `--html` mode,
`sips` scales, `iconutil` packs):

```bash
assets/brand/appicon.sh      # writes AppIcon.icns, AppIcon.appiconset/, build/contact-sheet.png
```

`build/contact-sheet.png` shows every size at 1× and the small ones at 8×, on light and dark, for checking.
