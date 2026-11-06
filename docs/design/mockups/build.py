#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Builds the self-contained HTML mockups from AircDesign's resolved theme values.

    python3 docs/design/mockups/build.py

Inputs: resolved-themes.json (written by `swift run aircdesign-gallery <dir>` in packages/AircDesign; copy it
here when themes change). Outputs: window.html, command-bar.html, space-switch.html, onboarding.html.
Every size is in points (CSS px) and comes from docs/design.md / AircMetrics.
"""
import base64
import json
import random
import re
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
THEMES = json.loads((HERE / "resolved-themes.json").read_text())


# ---------------------------------------------------------------------------------------------- grain

def grain_png(n=256, seed=0xA1C):
    rnd = random.Random(seed)
    rows = []
    for _ in range(n):
        row = bytearray([0])
        for _ in range(n):
            v = rnd.random() + rnd.random() - 1
            a = min(1.0, abs(v) * 0.9)
            row += bytes([255 if v > 0 else 0, int(round(a * 255))])
        rows.append(bytes(row))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 4, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
    return "data:image/png;base64," + base64.b64encode(png).decode()


GRAIN = grain_png()


# ---------------------------------------------------------------------------------------------- icons

def svg(body, size=16, stroke=1.75, vb=24, extra=""):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 {vb} {vb}" fill="none" stroke="currentColor" '
            f'stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round" {extra}>{body}</svg>')


I = {
    "sidebar": '<rect x="3" y="4.5" width="18" height="15" rx="3.5"/><path d="M9.5 4.5v15M5.8 8.5h1.4M5.8 11h1.4M5.8 13.5h1.4"/>',
    "back": '<path d="M15 18l-6-6 6-6"/>',
    "forward": '<path d="M9 18l6-6-6-6"/>',
    "reload": '<path d="M20 12a8 8 0 1 1-2.34-5.66"/><path d="M20 4v5h-5"/>',
    "plus": '<path d="M12 5v14M5 12h14"/>',
    "x": '<path d="M17 7 7 17M7 7l10 10"/>',
    "archive": '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"/>',
    "search": '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    "link": '<path d="M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 0 0-7.07-7.07l-1.5 1.5"/><path d="M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 0 0 7.07 7.07l1.5-1.5"/>',
    "sliders": '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
    "more": '<circle cx="5" cy="12" r="1.2" fill="currentColor"/><circle cx="12" cy="12" r="1.2" fill="currentColor"/><circle cx="19" cy="12" r="1.2" fill="currentColor"/>',
    "speaker": '<path d="M11 5 6.5 9H3.5v6h3l4.5 4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18.5 6a8 8 0 0 1 0 12"/>',
    "folder": '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5h3.6l2 2.2h7.4A2.5 2.5 0 0 1 21 9.7v7.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/>',
    "check": '<path d="M20 6 9 17l-5-5"/>',
    "arrow": '<path d="M5 12h14M13 6l6 6-6 6"/>',
    "return": '<path d="M9 10l-5 5 5 5"/><path d="M20 4v7a4 4 0 0 1-4 4H4"/>',
    "sun": '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4 6 18M18 6l1.4-1.4"/>',
    "moon": '<path d="M20.5 13.2A8.5 8.5 0 1 1 10.8 3.5a6.6 6.6 0 0 0 9.7 9.7z"/>',
    "auto": '<path d="M12 3l1.8 4.9L18.7 9.7l-4.9 1.8L12 16.4l-1.8-4.9L5.3 9.7l4.9-1.8z"/><path d="M19 15l.8 2.2 2.2.8-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>',
    "lock": '<rect x="4.5" y="10.5" width="15" height="10" rx="2.5"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>',
    "clock": '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
    "globe": '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 2.6 3.5 5.4 3.5 8.5s-1 5.9-3.5 8.5c-2.5-2.6-3.5-5.4-3.5-8.5s1-5.9 3.5-8.5z"/>',
    "space": '<rect x="3.5" y="4.5" width="17" height="15" rx="3.5"/><path d="M3.5 9.5h17"/>',
    "user": '<circle cx="12" cy="8.5" r="3.8"/><path d="M4.5 20a7.5 7.5 0 0 1 15 0"/>',
    "chevdown": '<path d="M7 10l5 5 5-5"/>',
    "share": '<path d="M12 15V3.5M7.5 8 12 3.5 16.5 8"/><path d="M5 12.5V18a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5.5"/>',
    "puzzle": '<path d="M9 4.5h3.5a1.8 1.8 0 1 1 3.4 0H19v4a1.8 1.8 0 1 0 0 3.4V16H15.5a1.8 1.8 0 1 1-3.4 0H9v-3.5a1.8 1.8 0 1 1 0-3.4z"/>',
}


def icon(name, size=16, stroke=1.75):
    return svg(I[name], size, stroke)


# Simplified, brand-coloured favicons (drawn, not copied).
FAV = {
    "gmail": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><path d="M3 8v10.5A1.5 1.5 0 0 0 4.5 20H7v-8.5z" fill="#4285F4"/><path d="M17 11.5V20h2.5a1.5 1.5 0 0 0 1.5-1.5V8z" fill="#34A853"/><path d="M3 8l9 6.5L21 8V6.6a1.6 1.6 0 0 0-2.6-1.3L12 10.2 5.6 5.3A1.6 1.6 0 0 0 3 6.6z" fill="#EA4335"/><path d="M17 11.5 21 8V6.6a1.6 1.6 0 0 0-2.6-1.3L17 6.4z" fill="#FBBC04"/><path d="M7 11.5 3 8V6.6a1.6 1.6 0 0 1 2.6-1.3L7 6.4z" fill="#C5221F"/></svg>',
    "gcal": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="3" y="3" width="18" height="18" rx="4" fill="#4285F4"/><rect x="3" y="3" width="18" height="5" rx="2" fill="#1967D2"/><text x="12" y="18" text-anchor="middle" font-family="-apple-system,Helvetica,Arial" font-weight="700" font-size="10" fill="#fff">4</text></svg>',
    "slack": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="9" y="2.5" width="3.6" height="9" rx="1.8" fill="#36C5F0"/><rect x="12.5" y="9" width="9" height="3.6" rx="1.8" fill="#2EB67D"/><rect x="11.4" y="12.5" width="3.6" height="9" rx="1.8" fill="#ECB22E"/><rect x="2.5" y="11.4" width="9" height="3.6" rx="1.8" fill="#E01E5A"/></svg>',
    "notion": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="3.5" y="3" width="17" height="18" rx="3" fill="#fff" stroke="#111" stroke-width="1.6"/><path d="M8.5 16.5v-9l7 9v-9" fill="none" stroke="#111" stroke-width="1.8" stroke-linejoin="round"/></svg>',
    "google": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><path d="M20.6 12.2c0-.6-.1-1.2-.2-1.8H12v3.4h4.8a4.1 4.1 0 0 1-1.8 2.7v2.2h2.9c1.7-1.6 2.7-3.9 2.7-6.5z" fill="#4285F4"/><path d="M12 21c2.4 0 4.5-.8 5.9-2.2L15 16.6c-.8.5-1.8.9-3 .9-2.3 0-4.3-1.6-5-3.7H4v2.3A9 9 0 0 0 12 21z" fill="#34A853"/><path d="M7 13.8a5.4 5.4 0 0 1 0-3.5V8H4a9 9 0 0 0 0 8.1z" fill="#FBBC04"/><path d="M12 6.6c1.3 0 2.5.5 3.4 1.3l2.6-2.6A9 9 0 0 0 4 8l3 2.3c.7-2.1 2.7-3.7 5-3.7z" fill="#EA4335"/></svg>',
    "github": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><circle cx="12" cy="12" r="10" fill="#1F2328"/><path d="M8.3 9.6 8 6.6l2.3 1.5a7 7 0 0 1 3.4 0L16 6.6l-.3 3a4.2 4.2 0 0 1 .8 2.6c0 2.6-1.7 3.6-3.4 3.9.5.4.6 1 .6 1.6v2.4h-3.4v-2.1c-1.6.3-2.3-.4-2.7-1.1" fill="#fff"/><path d="M10.3 16.1c-1.7-.3-3.3-1.3-3.3-3.9 0-1 .4-1.9 1.1-2.6" fill="#fff"/></svg>',
    "youtube": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="2" y="5.5" width="20" height="13" rx="4" fill="#FF0033"/><path d="M10 9.2v5.6l4.8-2.8z" fill="#fff"/></svg>',
    "figma": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><path d="M9 3h3v6H9a3 3 0 0 1 0-6z" fill="#F24E1E"/><path d="M12 3h3a3 3 0 0 1 0 6h-3z" fill="#FF7262"/><path d="M9 9h3v6H9a3 3 0 0 1 0-6z" fill="#A259FF"/><circle cx="15" cy="12" r="3" fill="#1ABCFE"/><path d="M9 15h3v3a3 3 0 1 1-3-3z" fill="#0ACF83"/></svg>',
    "linear": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><defs><linearGradient id="lg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7C86F2"/><stop offset="1" stop-color="#4B55C8"/></linearGradient></defs><circle cx="12" cy="12" r="9.5" fill="url(#lg)"/><path d="M5 13.5 10.5 19M5.6 9.8l8.6 8.6M7.6 6.8l9.6 9.6M10.6 4.9l8.5 8.5" stroke="#fff" stroke-width="1.3" stroke-linecap="round"/></svg>',
    "sheets": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><path d="M6 2.5h8.5L19.5 7.5V20a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 20V4A1.5 1.5 0 0 1 6 2.5z" fill="#0F9D58"/><path d="M14.5 2.5v5h5z" fill="#87CEAC"/><rect x="7.5" y="11" width="9" height="7" rx=".5" fill="none" stroke="#fff" stroke-width="1.2"/><path d="M7.5 14.5h9M11 11v7" stroke="#fff" stroke-width="1.2"/></svg>',
    "vercel": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="2" y="2" width="20" height="20" rx="5" fill="#111"/><path d="M12 7.5 17 16H7z" fill="#fff"/></svg>',
    "local": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="2.5" y="2.5" width="19" height="19" rx="5" fill="#111"/><text x="12" y="17" text-anchor="middle" font-family="Georgia,serif" font-weight="700" font-size="13" fill="#fff">t</text></svg>',
    "paper": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="2.5" y="2.5" width="19" height="19" rx="5.5" fill="#1F3A2E"/><path d="M8 17V7h5a3 3 0 0 1 0 6H8" fill="none" stroke="#F3EAD7" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    "maps": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="2.5" y="2.5" width="19" height="19" rx="5" fill="#E8F0E4"/><path d="M2.5 15 21.5 7" stroke="#F6C445" stroke-width="3"/><circle cx="14" cy="9.5" r="3.2" fill="#EA4335"/><circle cx="14" cy="9.5" r="1.2" fill="#fff"/></svg>',
    "claude": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><g stroke="#D97757" stroke-width="2.2" stroke-linecap="round"><path d="M12 3.5v17M3.5 12h17M6 6l12 12M18 6 6 18"/></g></svg>',
    "airbnb": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><rect x="2.5" y="2.5" width="19" height="19" rx="5" fill="#FF385C"/><path d="M12 7c-1 0-1.6 1-2.6 3.2L8 13.6c-.9 2 1.4 3.4 2.6 1.8L12 13.5l1.4 1.9c1.2 1.6 3.5.2 2.6-1.8l-1.4-3.4C13.6 8 13 7 12 7z" fill="none" stroke="#fff" stroke-width="1.3"/></svg>',
    "docs": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><path d="M6 2.5h8.5L19.5 7.5V20a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 20V4A1.5 1.5 0 0 1 6 2.5z" fill="#4285F4"/><path d="M14.5 2.5v5h5z" fill="#A1C2FA"/><path d="M8 12h8M8 15h8M8 18h5" stroke="#fff" stroke-width="1.3" stroke-linecap="round"/></svg>',
    "arc": '<svg viewBox="0 0 24 24" width="{s}" height="{s}"><defs><linearGradient id="ag" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF6B6B"/><stop offset=".5" stop-color="#FFB86B"/><stop offset="1" stop-color="#6B8BFF"/></linearGradient></defs><rect x="2" y="2" width="20" height="20" rx="5.5" fill="url(#ag)"/><path d="M7 16.5c1.5-6 8.5-6 10 0" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/></svg>',
}


def fav(name, size=18):
    return FAV[name].format(s=size)


BRAND = HERE.parent.parent.parent / "assets" / "brand"
APP_ICON = "data:image/svg+xml;base64," + base64.b64encode((BRAND / "airc-holographic.svg").read_bytes()).decode()


def app_icon(size=96, shadow=True):
    """The real app icon (assets/brand/airc-holographic.svg), on the macOS icon grid: body = 824/1024 of the box."""
    f = "filter:drop-shadow(0 6px 14px rgba(40,20,80,.22)) drop-shadow(0 1px 2px rgba(0,0,0,.12))" if shadow else ""
    return f'<img class="appicon" src="{APP_ICON}" width="{size}" height="{size}" style="display:block;{f}">'


# ---------------------------------------------------------------------------------------------- theme → CSS

def tvars(tid, mode="light"):
    t = THEMES[tid][mode]
    stops = ", ".join(f'{s["color"]} {s["location"] * 100:.1f}%' for s in t["gradient"])
    layers = []
    if t["overlay"]:
        o = t["overlay"]
        layers.append(f"linear-gradient(to bottom, {o.replace(', 1.000)', ', 0)')}, {o})")
    layers.append(f"linear-gradient(135deg, {stops})")
    v = {
        "underlay": t["underlay"], "layer": ", ".join(layers), "layer-o": f'{t["layerOpacity"]:.4f}',
        "grain-o": f'{t["grain"]:.4f}', "text": t["text"], "text2": t["textSecondary"], "text3": t["textTertiary"],
        "text4": t["textDisabled"], "hover": t["hoverFill"], "pressed": t["pressedFill"], "selected": t["selectedFill"],
        "sel-shadow": "0 0.5px 2px rgba(0,0,0,.20)" if t["selectedHasShadow"] else "none",
        "tile": t["tileFill"], "tile-hover": t["tileHoverFill"], "field": t["fieldFill"], "sep": t["separator"],
        "surface": t["surface"], "s-text": t["surfaceText"], "s-text2": t["surfaceTextSecondary"],
        "s-text3": t["surfaceTextTertiary"], "s-border": t["surfaceBorder"], "s-hover": t["surfaceHover"],
        "s-selected": t["surfaceSelected"], "accent": t["accent"], "on-accent": t["onAccent"], "ring": t["focusRing"],
        "bgsolid": t["background"],
        "completion": t.get("inlineCompletionText", t["surfaceTextTertiary"]),
        "completion-bg": t.get("inlineCompletionHighlight", t["accent"].rsplit(",", 1)[0] + ", .18)"),
        "card-shadow": ("0 0 0 .5px rgba(255,255,255,.06), 0 1px 3px rgba(0,0,0,.35)" if t["isDark"]
                        else "0 0 0 .5px rgba(0,0,0,.08), 0 1px 3px rgba(0,0,0,.10)"),
        "btn2": "rgba(255,255,255,.09)" if t["isDark"] else "#fff",
        "seg-on": "rgba(255,255,255,.20)" if t["isDark"] else "#fff",
        "field-bg": "rgba(255,255,255,.05)" if t["isDark"] else "#fff",
        "field-border": t["surfaceText"].rsplit(",", 1)[0] + ", .13)",
        "group-bg": "rgba(255,255,255,.035)" if t["isDark"] else "#fff",
        "und": f'{t["underlaySubtle"]:.2f}', "und-more": f'{t["underlayMore"]:.2f}', "mat": t["materialTint"],
        "mat-o": f'{1 - t["materialPassThrough"]:.2f}',
    }
    return ";".join(f"--{k}:{val}" for k, val in v.items()) + (";color-scheme:dark" if t["isDark"] else ";color-scheme:light")


def is_dark(tid, mode="light"):
    return THEMES[tid][mode]["isDark"]


# ---------------------------------------------------------------------------------------------- CSS

CSS = """
:root{--font:-apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro",system-ui,"Helvetica Neue",Arial,sans-serif;
--rounded:ui-rounded,"SF Pro Rounded",-apple-system,BlinkMacSystemFont,system-ui,sans-serif;
--mono:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace}
*{box-sizing:border-box;margin:0;padding:0}
button{-webkit-appearance:none;appearance:none;border:0;background:transparent;font:inherit;color:inherit;cursor:default}
html,body{background:#0f0d0c}
body{font-family:var(--font);-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;text-rendering:optimizeLegibility}
.win{position:relative;width:1440px;height:900px;overflow:hidden;color:var(--text);font-size:13px;letter-spacing:-.04px;flex:none}
.bg{position:absolute;inset:0;background:var(--underlay)}
.bg::before{content:"";position:absolute;inset:0;background:var(--layer);opacity:var(--layer-o)}
.bg::after{content:"";position:absolute;inset:0;background-image:url(GRAIN);background-size:128px 128px;opacity:var(--grain-o)}
/* traffic lights: 12 pt, centres (20,24) (43,24) (66,24) */
.tl{position:absolute;top:18px;width:12px;height:12px;border-radius:50%;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.14)}
.tl.r{left:14px;background:#FF5F57}.tl.y{left:37px;background:#FEBC2E}.tl.g{left:60px;background:#28C840}
.hbtn{position:absolute;top:7.5px;width:32px;height:32px;border-radius:6px;display:grid;place-items:center;color:var(--text2)}
.hbtn.off{color:var(--text4)}
.hbtn.hover{background:var(--hover)}
.sidebar{position:absolute;left:0;top:0;bottom:0;width:228px}
.url{position:absolute;top:46px;left:8px;right:8px;height:36px;border-radius:12px;background:var(--field);display:flex;align-items:center;padding:0 6px 0 12px;font-size:13px;color:var(--text2);letter-spacing:-.04px}
.url .host{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.url .ub{width:30px;height:30px;border-radius:8px;display:grid;place-items:center;color:var(--text2)}
.favs{position:absolute;top:90px;left:8px;right:8px;display:grid;gap:8px}
.tile{height:47px;border-radius:10px;background:var(--tile);display:grid;place-items:center;position:relative}
.tile.active{background:var(--selected);box-shadow:var(--sel-shadow)}
.tile .dot{position:absolute;right:8px;bottom:7px;width:6px;height:6px;border-radius:50%;background:#E5453A}
.list{position:absolute;left:0;right:0;bottom:50px;display:flex;flex-direction:column}
.row{height:41px;padding:2.5px 8px;flex:none}
.plate{height:36px;border-radius:12px;position:relative}
.plate.hover{background:var(--hover)}
.plate.sel{background:var(--selected);box-shadow:var(--sel-shadow)}
.plate .fi{position:absolute;top:9px;width:18px;height:18px;display:grid;place-items:center}
.plate .fi svg{display:block}
.plate .tt{position:absolute;top:0;bottom:0;right:9px;display:flex;flex-direction:column;justify-content:center;font-size:14px;line-height:18px;letter-spacing:-.08px;color:var(--text);min-width:0}
/* titles never run under a trailing control and never end in "…": they fade out over the last 24 pt (design §7) */
.plate .tt span{white-space:nowrap;overflow:hidden;-webkit-mask-image:linear-gradient(to right,#000 calc(100% - 24px),transparent);mask-image:linear-gradient(to right,#000 calc(100% - 24px),transparent)}
.plate .tt small{font-size:11px;line-height:13px;color:var(--text3);letter-spacing:.02px}
.plate .tt b{font-weight:600}
.plate .close{position:absolute;right:5px;top:5px;width:26px;height:26px;border-radius:8px;display:grid;place-items:center;color:var(--text2)}
.plate .aud{display:inline-flex;vertical-align:-3px;margin-right:8px;color:var(--text2)}
.plate.unloaded .fi{opacity:.5}
.space{height:41px;padding:2.5px 8px;flex:none}
.space .plate{display:flex;align-items:center}
.space .emo{position:absolute;left:5px;top:5px;width:26px;height:26px;display:grid;place-items:center;font-size:15px}
.space .nm{position:absolute;left:33px;font-size:14px;font-weight:600;color:var(--text2);letter-spacing:-.08px}
.space .prof{position:absolute;right:36px;display:flex;align-items:center;gap:5px;height:22px;padding:0 8px 0 3px;border-radius:11px;background:var(--tile);font-size:11px;font-weight:500;color:var(--text2)}
.space .prof i{width:16px;height:16px;border-radius:50%;display:grid;place-items:center;font-style:normal;font-size:9px;font-weight:700;color:#fff}
.space .more{position:absolute;right:6px;top:6px;width:24px;height:24px;border-radius:6px;display:grid;place-items:center;color:var(--text2)}
.divider{height:14.5px;position:relative;flex:none}
.divider .ln{position:absolute;top:9.75px;left:18px;right:18px;height:.5px;background:var(--sep)}
.divider.clear .ln{right:58px}
.divider .clr{position:absolute;right:18px;top:3.5px;font-size:10px;font-weight:600;letter-spacing:.1px;color:var(--text3)}
.newtab .tt{color:var(--text3)!important}.newtab .fi{color:var(--text3)}
.footer{position:absolute;left:0;right:0;bottom:0;height:50px}
.footer .fb{position:absolute;top:9px;width:32px;height:32px;border-radius:8px;display:grid;place-items:center;color:var(--text2)}
.spaces{position:absolute;left:44px;right:44px;top:8px;height:34px;display:flex;justify-content:center}
.spaces .c{width:34px;height:34px;display:grid;place-items:center;font-size:16px;opacity:.45;filter:saturate(.5)}
.spaces .c.on{opacity:1;filter:none}
.spaces .c .d{width:6px;height:6px;border-radius:50%;background:var(--text)}
.card{position:absolute;left:228px;top:10px;right:10px;bottom:10px;border-radius:6px;overflow:hidden;background:#fff;box-shadow:var(--card-shadow)}
.cursor{position:absolute;width:17px;height:24px;z-index:50;pointer-events:none;filter:drop-shadow(0 1px 1.5px rgba(0,0,0,.35))}
/* surfaces & controls (AircDesign components) */
.surface{background:var(--surface);color:var(--s-text)}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;height:30px;padding:0 14px;border-radius:8px;font-size:13px;font-weight:500;letter-spacing:-.04px;white-space:nowrap;position:relative;font-family:var(--font)}
.btn.lg{height:38px;padding:0 18px;border-radius:10px;font-size:14px;font-weight:600;letter-spacing:-.1px}
.btn.sm{height:24px;padding:0 10px;border-radius:6px;font-size:12px}
.btn.primary{background:var(--accent);color:var(--on-accent);box-shadow:inset 0 1px 0 rgba(255,255,255,.20),0 1px 1px color-mix(in srgb,var(--accent) 35%,transparent)}
.btn.secondary{background:var(--btn2);color:var(--s-text);box-shadow:inset 0 0 0 .5px var(--field-border),0 .5px 1px rgba(0,0,0,.10)}
.btn.plain{color:var(--s-text)}
.field{height:32px;border-radius:8px;background:var(--field-bg);box-shadow:inset 0 0 0 1px var(--field-border);display:flex;align-items:center;gap:8px;padding:0 10px;font-size:13px;color:var(--s-text)}
.field.focus{box-shadow:inset 0 0 0 1px var(--accent),0 0 0 3px color-mix(in srgb,var(--accent) 18%,transparent)}
.label{font-size:12px;font-weight:500;color:var(--s-text2);margin-bottom:6px}
.group{border-radius:10px;background:var(--group-bg);box-shadow:inset 0 0 0 .5px var(--s-border)}
.group .gr{display:flex;align-items:center;gap:12px;min-height:44px;padding:10px 14px;position:relative}
.group .gr+.gr::before{content:"";position:absolute;top:0;left:14px;right:0;height:.5px;background:var(--s-border)}
.switch{width:32px;height:20px;border-radius:10px;background:color-mix(in srgb,var(--s-text) 16%,transparent);position:relative;flex:none}
.switch::after{content:"";position:absolute;left:2px;top:2px;width:16px;height:16px;border-radius:50%;background:#fff;box-shadow:0 .5px 1.5px rgba(0,0,0,.25)}
.switch.on{background:var(--accent)}.switch.on::after{left:14px}
.mono{font-family:var(--mono);font-size:11px;font-weight:500;letter-spacing:0}
.kbd{display:inline-grid;place-items:center;min-width:18px;height:18px;padding:0 4px;border-radius:5px;font-family:var(--mono);font-size:11px;font-weight:500;color:var(--s-text2);box-shadow:inset 0 0 0 .5px var(--s-border);background:var(--s-hover)}
.toast{display:inline-flex;align-items:center;gap:8px;height:36px;padding:0 14px;border-radius:12px;background:var(--surface);color:var(--s-text);font-size:13px;font-weight:500;box-shadow:0 0 0 .5px var(--s-border),0 6px 16px rgba(0,0,0,.18),0 1px 2px rgba(0,0,0,.08)}
.toast .ti{color:var(--accent);display:grid}
/* desktop: a code-drawn wallpaper (the same one the on-screen checks use) and a menu bar */
.desk{position:relative;width:1440px;height:900px;overflow:hidden;flex:none}
.wall{position:absolute;inset:0;background:linear-gradient(135deg,#1E2A5A 0%,#6A3D8F 40%,#E07A5F 75%,#F2C57C 100%)}
.wall i{position:absolute;border-radius:50%}
.menubar{position:absolute;left:0;right:0;top:0;height:28px;display:flex;align-items:center;gap:22px;padding:0 18px;color:#fff;
font-size:13px;font-weight:500;letter-spacing:-.05px;background:rgba(18,14,30,.18);-webkit-backdrop-filter:blur(24px) saturate(1.4);z-index:30}
.menubar b{font-weight:700}.menubar .r{margin-left:auto;display:flex;gap:16px;font-variant-numeric:tabular-nums}
/* a translucent themed window: blur → material tint → underlay (contrast floor) → theme layer → grain */
.tw{position:absolute;overflow:hidden;color:var(--text);font-size:13px}
.tbg{position:absolute;inset:0;-webkit-backdrop-filter:blur(36px) saturate(1.5);backdrop-filter:blur(36px) saturate(1.5)}
.tbg i{position:absolute;inset:0}
.tbg .m{background:var(--mat);opacity:var(--mat-o)}
.tbg .u{background:var(--underlay);opacity:var(--und)}
.tbg.more .u{opacity:var(--und-more)}
.tbg .l{background:var(--layer);opacity:var(--layer-o)}
.tbg .g{background-image:url(GRAIN);background-size:128px 128px;opacity:var(--grain-o)}
.fw{border-radius:24px;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.10),0 0 0 .5px rgba(0,0,0,.12),0 24px 70px rgba(0,0,0,.36),0 4px 14px rgba(0,0,0,.16)}
.fw.dark{box-shadow:inset 0 0 0 .5px rgba(255,255,255,.14),0 0 0 .5px rgba(0,0,0,.5),0 24px 70px rgba(0,0,0,.45),0 4px 14px rgba(0,0,0,.2)}
.bw{border-radius:16px;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.10),0 0 0 .5px rgba(0,0,0,.14),0 22px 60px rgba(0,0,0,.35)}
.caption{font-family:var(--mono);font-size:12px;color:#8a837e;height:56px;padding:26px 0 0 24px;letter-spacing:.2px;white-space:nowrap;overflow:hidden}
.caption b{color:#e9e6e2;font-weight:500}
""".replace("GRAIN", GRAIN)

CURSOR = ('<svg class="cursor" style="left:{x}px;top:{y}px" viewBox="0 0 17 24"><path d="M1.5 1.5v18.2l4.6-4.4 '
          '2.9 6.8 3.1-1.3-2.9-6.7h6.4z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>')


def page(title, body, extra_css=""):
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=1440">
<title>{title}</title>
<style>{CSS}{extra_css}</style></head>
<body>{body}</body></html>
"""


# ---------------------------------------------------------------------------------------------- the window

def item_row(it, level=0):
    """A sidebar row. it: dict(title, fav | icon, sel, hover, host, folder, audio, unloaded, bold)."""
    left_fi = 9 + 16 * level   # favicon x 17 (+16 per folder level), relative to the 8 pt plate inset
    left_tt = 35 + 16 * level  # title x 43
    cls = "plate" + (" sel" if it.get("sel") else "") + (" hover" if it.get("hover") else "") + (" unloaded" if it.get("unloaded") else "")
    if it.get("folder"):
        glyph = f'<span style="color:var(--accent)">{svg(I["folder"], 18, 1.7)}</span>'
    elif it.get("icon"):
        glyph = icon(it["icon"], 16, 1.9)
    else:
        glyph = fav(it["fav"], 18)
    title = it["title"]
    if it.get("bold") or it.get("folder"):
        title = f"<b>{title}</b>"
    aud = f'<span class="aud">{icon("speaker", 16, 1.7)}</span>' if it.get("audio") else ""
    host = f'<small>{it["host"]}</small>' if it.get("host") else ""
    right = 37 if it.get("hover") else 9
    close = f'<div class="close">{icon("x", 13, 2)}</div>' if it.get("hover") else ""
    extra = it.get("cls", "")
    return (f'<div class="row {extra}"><div class="{cls}"><div class="fi" style="left:{left_fi}px">{glyph}</div>'
            f'<div class="tt" style="left:{left_tt}px;right:{right}px"><span>{aud}{title}</span>{host}</div>{close}</div></div>')


def sidebar(sp, spaces, current, hover_header=False, show_clear=True, url_hover=False):
    favs = sp["favorites"]
    cols = {1: 1, 2: 2, 3: 3, 4: 4, 5: 3, 6: 3, 7: 4, 8: 4, 9: 3}.get(len(favs), 4)
    tiles = "".join(
        f'<div class="tile{" active" if f.get("active") else ""}">{fav(f["fav"], 20)}{"<i class=dot></i>" if f.get("unread") else ""}</div>'
        for f in favs)
    rows_fav = (len(favs) + cols - 1) // cols
    list_top = 90 + rows_fav * 47 + (rows_fav - 1) * 8 + 4 if favs else 86
    hdr_extra = ""
    if hover_header:
        p = sp["profile"]
        hdr_extra = (f'<div class="prof"><i style="background:{p["color"]}">{p["initial"]}</i>{p["name"]}</div>'
                     f'<div class="more">{icon("more", 16)}</div>')
    header = (f'<div class="space"><div class="plate{" hover" if hover_header else ""}"><div class="emo">{sp["emoji"]}</div>'
              f'<div class="nm">{sp["name"]}</div>{hdr_extra}</div></div>')
    pinned = ""
    for it in sp["pinned"]:
        pinned += item_row(it)
        for ch in it.get("children", []):
            pinned += item_row(ch, 1)
    divider = (f'<div class="divider{" clear" if show_clear else ""}"><div class="ln"></div>'
               f'{"<div class=clr>Clear</div>" if show_clear else ""}</div>')
    newtab = item_row({"title": "New Tab", "icon": "plus", "cls": "newtab"})
    today = "".join(item_row(it) for it in sp["today"])
    cells = "".join(
        f'<div class="c{" on" if i == current else ""}">{e if e else "<span class=d></span>"}</div>' for i, e in enumerate(spaces))
    url_btns = (f'<div class="ub">{icon("link", 14)}</div><div class="ub">{icon("sliders", 15)}</div>' if url_hover else "")
    return f"""<div class="sidebar">
  <div class="tl r"></div><div class="tl y"></div><div class="tl g"></div>
  <div class="hbtn" style="left:77px">{icon("sidebar", 18, 1.6)}</div>
  <div class="hbtn" style="left:122px">{icon("back", 17, 1.9)}</div>
  <div class="hbtn off" style="left:156px">{icon("forward", 17, 1.9)}</div>
  <div class="hbtn" style="left:190px">{icon("reload", 16, 1.9)}</div>
  <div class="url"><span class="host">{sp["host"]}</span>{url_btns}</div>
  <div class="favs" style="grid-template-columns:repeat({cols},1fr)">{tiles}</div>
  <div class="list" style="top:{list_top}px">{header}{pinned}{divider}{newtab}{today}</div>
  <div class="footer"><div class="fb" style="left:8px">{icon("archive", 17, 1.7)}</div>
    <div class="spaces">{cells}</div><div class="fb" style="right:8px">{icon("plus", 17, 1.8)}</div></div>
</div>"""


def window(sp, spaces, current, card_html, overlay="", hover_header=False, cursor=None, url_hover=False, show_clear=True):
    mode = sp.get("mode", "light")
    cur = CURSOR.format(x=cursor[0], y=cursor[1]) if cursor else ""
    return f"""<div class="win" style="{tvars(sp["theme"], mode)}">
<div class="bg"></div>
{sidebar(sp, spaces, current, hover_header=hover_header, show_clear=show_clear, url_hover=url_hover)}
<div class="card">{card_html}</div>
{overlay}{cur}
</div>"""


# ---------------------------------------------------------------------------------------------- content

PERSONAL = {
    "name": "Personal", "emoji": "🏡", "theme": "mint", "host": "papertrail.blog",
    "profile": {"name": "Personal", "initial": "A", "color": "#2F9E62"},
    "favorites": [{"fav": "gmail", "unread": True}, {"fav": "gcal"}, {"fav": "maps"}, {"fav": "youtube"}],
    "pinned": [
        {"title": "Budget 2027 – Google Sheets", "fav": "sheets"},
        {"title": "Lisbon, March", "folder": True, "children": [
            {"title": "Flights – compare dates", "fav": "google"},
            {"title": "Alfama loft · Airbnb", "fav": "airbnb", "unloaded": True},
        ]},
        {"title": "papertrail/web", "fav": "github"},
        {"title": "Landing page (dev)", "fav": "local", "host": "localhost:5173"},
    ],
    "today": [
        {"title": "The case for a calmer browser", "fav": "paper", "sel": True},
        {"title": "Lo-fi beats to focus to", "fav": "youtube", "audio": True},
        {"title": "New session – Claude", "fav": "claude", "hover": True},
        {"title": "Shared notes – Google Docs", "fav": "docs"},
    ],
}

WORK = {
    "name": "Work", "emoji": "💼", "theme": "ocean", "mode": "dark", "host": "linear.app",
    "profile": {"name": "Acme", "initial": "A", "color": "#2F6AF0"},
    "favorites": [{"fav": "gmail"}, {"fav": "gcal"}, {"fav": "slack", "unread": True}, {"fav": "linear"},
                  {"fav": "figma"}, {"fav": "notion"}],
    "pinned": [
        {"title": "Q4 roadmap", "fav": "notion"},
        {"title": "Launch", "folder": True, "children": [
            {"title": "Launch checklist", "fav": "linear"},
            {"title": "Press kit – Figma", "fav": "figma"},
        ]},
        {"title": "acme/web", "fav": "github"},
    ],
    "today": [
        {"title": "AIR-412 Sidebar springs", "fav": "linear", "sel": True},
        {"title": "Deployments – Vercel", "fav": "vercel"},
        {"title": "#design – Slack", "fav": "slack"},
    ],
}

SPACE_ICONS = ["🏡", "💼", "🦄"]

ARTICLE = """
<div class="art">
  <header><div class="logo">{logo}<span>Paper Trail</span></div>
    <nav><a>Essays</a><a>Tools</a><a>Archive</a><a class="sub">Subscribe</a></nav></header>
  <main>
    <p class="kicker">Essay · 7 min read</p>
    <h1>The case for a calmer browser</h1>
    <p class="dek">Tabs are not a to-do list. A browser that forgets politely, keeps what matters within reach and gets out of the way.</p>
    <div class="by"><span class="av"></span><div><b>Mara Lindqvist</b><span>November 4, 2026</span></div></div>
    <figure class="hero"><div class="sun"></div><div class="h1"></div><div class="h2"></div><div class="h3"></div></figure>
    <p>Every browser ships the same idea: a strip of tabs across the top that grows until it becomes noise. We open, we forget, we hoard. The calm alternative is not fewer features; it is a better default for forgetting.</p>
    <p>Pinned things stay. Everything else quietly archives after a day. The sidebar holds your work the way a desk does: what you need now in front of you, what you need often within reach.</p>
  </main>
</div>"""

ARTICLE_CSS = """
.art{height:100%;background:#FBFAF7;color:#22201d;font-family:var(--font);overflow:hidden}
.art header{display:flex;align-items:center;justify-content:space-between;height:64px;padding:0 48px;border-bottom:1px solid #ECE8E1}
.art .logo{display:flex;align-items:center;gap:10px;font-weight:650;font-size:16px;letter-spacing:-.2px}
.art nav{display:flex;gap:28px;font-size:14px;color:#6c665f;align-items:center}
.art nav .sub{color:#fff;background:#1F3A2E;padding:7px 14px;border-radius:999px;font-weight:500}
.art main{max-width:720px;margin:0 auto;padding:56px 0}
.art .kicker{font-size:13px;font-weight:600;color:#2E7D5B;letter-spacing:.2px;margin-bottom:14px}
.art h1{font-family:ui-serif,"New York",Georgia,serif;font-weight:600;font-size:46px;line-height:52px;letter-spacing:-.8px;margin-bottom:16px}
.art .dek{font-size:19px;line-height:29px;color:#5d5852;margin-bottom:26px}
.art .by{display:flex;gap:12px;align-items:center;margin-bottom:34px;font-size:13px}
.art .by div{display:flex;flex-direction:column;gap:2px}.art .by span{color:#8a847d}
.art .by .av{width:36px;height:36px;border-radius:50%;background:linear-gradient(135deg,#F2C79A,#C9775A)}
.art .hero{position:relative;height:300px;border-radius:14px;overflow:hidden;margin-bottom:34px;background:linear-gradient(180deg,#F6D9B8 0%,#F3B9A0 55%,#E89A86 100%)}
.art .hero .sun{position:absolute;left:58%;top:70px;width:110px;height:110px;border-radius:50%;background:#FFF1D6;opacity:.9}
.art .hero .h1{position:absolute;left:-10%;right:-10%;bottom:-120px;height:260px;border-radius:50%;background:#C98A7A}
.art .hero .h2{position:absolute;left:30%;right:-30%;bottom:-150px;height:260px;border-radius:50%;background:#9E6A68}
.art .hero .h3{position:absolute;left:-30%;right:35%;bottom:-190px;height:260px;border-radius:50%;background:#6E4F5B}
.art main>p:not(.kicker):not(.dek){font-family:ui-serif,"New York",Georgia,serif;font-size:19px;line-height:31px;color:#33302c;margin-bottom:20px}
"""

LINEAR_CSS = """
.lin{height:100%;background:#16171B;color:#E6E6EA;font-family:var(--font);display:flex;font-size:13px}
.lin aside{width:220px;border-right:1px solid #24252B;padding:16px 10px;color:#9A9AA5}
.lin aside .w{display:flex;gap:8px;align-items:center;color:#E6E6EA;font-weight:600;padding:4px 8px 14px}
.lin aside .w i{width:20px;height:20px;border-radius:5px;background:#5E6AD2;display:block}
.lin aside a{display:block;padding:6px 8px;border-radius:6px}.lin aside a.on{background:#24252B;color:#E6E6EA}
.lin aside h6{font-size:11px;font-weight:500;color:#6B6B76;padding:18px 8px 6px}
.lin section{flex:1;padding:22px 40px}
.lin .crumb{color:#7C7C88;font-size:12px;margin-bottom:22px}
.lin h1{font-size:24px;font-weight:600;letter-spacing:-.3px;margin-bottom:14px}
.lin .meta{display:flex;gap:8px;margin-bottom:26px}.lin .meta span{border:1px solid #2C2D34;border-radius:999px;padding:3px 10px;color:#B5B5BF;font-size:12px}
.lin p{color:#B9B9C3;line-height:21px;max-width:640px;margin-bottom:14px}
.lin .code{font-family:var(--mono);font-size:12px;background:#1D1E23;border:1px solid #2A2B31;border-radius:8px;padding:14px 16px;color:#C8C8D2;line-height:20px;max-width:640px;margin:8px 0 22px}
.lin .act{border-top:1px solid #24252B;padding-top:18px;max-width:640px;color:#8A8A95;font-size:12px;display:flex;flex-direction:column;gap:12px}
.lin .act b{color:#D6D6DE;font-weight:500}
"""

LINEAR = """
<div class="lin"><aside><div class="w"><i></i>Acme</div><a>Inbox</a><a>My issues</a><h6>Workspace</h6><a>Projects</a><a>Views</a>
<h6>Your teams</h6><a class="on">Airc</a><a>Web</a><a>Platform</a></aside>
<section><div class="crumb">Airc › Sidebar › AIR-412</div><h1>Sidebar springs match Arc's measurements</h1>
<div class="meta"><span>In progress</span><span>Motion</span><span>v1</span></div>
<p>Rows move on a 0.13 s spring with ζ 0.9; the Space pager settles critically damped in 0.19 s. Hover is a single frame, and a press activates the tab before release.</p>
<div class="code">AircSpring.row      // response 0.13, ζ 0.90<br>AircSpring.settle   // response 0.19, ζ 1.00 (ω ≈ 33)<br>AircSpring.reveal   // response 0.175, ζ 0.80</div>
<div class="act"><div><b>design</b> attached gallery.png</div><div><b>app</b> moved this to In progress · 2 h ago</div></div></section></div>
"""


# ---------------------------------------------------------------------------------------------- 2. command bar

CB_CSS = """
.cb{position:absolute;left:446.5px;top:281px;width:765px;border-radius:16px;background:var(--surface);color:var(--s-text);
box-shadow:0 0 0 .5px rgba(0,0,0,.10),0 20px 60px rgba(0,0,0,.26),0 2px 6px rgba(0,0,0,.10);overflow:hidden;z-index:20}
.cb .in{height:64px;display:flex;align-items:center;gap:14px;padding:0 22px;border-bottom:.5px solid var(--s-border)}
.cb .in .q{flex:1;font-size:18px;letter-spacing:-.2px;line-height:24px;white-space:nowrap}
.cb .in .q .ghost{color:var(--completion);background:var(--completion-bg);border-radius:2px}
.cb .in .q .caret{display:inline-block;width:1.5px;height:21px;background:var(--accent);vertical-align:-4px;margin:0 1px}
.cb .chip{display:flex;align-items:center;gap:6px;height:24px;padding:0 9px 0 4px;border-radius:12px;background:var(--s-hover);box-shadow:inset 0 0 0 .5px var(--s-border);font-size:12px;font-weight:500;color:var(--s-text2)}
.cb .chip i{width:18px;height:18px;border-radius:50%;display:grid;place-items:center;font-style:normal;font-size:11px}
.cb .res{padding:6px 8px 8px}
.cb .sec{font-size:11px;font-weight:500;letter-spacing:.06px;color:var(--s-text3);padding:10px 14px 6px}
.cb .it{height:40px;border-radius:10px;display:flex;align-items:center;gap:12px;padding:0 12px 0 14px}
.cb .it.on{background:var(--s-selected)}
.cb .it .ic{width:20px;height:20px;display:grid;place-items:center;color:var(--s-text2);flex:none}
.cb .it .t{font-size:14px;letter-spacing:-.08px;white-space:nowrap}
.cb .it .u{font-size:13px;color:var(--s-text3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
.cb .it .act{font-size:12px;font-weight:500;color:var(--s-text2);display:flex;align-items:center;gap:8px;white-space:nowrap}
.cb .it.on .act{color:var(--accent)}
"""


def build_command_bar():
    k = lambda s: f'<span class="kbd">{s}</span>'
    rows = f"""
<div class="sec">Tabs and Favorites</div>
<div class="it on"><div class="ic">{fav("gmail", 18)}</div><div class="t">Inbox (3) – Gmail</div><div class="u">mail.google.com</div><div class="act">Switch to Tab {k("↩")}</div></div>
<div class="it"><div class="ic">{fav("gcal", 18)}</div><div class="t">Google Calendar – Week of Nov 2</div><div class="u">calendar.google.com</div><div class="act"></div></div>
<div class="sec">Search</div>
<div class="it"><div class="ic">{icon("search", 16, 1.9)}</div><div class="t">gma</div><div class="u">Search Google</div><div class="act"></div></div>
<div class="it"><div class="ic">{icon("search", 16, 1.9)}</div><div class="t">gmail filters for newsletters</div><div class="u"></div><div class="act"></div></div>
<div class="sec">History</div>
<div class="it"><div class="ic">{icon("clock", 16, 1.8)}</div><div class="t">Settings – Gmail</div><div class="u">mail.google.com/mail/u/0/#settings/filters</div><div class="act"></div></div>
<div class="sec">Actions</div>
<div class="it"><div class="ic">{icon("space", 16, 1.8)}</div><div class="t">Go to Space “Work”</div><div class="u">Acme profile</div><div class="act">{k("⌃")}{k("2")}</div></div>
"""
    cb = f"""<div class="cb">
<div class="in"><span style="color:var(--s-text3);display:grid">{icon("search", 20, 1.9)}</span>
<div class="q">gma<span class="ghost">il.google.com</span></div>
<div class="chip"><i style="background:color-mix(in srgb,var(--accent) 18%,transparent)">🏡</i>Personal profile</div></div>
<div class="res">{rows}</div>
</div>"""
    sp = dict(PERSONAL)
    sp["today"] = [dict(t, sel=False, hover=False) for t in PERSONAL["today"]]
    sp["today"][0] = dict(sp["today"][0], sel=True)
    body = window(sp, SPACE_ICONS, 0, ARTICLE.format(logo=fav("paper", 26)), overlay=cb, show_clear=False)
    (HERE / "command-bar.html").write_text(page("Airc · command bar", body, ARTICLE_CSS + CB_CSS))


# ---------------------------------------------------------------------------------------------- 3. space switch

SS_CSS = """
.stage{width:1440px;height:900px;background:#141110;position:relative;overflow:hidden;color:#EAE6E2;font-family:var(--font)}
.stage>h1{position:absolute;left:56px;top:48px;font-family:var(--rounded);font-size:26px;font-weight:600;letter-spacing:-.45px}
.stage>.sub{position:absolute;left:56px;top:88px;font-size:15px;line-height:22px;color:#A39C96;max-width:760px}
.frame{position:absolute;top:176px;width:648px;height:405px;border-radius:12px;overflow:hidden;box-shadow:0 0 0 .5px rgba(255,255,255,.08),0 24px 60px rgba(0,0,0,.5)}
.frame .win{transform:scale(.45);transform-origin:0 0}
.frame.a{left:56px}.frame.b{left:736px}
.lab{position:absolute;top:600px;width:648px;display:flex;flex-direction:column;gap:6px}
.lab.a{left:56px}.lab.b{left:736px}
.lab b{font-size:15px;font-weight:600;letter-spacing:-.1px}
.lab span{font-family:var(--mono);font-size:12px;color:#8F8883}
.flow{position:absolute;left:56px;right:56px;top:700px;display:grid;grid-template-columns:repeat(4,1fr);gap:16px}
.flow div{border-radius:12px;background:#1C1917;box-shadow:inset 0 0 0 .5px rgba(255,255,255,.08);padding:16px 18px}
.flow h6{font-size:13px;font-weight:600;margin-bottom:6px;color:#EAE6E2}
.flow p{font-size:12px;line-height:18px;color:#A39C96}
.flow code{font-family:var(--mono);font-size:11px;color:#D9D3CD}
.arrow{position:absolute;left:704px;top:362px;width:32px;height:32px;border-radius:50%;background:#2A2522;display:grid;place-items:center;color:#EAE6E2;box-shadow:0 0 0 .5px rgba(255,255,255,.1)}
"""


def build_space_switch():
    a = window(PERSONAL, SPACE_ICONS, 0, ARTICLE.format(logo=fav("paper", 26)))
    b = window(WORK, SPACE_ICONS, 1, LINEAR, hover_header=True, cursor=(120, 266))
    body = f"""<div class="stage">
<h1>Switching Spaces</h1>
<p class="sub">⌃2, a click on 💼 or a two-finger swipe over the sidebar. One window, two profiles: the colour, the Favorites, the cookies and the Command Bar's history all change together.</p>
<div class="frame a">{a}</div><div class="arrow">{icon("arrow", 16, 2)}</div><div class="frame b">{b}</div>
<div class="lab a"><b>🏡 Personal</b><span>Mint · light · Personal profile · 4 Favorites</span></div>
<div class="lab b"><b>💼 Work</b><span>Ocean · dark · Acme profile · 6 Favorites · header hovered: profile pill + •••</span></div>
<div class="flow">
<div><h6>Pages slide</h6><p>Sidebar contents page sideways; footer and window buttons stay put.<br><code>AircSpring.settle · 0.19 s · ζ 1</code></p></div>
<div><h6>Colour leads</h6><p>The whole window re-tints at once, well ahead of the slide; a swipe blends by visible fraction.<br><code>AircCurve.themeCrossfade · 90 ms</code></p></div>
<div><h6>Favorites swap</h6><p>Different profile, so the tiles swap in one frame (Arc). Same profile: tiles don't move.<br><code>4 → 6 tiles · 1 row each</code></p></div>
<div><h6>Readable at once</h6><p>Text is legible within ~130 ms while motion finishes. No haptic on a normal switch.<br><code>input → first frame ≤ 16 ms</code></p></div>
</div></div>"""
    (HERE / "space-switch.html").write_text(page("Airc · switching Spaces", body, ARTICLE_CSS + LINEAR_CSS + SS_CSS))


# ---------------------------------------------------------------------------------------------- desktop

def wallpaper():
    """The calm dusk wallpaper from the on-screen checks (Onscreen.swift's BusyWallpaperView(calm:))."""
    H, W = 900, 1440
    blobs = [(0.2, 0.3, 0.35, "rgba(46,134,171,.55)"), (0.75, 0.7, 0.3, "rgba(246,174,45,.5)"), (0.55, 0.15, 0.25, "rgba(51,101,138,.6)")]
    out = ""
    for x, y, r, c in blobs:
        rr = r * H
        out += f'<i style="left:{x * W - rr:.0f}px;top:{(1 - y) * H - rr:.0f}px;width:{2 * rr:.0f}px;height:{2 * rr:.0f}px;background:{c}"></i>'
    return f'<div class="wall">{out}</div>'


MENUBAR = ('<div class="menubar"><b>Airc</b><span>File</span><span>Edit</span><span>View</span><span>Spaces</span>'
           '<span>Window</span><span>Help</span><span class="r"><span>Wed 4 Nov</span><span>21:40</span></span></div>')


def desk(inner, caption):
    return f'<div class="caption"><b>{caption[0]}</b>{caption[1]}</div><div class="desk">{wallpaper()}{MENUBAR}{inner}</div>'


def tbg(more=False):
    return f'<div class="tbg{" more" if more else ""}"><i class="m"></i><i class="u"></i><i class="l"></i><i class="g"></i></div>'


# ---------------------------------------------------------------------------------------------- 1b. window, translucent

def build_window():
    first = window(PERSONAL, SPACE_ICONS, 0, ARTICLE.format(logo=fav("paper", 26)), cursor=(170, 548))
    # The same window over the desktop, translucent: Subtle (the default) in Mint, More in the default theme, dark.
    def floating_browser(sp, mode, more, left, top, w, h, card):
        sb = sidebar(sp, SPACE_ICONS, 0)
        return (f'<div class="tw bw{" dark" if mode == "dark" else ""}" style="{tvars(sp["theme"], mode)};left:{left}px;top:{top}px;width:{w}px;height:{h}px">'
                f'{tbg(more)}{sb}<div class="card">{card}</div></div>')
    sub = desk(floating_browser(PERSONAL, "light", False, 60, 64, 1320, 800, ARTICLE.format(logo=fav("paper", 26))),
               ("Translucency · Subtle (default)", " — Mint: the underlay floors at 0.70, so about 10 % of the blurred desktop reaches the sidebar; the page card stays opaque"))
    dark_work = dict(WORK, theme="paper", mode="dark")
    more = desk(floating_browser(dark_work, "dark", True, 60, 64, 1320, 800, LINEAR),
                ("Translucency · More", " — default theme, dark: underlay 0.32, about 24 % of the blurred desktop shows; text still meets 4.5 : 1 over a white or saturated backdrop"))
    # Favorites follow Arc's column rule: one Favorite fills the row, two share it, five go 3 + 2.
    cols = ""
    for i, (n, note) in enumerate([(1, "one Favorite fills the row"), (2, "two share it"), (3, "three share it"), (5, "five: 3 + 2, never a lone tile on a 4-wide row")]):
        sp = dict(PERSONAL, favorites=PERSONAL["favorites"][:min(n, 4)] + ([{"fav": "github"}] if n == 5 else []), pinned=PERSONAL["pinned"][:1],
                  today=PERSONAL["today"][:2])
        cols += (f'<div class="col" style="left:{56 + i * 262}px"><div class="sbx" style="height:490px;{tvars("mint", "light")}"><div class="bg"></div>'
                 f'{sidebar(sp, SPACE_ICONS, 0, show_clear=False)}</div><div class="lbl"><b>{n} Favorite{"s" if n > 1 else ""}</b>{note}</div></div>')
    favs = frame("Favorites · the column rule", " — AircMetrics.Favorites.columns: the most columns (≤ 4) that keep tiles ≥ 47 pt, then the fewest that need no more rows",
                 stage(cols, "One Favorite is not a bug", "Arc fills the row with a single Favorite and splits it for two or three. Tiles are 47 pt tall, 8 pt apart, radius 10."))
    body = first + sub + more + favs
    (HERE / "window.html").write_text(page("Airc · window", body, ARTICLE_CSS + LINEAR_CSS + STAGE_CSS))


# ---------------------------------------------------------------------------------------------- 4. onboarding (ON-5)

OB_CSS = """
.ob-cap{position:absolute;left:0;right:0;bottom:22px;text-align:center;font-family:var(--mono);font-size:12px;color:rgba(255,255,255,.62)}
.fw .sidebar .list{overflow:hidden;-webkit-mask-image:linear-gradient(to bottom,#000 86%,transparent)}
.obc{position:absolute;left:228px;top:10px;right:10px;bottom:10px;border-radius:14px;background:var(--surface);color:var(--s-text);padding:32px;
display:flex;flex-direction:column;box-shadow:var(--card-shadow)}
.dots{display:flex;gap:6px;margin-bottom:24px}.dots i{width:6px;height:6px;border-radius:3px;background:color-mix(in srgb,var(--s-text) 14%,transparent)}
.dots i.done{background:color-mix(in srgb,var(--s-text) 30%,transparent)}.dots i.on{width:20px;background:var(--accent)}
.obc h2{font-family:var(--rounded);font-size:26px;line-height:32px;font-weight:600;letter-spacing:-.45px}
.obc .lead{font-size:15px;line-height:22px;color:var(--s-text2);margin-top:8px;letter-spacing:-.1px}
.obc .content{margin-top:24px}
.obc .acts{margin-top:auto;display:flex;gap:8px;align-items:center}
.obc .acts .sp{flex:1}
.found{display:flex;align-items:center;gap:14px;padding:12px 14px;border-radius:12px;background:var(--group-bg);box-shadow:inset 0 0 0 .5px var(--s-border)}
.found b{font-size:14px;font-weight:600;letter-spacing:-.1px}.found .mono{color:var(--s-text2);margin-top:3px}
.chk{width:18px;height:18px;border-radius:5px;background:var(--accent);color:var(--on-accent);display:grid;place-items:center;flex:none}
.chk.off{background:transparent;box-shadow:inset 0 0 0 1px color-mix(in srgb,var(--s-text) 25%,transparent)}
.gr .tx{flex:1;min-width:0}.gr .tx div{font-size:13px}.gr .tx small{display:block;font-size:12px;color:var(--s-text2);margin-top:2px;line-height:16px}
.workpill{position:absolute;left:8px;right:8px;top:10px;height:26px;display:flex;align-items:center;gap:8px;padding:0 10px;border-radius:13px;
background:var(--tile);color:var(--text2);font-size:11px;font-weight:500}
.workpill .bar{flex:1;height:4px;border-radius:2px;background:color-mix(in srgb,var(--text) 14%,transparent);overflow:hidden}
.workpill .bar i{display:block;height:100%;width:62%;background:var(--accent);border-radius:2px}
.pav{width:32px;height:32px;border-radius:50%;display:grid;place-items:center;font-size:15px;flex:none}
.schip{display:inline-flex;align-items:center;gap:5px;height:22px;padding:0 8px;border-radius:11px;font-size:12px;font-weight:500;background:var(--s-hover);box-shadow:inset 0 0 0 .5px var(--s-border);margin-right:4px}
.acct{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--s-text2);white-space:nowrap}
.acct i{width:18px;height:18px;border-radius:50%;display:grid;place-items:center;font-style:normal;font-size:10px;font-weight:700;color:#fff}
.note{display:flex;gap:10px;align-items:flex-start;margin-top:12px;font-size:12px;line-height:17px;color:var(--s-text2)}
.sw{display:grid;grid-template-columns:repeat(6,36px);gap:12px 18px}
.sw .disc{width:36px;height:36px;border-radius:50%;position:relative;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.10);overflow:hidden}
.sw .on{box-shadow:0 0 0 2px var(--surface),0 0 0 4px var(--accent)}
.seg{display:flex;padding:2px;border-radius:9px;background:var(--s-hover);box-shadow:inset 0 0 0 .5px var(--s-border);height:30px;flex:1}
.seg div{flex:1;display:flex;align-items:center;justify-content:center;gap:6px;border-radius:7px;font-size:12px;font-weight:500;color:var(--s-text2)}
.seg .on{background:var(--btn2);color:var(--s-text);box-shadow:0 .5px 1.5px rgba(0,0,0,.12),inset 0 0 0 .5px var(--s-border)}
.slider{height:20px;position:relative;flex:1}
.slider .tr{position:absolute;left:0;right:0;top:8px;height:4px;border-radius:2px;background:color-mix(in srgb,var(--s-text) 12%,transparent)}
.slider .fl{position:absolute;left:0;top:8px;height:4px;border-radius:2px;background:var(--accent)}
.slider .kn{position:absolute;top:0;width:20px;height:20px;border-radius:50%;background:#fff;box-shadow:0 .5px 2px rgba(0,0,0,.3),0 0 0 .5px rgba(0,0,0,.06);margin-left:-10px}
.ctl{display:flex;align-items:center;gap:14px;font-size:13px;height:30px}
.ctl .k{width:84px;color:var(--s-text2);font-size:12px;font-weight:500}
.hero{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:48px}
.hero h1{font-family:var(--rounded);font-size:34px;line-height:40px;font-weight:600;letter-spacing:-.7px;color:var(--text);margin-top:26px}
.hero p{font-size:15px;line-height:22px;color:var(--text2);margin-top:10px;max-width:440px;letter-spacing:-.1px}
.hero .acts{display:flex;gap:10px;margin-top:30px}
.hero .foot{position:absolute;bottom:20px;left:0;right:0;font-family:var(--mono);font-size:11px;color:var(--text3)}
.bloom{position:absolute;inset:0;background:
radial-gradient(60% 70% at 18% 20%,rgba(180,240,218,.95),transparent 70%),
radial-gradient(55% 65% at 85% 18%,rgba(255,211,227,.95),transparent 70%),
radial-gradient(60% 70% at 25% 95%,rgba(196,224,255,.95),transparent 70%),
radial-gradient(55% 60% at 88% 92%,rgba(226,208,255,.95),transparent 70%),rgba(255,255,255,.84)}
.bloom::after{content:"";position:absolute;inset:0;background-image:url(GRAIN);background-size:128px 128px;opacity:.10}
.member{position:relative;width:360px;height:226px;border-radius:18px;overflow:hidden;color:#fff;text-align:left;flex:none;
box-shadow:0 26px 60px rgba(30,20,60,.35),0 2px 6px rgba(0,0,0,.18),inset 0 0 0 .5px rgba(255,255,255,.25);transform:rotate(-2deg)}
.member .mbg{position:absolute;inset:0;background:linear-gradient(135deg,#53CA9F 0%,#2F6AF0 50%,#7A4CF0 78%,#E0559F 100%)}
.member .mbg::after{content:"";position:absolute;inset:0;background-image:url(GRAIN);background-size:128px 128px;opacity:.5}
.member .shine{position:absolute;inset:0;background:linear-gradient(115deg,rgba(255,255,255,.28) 0%,rgba(255,255,255,0) 40%)}
.member .in{position:absolute;inset:0;padding:20px 22px;display:flex;flex-direction:column}
.member .top{display:flex;justify-content:space-between;align-items:center}
.member .top span{font-family:var(--mono);font-size:12px;opacity:.85}
.member .nm{margin-top:auto;font-family:var(--rounded);font-size:28px;font-weight:600;letter-spacing:-.6px}
.member .row2{display:flex;justify-content:space-between;align-items:flex-end;margin-top:4px}
.member .row2 span{font-family:var(--mono);font-size:11px;opacity:.85;line-height:15px}
.member .em{font-size:16px;letter-spacing:3px}
.ghost{position:absolute;border:1px dashed rgba(255,255,255,.55);pointer-events:none}
.ghost b{position:absolute;top:-22px;left:0;font-family:var(--mono);font-size:11px;font-weight:500;color:rgba(255,255,255,.8);white-space:nowrap}
"""

WIN_W, WIN_H = 760, 540
WIN_X = (1440 - WIN_W) // 2
WIN_Y = round(28 + (900 - 28 - WIN_H) * 0.45)   # optical centre: 55 % of the free space below (AircMetrics.Onboarding)


def dots(step, total=5):
    return '<div class="dots">' + "".join(
        f'<i class="{"on" if i == step else "done" if i < step else ""}"></i>' for i in range(1, total + 1)) + "</div>"


def preview(sp, spaces, current, hover_header=False, pill=""):
    """The live sidebar preview: the real sidebar at 1:1 on the window's theme, without the window buttons
    (there are none)."""
    html = sidebar(sp, spaces, current, hover_header=hover_header, show_clear=False)
    html = re.sub(r'\s*<div class="tl [ryg]"></div>', "", html)
    html = re.sub(r'\s*<div class="hbtn[^"]*" style="left:\d+px">.*?</svg></div>', "", html)
    return html.replace('<div class="sidebar">', '<div class="sidebar">' + pill, 1)


def ob_window(theme, mode, inner, more=False, x=WIN_X, y=WIN_Y, w=WIN_W, h=WIN_H, extra="", bg=None):
    background = bg if bg is not None else tbg(more)
    return (f'<div class="tw fw{" dark" if mode == "dark" else ""}" style="{tvars(theme, mode)};left:{x}px;top:{y}px;width:{w}px;height:{h}px{extra}">'
            f'{background}{inner}</div>')


def card(step, title, lead, content, acts):
    return (f'<div class="obc">{dots(step)}<h2>{title}</h2><p class="lead">{lead}</p>'
            f'<div class="content">{content}</div><div class="acts">{acts}</div></div>')


def member_card():
    return (f'<div class="member"><div class="mbg"></div><div class="shine"></div><div class="in">'
            f'<div class="top">{app_icon(38, shadow=False)}<span>No. 000 001</span></div>'
            f'<div class="nm">Alex</div>'
            f'<div class="row2"><span>Member since 4 Nov 2026<br>Methodical Explorer</span><span class="em">🏡💼🦄🚀</span></div></div></div>')


def build_onboarding():
    frames = []
    cap = lambda s: f'<div class="ob-cap">{s}</div>'

    # 1. Welcome
    welcome = f"""<div class="hero">{app_icon(104)}<h1>Welcome to Airc</h1>
<p>The calm, Arc-style browser for your Mac. Your Spaces, tabs and logins move over in about a minute.</p>
<div class="acts"><button class="btn lg primary" style="padding:0 22px">Get started {icon("arrow", 15, 2.2)}</button></div>
<div class="foot">Open source · Apache-2.0</div></div>"""
    frames.append(desk(ob_window("paper", "light", welcome, bg='<div class="tbg"><i class="m"></i></div><div class="bloom"></div>')
                       + cap("760 × 540 · 24 pt corners · no title bar, no traffic lights · drag anywhere · Return starts"),
                       ("1 · Welcome", " — a floating card over the desktop (ON-5): the app icon, SF Pro Rounded title, the icon's pastels as the bloom")))

    # 2. Import from Arc
    k = lambda on: f'<div class="chk{"" if on else " off"}">{icon("check", 12, 3) if on else ""}</div>'
    imp = card(2, "Bring your Arc with you.",
               "We found Arc on this Mac. Your Spaces come over exactly as they are, profiles and all.",
               f"""<div class="found">{fav("arc", 34)}<div style="flex:1"><b>Arc 1.171</b><div class="mono">6 Spaces · 3 profiles · 84 tabs</div></div>
<button class="btn sm secondary">Back up first</button></div>
<div class="group" style="margin-top:12px">
<div class="gr">{k(True)}<div class="tx"><div>Spaces, pinned tabs and folders</div></div><span class="mono" style="color:var(--s-text3)">84</span></div>
<div class="gr">{k(True)}<div class="tx"><div>Favorites, per profile</div></div><span class="mono" style="color:var(--s-text3)">12</span></div>
<div class="gr">{k(True)}<div class="tx"><div>Logins and saved passwords</div><small>macOS asks for your Mac password once.</small></div><span class="mono" style="color:var(--s-text3)">1,204</span></div>
</div>""",
               '<button class="btn lg plain">Start fresh</button><span class="sp"></span><button class="btn lg primary">Import everything</button>')
    pill = '<div class="workpill">Reading Arc <span class="bar"><i></i></span></div>'
    sb = preview(dict(PERSONAL, today=PERSONAL["today"][:2]), ["🏡", "💼", "🦄", "🚀", "", "😺"], 0, pill=pill)
    frames.append(desk(ob_window("sky", "light", sb + imp) + cap("the preview on the left is the real sidebar at 1:1, rebuilding as the import runs · Esc goes back"),
                       ("2 · Import from Arc", " — the window mirrors the browser it becomes: sidebar on the theme, the step on a card where the page will be")))

    # 3. Spaces and profiles
    def prof(emoji, color, name, chips, acct):
        return (f'<div class="gr"><div class="pav" style="background:{color}">{emoji}</div><div class="tx">'
                f'<div style="font-weight:600;font-size:13px">{name}</div><div style="margin-top:5px">{chips}</div></div>{acct}</div>')
    chip = lambda e, n: f'<span class="schip">{e} {n}</span>'
    signed = lambda c, i, mail: f'<div class="acct"><i style="background:{c}">{i}</i>{mail}</div>'
    spaces_html = card(3, "Spaces and accounts.",
                       "Each Arc profile becomes a real profile with its own logins.",
                       f"""<div class="group">
{prof("🏡", "color-mix(in srgb,#53CA9F 30%,transparent)", "Personal", chip("🏡", "Personal") + chip("🦄", "Studio"), signed("#2F9E62", "A", "alex@example.com"))}
{prof("💼", "color-mix(in srgb,#2F6AF0 22%,transparent)", "Acme", chip("💼", "Work"), signed("#2F6AF0", "A", "alex@acme.example"))}
{prof("🚀", "color-mix(in srgb,#F0642A 22%,transparent)", "Launch", chip("🚀", "Launch"), '<button class="btn sm secondary">' + fav("google", 13) + ' Sign in</button>')}
</div>
<div class="note"><span style="color:var(--s-text3);display:grid">{icon("lock", 15, 1.8)}</span><span>Next, macOS asks for your Mac password once, to unlock Arc's saved logins.</span></div>""",
                       '<button class="btn lg plain">Back</button><span class="sp"></span><button class="btn lg secondary">Skip logins</button><button class="btn lg primary">Continue</button>')
    sb = preview(dict(PERSONAL, theme="lilac", today=PERSONAL["today"][:1]), ["🏡", "💼", "🦄", "🚀"], 0, hover_header=True)
    frames.append(desk(ob_window("lilac", "light", sb + spaces_html) + cap("header hovered in the preview: a Space shows its profile pill"),
                       ("3 · Spaces and profiles", " — one Google account per profile, avatars from the imported cookies")))

    # 4. Make it yours
    sw = ""
    for pid in ["paper", "mint", "sky", "lilac", "peach", "lemon", "ocean", "grape", "forest", "ember", "slate", "midnight"]:
        t = THEMES[pid]["light"]
        stops = ", ".join(f'{st["color"]} {st["location"] * 100:.0f}%' for st in t["gradient"])
        layer = f'<i style="position:absolute;inset:0;background:linear-gradient(135deg,{stops});opacity:{t["layerOpacity"]:.3f}"></i>'
        sw += f'<span class="disc{" on" if pid == "peach" else ""}" style="background:{t["underlay"]}" title="{pid}">{layer}</span>'
    seg = lambda items, on: '<div class="seg">' + "".join(f'<div class="{"on" if i == on else ""}">{x}</div>' for i, x in enumerate(items)) + "</div>"
    theme_html = card(4, "Make it yours.", "Pick a colour for each Space. The window re-tints as you choose.",
                      f"""<div style="display:flex;gap:4px;margin-bottom:18px">{chip("🏡", "Personal")}<span class="schip" style="background:var(--s-selected);box-shadow:inset 0 0 0 1px var(--accent);color:var(--s-text)">💼 Work</span>{chip("🦄", "Studio")}</div>
<div class="sw">{sw}</div>
<div style="display:flex;flex-direction:column;gap:10px;margin-top:20px">
<div class="ctl"><span class="k">Appearance</span>{seg([icon("auto", 13, 1.8) + " Auto", icon("sun", 13, 1.8) + " Light", icon("moon", 13, 1.8) + " Dark"], 0)}</div>
<div class="ctl"><span class="k">Intensity</span><div class="slider"><div class="tr"></div><div class="fl" style="width:81%"></div><div class="kn" style="left:81%"></div></div></div>
<div class="ctl"><span class="k">Translucency</span>{seg(["Off", "Subtle", "More"], 1)}</div>
</div>""",
                      '<button class="btn lg plain">Back</button><span class="sp"></span><button class="btn lg primary">Looks right</button>')
    sb = preview(dict(WORK, theme="peach", mode="light", today=WORK["today"][:2], favorites=WORK["favorites"][:4]), ["🏡", "💼", "🦄"], 1)
    frames.append(desk(ob_window("peach", "light", sb + theme_html) + cap("Translucency (Off · Subtle · More) is new: the desktop shows through the theme, text keeps its contrast floor"),
                       ("4 · Make it yours", " — presets, appearance, intensity, translucency; the window and the preview follow every change")))

    # 5. Done
    done = f"""<div class="hero">{member_card()}<h1 style="margin-top:34px">Welcome to Airc, Alex.</h1>
<p>Here's your card. Your Spaces, tabs and logins are ready.</p>
<div class="acts"><button class="btn lg secondary">{icon("share", 15, 1.9)} Share card</button><button class="btn lg primary">Open Airc</button></div></div>"""
    frames.append(desk(ob_window("paper", "light", done, bg='<div class="tbg"><i class="m"></i></div><div class="bloom"></div>')
                       + cap("the member card wears the app icon · the same bloom as Welcome · Open Airc starts the expansion"),
                       ("5 · Done", " — the member card (Arc's) on the welcome bloom, so the flow opens and closes in one key")))

    # 6. Expanding into the browser window (one frame, ≈ 55 % of the way)
    start = (WIN_X, WIN_Y, WIN_W, WIN_H)
    end = (40, 50, 1360, 800)
    p_ = 0.55
    x, y, w, h = (round(a_ + (b_ - a_) * p_) for a_, b_ in zip(start, end))
    radius = 24 + (16 - 24) * p_
    inner = (f'<div style="opacity:.55">{sidebar(dict(PERSONAL, today=PERSONAL["today"][:3]), SPACE_ICONS, 0, show_clear=False)}</div>'
             f'<div class="card" style="opacity:.5;background:#FBFAF7"></div>'
             f'<div style="position:absolute;left:50%;top:50%;width:760px;height:540px;margin:-270px 0 0 -380px;opacity:.12">{done}</div>')
    ghosts = f'<div class="ghost" style="left:{end[0]}px;top:{end[1]}px;width:{end[2]}px;height:{end[3]}px;border-radius:16px;z-index:1"><b>to: the first browser window, r 16</b></div>'
    frames.append(desk(ob_window("paper", "light", inner, x=x, y=y, w=w, h=h, extra=f";border-radius:{radius:.1f}px;z-index:2") + ghosts
                       + cap("from 760 × 540 r 24 · AircSpring.expand 0.40 s ζ 0.88 · card content gone by 120 ms, browser content fades in · Reduce Motion: 150 ms cross-fade"),
                       ("6 · Into the browser", " — one frame of the expansion, about 55 % of the way: the room grows, the sidebar and the page card arrive")))

    body = '<div style="width:1440px;margin:0 auto;padding-bottom:40px">' + "".join(frames) + "</div>"
    (HERE / "onboarding.html").write_text(page("Airc · onboarding", body, OB_CSS.replace("GRAIN", GRAIN)))


# ---------------------------------------------------------------------------------------------- 5. profiles (SP-10…15)

# Demo identities. Photos are code-drawn stand-ins for a Google account picture (no real faces).
PROFILE_COLORS = ["#4C7DF0", "#2F9E62", "#14A3A3", "#8B5CF6", "#E0559F", "#E5484D", "#F0782A", "#E8B21E", "#6B6560"]
PROFILES = {
    "personal": {"name": "Personal", "color": "#2F9E62", "photo": ("#F3D9B1", "#E7A86B", "#5B3A29", "#F6E7D3"), "email": "alex@example.com"},
    "acme": {"name": "Acme", "color": "#4C7DF0", "photo": ("#C9DAF5", "#8FB0E8", "#2B2622", "#E9C4A4"), "email": "alex@acme.example"},
    "studio": {"name": "Studio", "color": "#8B5CF6", "emoji": "🎨"},
    "freelance": {"name": "Freelance", "color": "#14A3A3", "emoji": "🪴"},
}


def avatar(pid, size=16, ring=None):
    """AircProfileAvatar: the Google photo once signed in, otherwise the emoji on a pastel of the profile colour
    (OKLab mix with white 0.72), with a 0.5 pt inner hairline. `ring` draws a cut-out ring in that colour."""
    p = PROFILES[pid]
    rs = f"box-shadow:0 0 0 1.5px {ring};" if ring else ""
    if "photo" in p:
        bg, bg2, hair, skin = p["photo"]
        uid = f"ph{pid}{size}"
        body = (f'<svg width="{size}" height="{size}" viewBox="0 0 32 32" style="display:block;border-radius:50%">'
                f'<defs><linearGradient id="{uid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{bg}"/>'
                f'<stop offset="1" stop-color="{bg2}"/></linearGradient></defs><rect width="32" height="32" fill="url(#{uid})"/>'
                f'<path d="M5 33c1.2-6.6 5.8-9.6 11-9.6s9.8 3 11 9.6z" fill="{hair}" opacity=".88"/>'
                f'<circle cx="16" cy="14" r="6.4" fill="{skin}"/><path d="M9.4 13.2c.2-4.8 3.1-7.4 6.8-7.4 3.8 0 6.6 2.7 6.5 7.6-1.3-2.6-3.9-3.6-6.6-3.6-2.8 0-5.3 1-6.7 3.4z" fill="{hair}"/></svg>')
        return f'<span class="av" style="width:{size}px;height:{size}px;{rs}">{body}</span>'
    return (f'<span class="av" style="width:{size}px;height:{size}px;font-size:{size * 0.56:.1f}px;'
            f'background:color-mix(in oklab,{p["color"]} 28%,#fff);{rs}">{p["emoji"]}</span>')


PROF_CSS = """
.dots{display:flex;gap:6px;margin-bottom:24px}.dots i{width:6px;height:6px;border-radius:3px;background:color-mix(in srgb,var(--s-text) 14%,transparent)}
.dots i.done{background:color-mix(in srgb,var(--s-text) 30%,transparent)}.dots i.on{width:20px;background:var(--accent)}
.av{display:inline-grid;place-items:center;border-radius:50%;flex:none;overflow:hidden;position:relative;line-height:1}
.av::after{content:"";position:absolute;inset:0;border-radius:50%;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.10)}
/* --- Create a Space (in the sidebar, SP-10) --- */
.cs{position:absolute;left:14px;right:14px;display:flex;flex-direction:column;align-items:stretch}
.cs .ill{height:64px;display:grid;place-items:center}
.cs h3{margin-top:14px;text-align:center;font-size:15px;line-height:20px;font-weight:600;letter-spacing:-.1px;color:var(--text)}
.cs .subt{margin:4px auto 0;max-width:184px;text-align:center;font-size:12px;line-height:16px;color:var(--text2)}
.cs .nf{margin-top:20px;height:36px;border-radius:10px;background:var(--field);display:flex;align-items:center;gap:8px;padding:0 10px 0 4px;font-size:13px;color:var(--text)}
.cs .nf.focus{box-shadow:inset 0 0 0 1.5px var(--accent),0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}
.cs .nf .ib{width:28px;height:28px;border-radius:7px;background:var(--tile);display:grid;place-items:center;font-size:16px;color:var(--text3);flex:none}
.cs .nf .ph{color:var(--text3)}
.cs .nf .car{display:inline-block;width:1.5px;height:16px;background:var(--accent);vertical-align:-3px;margin-left:1px}
.cs .rw{margin-top:8px;height:36px;border-radius:10px;background:var(--field);display:flex;align-items:center;padding:0 7px 0 12px;font-size:13px;color:var(--text2);gap:8px}
.cs .rw.hover{background:color-mix(in srgb,var(--text) 9%,transparent)}
.cs .rw .k{flex:1;white-space:nowrap}
.pill{display:inline-flex;align-items:center;gap:5px;height:22px;padding:0 6px 0 3px;border-radius:11px;background:var(--tile-hover);font-size:12px;font-weight:500;color:var(--text);white-space:nowrap}
.pill .cv{color:var(--text2);display:grid;margin-left:1px}
.tchip{width:30px;height:20px;border-radius:10px;position:relative;overflow:hidden;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.14),0 0 0 1.5px rgba(255,255,255,.7)}
.cs .go{margin-top:20px;height:36px;border-radius:8px;background:var(--accent);color:var(--on-accent);display:grid;place-items:center;font-size:13px;font-weight:600;letter-spacing:-.04px;
box-shadow:inset 0 1px 0 rgba(255,255,255,.20),0 1px 1px color-mix(in srgb,var(--accent) 35%,transparent)}
.cs .go.off{opacity:.4;box-shadow:none}
.cs .cancel{margin-top:6px;height:30px;display:grid;place-items:center;font-size:13px;font-weight:500;color:var(--text2)}
.spaces .c{position:relative}
.spaces .c .pd{position:absolute;right:6px;bottom:6px;width:6px;height:6px;border-radius:50%;box-shadow:0 0 0 1.5px var(--bgsolid)}
.spaces .c.new{opacity:1;filter:none}
.spaces .c.new::before{content:"";position:absolute;inset:3px 4px;border-radius:9px;background:var(--tile)}
.spaces .c.new span{position:relative}
/* --- profile indicator in the Space header (SP-15) --- */
.space .plate.fx{display:flex;align-items:center;padding:0 6px 0 5px}
.space .plate.fx .emo,.space .plate.fx .nm,.space .plate.fx .more{position:static}
.space .plate.fx .emo{flex:none}
.space .plate.fx .nm{flex:1;min-width:0;margin-left:2px;white-space:nowrap;overflow:hidden;-webkit-mask-image:linear-gradient(to right,#000 calc(100% - 20px),transparent)}
.space .plate.fx .more{flex:none;margin-left:2px}
.space .ind{flex:none;margin-left:4px;display:flex;align-items:center;gap:5px;height:22px;padding:0 4px 0 3px;border-radius:11px;font-size:11px;font-weight:500;color:var(--text3);letter-spacing:.06px;white-space:nowrap}
.space .ind.hov{background:var(--tile);color:var(--text2);padding-right:5px}
/* --- native menu (NSMenu, macOS 26) --- */
.menu{position:absolute;z-index:40;width:236px;padding:5px;border-radius:12px;background:rgba(246,245,243,.985);
box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 12px 32px rgba(0,0,0,.20),0 2px 6px rgba(0,0,0,.08);color:#1d1a18;font-size:13px}
.menu .mi{height:38px;border-radius:7px;display:flex;align-items:center;gap:8px;padding:0 10px 0 6px}
.menu .mi.one{height:26px}
.menu .mi .ck{width:14px;display:grid;place-items:center;color:#1d1a18;flex:none}
.menu .mi .tx{display:flex;flex-direction:column;min-width:0;line-height:16px}
.menu .mi .tx small{font-size:11px;line-height:14px;color:rgba(29,26,24,.55)}
.menu .mi.hl{background:#3D73E9;color:#fff}.menu .mi.hl .ck,.menu .mi.hl small{color:rgba(255,255,255,.85)}
.menu .sep{height:1px;margin:5px 10px;background:rgba(0,0,0,.10)}
.menu .plusg{width:20px;height:20px;border-radius:50%;display:grid;place-items:center;box-shadow:inset 0 0 0 1px currentColor;opacity:.75}
/* --- dialogs: the Create Profile card, centred over the page (SP-11) --- */
.scrim{position:absolute;left:228px;top:10px;right:10px;bottom:10px;border-radius:6px;background:rgba(10,8,6,.26);z-index:30}
.dlg{position:absolute;z-index:31;width:520px;border-radius:16px;background:var(--surface);color:var(--s-text);padding:28px 28px 22px;
box-shadow:0 0 0 .5px rgba(0,0,0,.10),0 24px 64px rgba(0,0,0,.26),0 3px 8px rgba(0,0,0,.10)}
.dlg .dots{margin-bottom:18px}
.dlg h2{font-size:20px;line-height:26px;font-weight:600;letter-spacing:-.3px}
.dlg p{font-size:13px;line-height:19px;color:var(--s-text2);margin-top:8px;letter-spacing:-.04px}
.dlg .q{font-size:13px;font-weight:500;color:var(--s-text);margin-top:18px;margin-bottom:8px}
.dlg .acts{display:flex;gap:8px;align-items:center;margin-top:26px}.dlg .acts .sp{flex:1}
.dlg .acts .hint{font-family:var(--mono);font-size:11px;color:var(--s-text3)}
.idrow{display:flex;gap:16px;align-items:center}
.idrow .big{width:64px;height:64px;border-radius:50%;display:grid;place-items:center;font-size:32px;flex:none;position:relative;
box-shadow:inset 0 0 0 .5px rgba(0,0,0,.10),0 0 0 4px var(--surface),0 0 0 5px var(--s-border)}
.idrow .big .ed{position:absolute;right:-2px;bottom:-2px;width:22px;height:22px;border-radius:50%;background:var(--btn2);display:grid;place-items:center;color:var(--s-text2);
box-shadow:0 0 0 .5px var(--field-border),0 1px 2px rgba(0,0,0,.12)}
.pick{margin-top:16px;display:flex;flex-direction:column;gap:10px}
.pick .lab{font-size:12px;font-weight:500;color:var(--s-text2);width:44px;flex:none}
.pick .line{display:flex;align-items:center;gap:10px}
.emos{display:flex;gap:2px}
.emos span{width:30px;height:30px;border-radius:8px;display:grid;place-items:center;font-size:17px}
.emos span.on{background:var(--s-selected);box-shadow:inset 0 0 0 1.5px var(--accent)}
.emos span.more{color:var(--s-text2);font-size:13px;background:var(--s-hover)}
.cols{display:flex;gap:9px;padding-left:4px}
.cols i{width:20px;height:20px;border-radius:50%;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.12)}
.cols i.on{box-shadow:0 0 0 2px var(--surface),0 0 0 3.5px currentColor}
.tiles{display:flex;flex-wrap:wrap;gap:14px 10px;margin-top:18px}
.stile{width:84px;display:flex;flex-direction:column;align-items:center;gap:7px}
.stile .tb{width:84px;height:64px;border-radius:12px;position:relative;overflow:hidden;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.10)}
.stile .tb .bg{border-radius:12px}
.stile .tb .e{position:absolute;inset:0;display:grid;place-items:center;font-size:24px}
.stile .tb .mini{position:absolute;left:8px;top:9px;width:22px;display:flex;flex-direction:column;gap:3px}
.stile .tb .mini i{height:3px;border-radius:2px;background:var(--text);opacity:.18}
.stile .cb{position:absolute;right:6px;top:6px;width:18px;height:18px;border-radius:50%;background:rgba(255,255,255,.85);box-shadow:inset 0 0 0 1px rgba(0,0,0,.18);display:grid;place-items:center}
.stile.on .cb{background:var(--sel-accent);box-shadow:0 0 0 1.5px #fff;color:#fff}
.stile.on .tb{box-shadow:0 0 0 2px var(--surface),0 0 0 4px var(--sel-accent)}
.stile .n{font-size:12px;font-weight:500;color:var(--s-text);white-space:nowrap}
.stile .f{display:flex;align-items:center;gap:4px;font-size:11px;color:var(--s-text3);margin-top:-4px;white-space:nowrap}
.sumline{margin-top:16px;font-size:12px;line-height:16px;color:var(--s-text2);display:flex;gap:8px;align-items:center}
/* --- theme picker popover (Arc ref §4.1: 357 × 509, radius 20) --- */
.tp{position:absolute;z-index:35;width:357px;height:509px;border-radius:20px;background:var(--surface);
box-shadow:0 0 0 .5px rgba(0,0,0,.12),0 20px 48px rgba(0,0,0,.22),0 2px 4px rgba(0,0,0,.06);padding:8.5px;color:var(--s-text)}
.tp .arr{position:absolute;left:-7px;width:14px;height:14px;transform:rotate(45deg);background:var(--surface);box-shadow:-.5px .5px 0 rgba(0,0,0,.12);border-radius:2px}
.tp .fld{position:relative;width:340px;height:340px;border-radius:14px;background:var(--s-hover);overflow:hidden;padding:0;box-shadow:inset 0 0 0 .5px var(--s-border)}
.tp .fld .dg{position:absolute;inset:0;background:radial-gradient(circle at 50% 50%,color-mix(in srgb,var(--s-text) 4%,transparent),transparent 70%)}
.tp .disc{position:absolute;left:0;top:0}
.tp .h{position:absolute;border-radius:50%;box-shadow:0 0 0 3px #fff,0 2px 8px rgba(0,0,0,.35);transform:translate(-50%,-50%)}
.tp .link{position:absolute;height:2px;background:rgba(255,255,255,.75);transform-origin:0 50%;box-shadow:0 0 2px rgba(0,0,0,.25)}
.tp .bar{display:flex;align-items:center;gap:8px;margin-top:10px;height:30px}
.tp .rb{width:28px;height:28px;border-radius:50%;display:grid;place-items:center;background:var(--s-hover);box-shadow:inset 0 0 0 .5px var(--s-border);color:var(--s-text2)}
.tp .cnt{display:flex;gap:4px;margin:0 4px}.tp .cnt i{width:6px;height:6px;border-radius:50%;background:color-mix(in srgb,var(--s-text) 16%,transparent)}.tp .cnt i.on{background:var(--s-text2)}
.tp .seg3{margin-left:auto;display:flex;padding:2px;border-radius:9px;background:var(--s-hover);box-shadow:inset 0 0 0 .5px var(--s-border)}
.tp .seg3 span{width:34px;height:24px;border-radius:7px;display:grid;place-items:center;color:var(--s-text2)}
.tp .seg3 span.on{background:var(--seg-on);color:var(--s-text);box-shadow:0 .5px 1.5px rgba(0,0,0,.14),inset 0 0 0 .5px var(--s-border)}
.tp .sw9{display:flex;align-items:center;gap:6px;margin-top:10px;height:30px}
.tp .sw9 .pg{width:18px;color:var(--s-text3);display:grid;place-items:center}
.tp .sw9 i{width:24px;height:24px;border-radius:50%;position:relative;overflow:hidden;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.12);flex:none}
.tp .sw9 i.on{box-shadow:0 0 0 2px var(--surface),0 0 0 3.5px var(--s-text2)}
.tp .lo{display:flex;align-items:center;gap:12px;margin-top:10px;height:50px}
.tp .lo .wv{flex:1;position:relative;height:44px}
.tp .lo .lb{position:absolute;left:0;top:-1px;font-size:11px;font-weight:500;color:var(--s-text3)}
.tp .dial{width:46px;height:46px;position:relative;flex:none}
"""


def theme_chip(tid, w=30, h=20, mode="light"):
    t = THEMES[tid][mode]
    stops = ", ".join(f'{s["color"]} {s["location"] * 100:.0f}%' for s in t["gradient"])
    return (f'<span class="tchip" style="width:{w}px;height:{h}px;background:{t["underlay"]}">'
            f'<i style="position:absolute;inset:0;background:linear-gradient(135deg,{stops});opacity:{t["layerOpacity"]:.3f}"></i></span>')


def spaces_illustration(themes=("mint", "sky", "peach")):
    """Three Space pages fanned out like cards: code-drawn, symmetric, in real theme colours."""
    cards = ""
    for i, (tid, rot, dx) in enumerate(zip(themes, (-9, 0, 9), (-22, 0, 22))):
        t = THEMES[tid]["light"]
        stops = ", ".join(f'{s["color"]} {s["location"] * 100:.0f}%' for s in t["gradient"])
        z = 2 if i == 1 else 1
        dy = 0 if i == 1 else 5
        lines = "".join(f'<i style="display:block;height:3px;border-radius:2px;margin-top:{4 if k else 0}px;width:{w}px;background:rgba(20,17,15,.16)"></i>'
                        for k, w in enumerate((22, 16, 19, 12)))
        cards += (f'<div style="position:absolute;left:{30 + dx}px;top:{6 + dy}px;width:36px;height:50px;border-radius:8px;z-index:{z};'
                  f'transform:rotate({rot}deg);background:{t["underlay"]};overflow:hidden;box-shadow:0 0 0 .5px rgba(0,0,0,.10),0 3px 8px rgba(0,0,0,.14)">'
                  f'<i style="position:absolute;inset:0;background:linear-gradient(135deg,{stops});opacity:{t["layerOpacity"]:.3f}"></i>'
                  f'<div style="position:absolute;left:6px;top:8px">{lines}</div>'
                  f'<i style="position:absolute;left:12px;right:12px;bottom:5px;height:3px;border-radius:2px;background:rgba(20,17,15,.22)"></i></div>')
    return f'<div style="position:relative;width:96px;height:64px">{cards}</div>'


def footer(cells, current, plus_on=False):
    """cells: list of (emoji, profile id or None, extra class)."""
    out = ""
    for i, (e, pid, extra) in enumerate(cells):
        dot = f'<i class="pd" style="background:{PROFILES[pid]["color"]}"></i>' if pid else ""
        inner = f"<span>{e}</span>" if e else "<span class=d></span>"
        out += f'<div class="c{" on" if i == current else ""} {extra}">{inner}{dot}</div>'
    plus = f'<div class="fb" style="right:8px;{"background:var(--hover)" if plus_on else ""}">{icon("plus", 17, 1.8)}</div>'
    return (f'<div class="footer"><div class="fb" style="left:8px">{icon("archive", 17, 1.7)}</div>'
            f'<div class="spaces">{out}</div>{plus}</div>')


HEADER_BUTTONS = ('<div class="tl r"></div><div class="tl y"></div><div class="tl g"></div>'
                  f'<div class="hbtn" style="left:77px">{icon("sidebar", 18, 1.6)}</div>'
                  f'<div class="hbtn" style="left:122px">{icon("back", 17, 1.9)}</div>'
                  f'<div class="hbtn off" style="left:156px">{icon("forward", 17, 1.9)}</div>'
                  f'<div class="hbtn" style="left:190px">{icon("reload", 16, 1.9)}</div>')

MULTI_FOOTER = [("🏡", "personal", ""), ("💼", "acme", ""), ("🎨", "studio", ""), ("✈️", "personal", "")]


def create_card(top=196, name="", profile="personal", theme="sky", emoji="🌱", focus=True, hover_row=None, leaving=None):
    """The Create a Space card (SP-10). leaving: progress 0…1 of the bottom-up exit (parts sink 8 pt and fade in
    150 ms, staggered 0 / 80 / 130 ms from the bottom)."""
    caret = '<span class="car"></span>' if focus else ""
    nm = f'{name}{caret}' if name else f'{caret}<span class="ph">Space name</span>'
    groups = [
        f'<div class="ill">{spaces_illustration()}</div><h3>Create a Space</h3>'
        f'<p class="subt">Give each part of your life its own tabs.</p>',
        f'<div class="nf{" focus" if focus else ""}"><span class="ib">{emoji or icon("plus", 14, 2)}</span><span>{nm}</span></div>'
        f'<div class="rw{" hover" if hover_row == "profile" else ""}"><span class="k">Profile</span>'
        f'<span class="pill">{avatar(profile, 16)}{PROFILES[profile]["name"]}<span class="cv">{icon("chevdown", 11, 2.2)}</span></span></div>'
        f'<div class="rw{" hover" if hover_row == "theme" else ""}"><span class="k">Choose a Theme</span>{theme_chip(theme)}'
        f'<span style="color:var(--text3);display:grid">{icon("forward", 13, 2.2)}</span></div>',
        f'<div class="go{"" if name else " off"}">Create Space</div><div class="cancel">Cancel</div>',
    ]
    if leaving is not None:
        out = ""
        for g, delay in zip(groups, (0.130, 0.080, 0.0)):   # bottom group leaves first
            t = min(1, max(0, (leaving * 0.280 - delay) / 0.150))
            e = 1 - (1 - t) ** 3
            out += f'<div style="opacity:{1 - e:.2f};transform:translateY({8 * e:.1f}px)">{g}</div>'
        return f'<div class="cs" style="top:{top}px">{out}</div>'
    return f'<div class="cs" style="top:{top}px">{"".join(groups)}</div>'


def create_sidebar(card_html, cells, current, plus_on=True, height=None):
    style = f' style="height:{height}px"' if height else ""
    return f'<div class="sidebar"{style}>{HEADER_BUTTONS}{card_html}{footer(cells, current, plus_on)}</div>'


def themed_window(tid, mode, sidebar_html, card_html, overlay=""):
    return (f'<div class="win" style="{tvars(tid, mode)}"><div class="bg"></div>{sidebar_html}'
            f'<div class="card">{card_html}</div>{overlay}</div>')


def frame(title, rest, inner):
    return f'<div class="caption"><b>{title}</b>{rest}</div>{inner}'


def stage(inner, title, sub):
    return (f'<div class="pstage"><h1>{title}</h1><p class="sub">{sub}</p>{inner}</div>')


STAGE_CSS = """
.pstage{width:1440px;height:900px;background:#141110;position:relative;overflow:hidden;color:#EAE6E2;font-family:var(--font);flex:none}
.pstage>h1{position:absolute;left:56px;top:44px;font-family:var(--rounded);font-size:26px;font-weight:600;letter-spacing:-.45px}
.pstage>.sub{position:absolute;left:56px;top:84px;font-size:15px;line-height:22px;color:#A39C96;max-width:1100px}
.pstage .col{position:absolute;top:140px}
.pstage .lbl{font-family:var(--mono);font-size:11px;color:#8F8883;margin-top:10px;line-height:16px;max-width:440px}
.pstage .col .sbx+.lbl{max-width:228px}
.pstage .lbl b{color:#E9E6E2;font-weight:500;font-family:var(--font);font-size:13px;display:block;margin-bottom:2px}
.pstage .sbx{position:relative;width:228px;overflow:hidden;border-radius:10px;box-shadow:0 0 0 .5px rgba(255,255,255,.08),0 18px 40px rgba(0,0,0,.45)}
.pstage .notes{position:absolute;display:flex;flex-direction:column;gap:12px}
.pstage .notes div{border-radius:12px;background:#1C1917;box-shadow:inset 0 0 0 .5px rgba(255,255,255,.08);padding:14px 16px}
.pstage .notes h6{font-size:13px;font-weight:600;margin-bottom:5px;color:#EAE6E2}
.pstage .notes p{font-size:12px;line-height:18px;color:#A39C96}
.pstage .notes code{font-family:var(--mono);font-size:11px;color:#D9D3CD}
.zoom{position:relative;transform-origin:0 0}
.meas{position:absolute;font-family:var(--mono);font-size:10px;color:#F2C57C;white-space:nowrap}
.meas.v{border-left:1px solid #F2C57C}.meas.h{border-top:1px solid #F2C57C}
"""


def empty_space_page(tid, mode, emoji, name, pid):
    p = PROFILES[pid]
    return (f'<div style="height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;background:var(--surface);color:var(--s-text);text-align:center">'
            f'<div style="font-size:40px;line-height:48px">{emoji}</div>'
            f'<div style="margin-top:6px;font-size:20px;line-height:26px;font-weight:600;letter-spacing:-.3px">{name}</div>'
            f'<div style="margin-top:8px;font-size:13px;color:var(--s-text2);display:flex;gap:6px;align-items:center">{avatar(pid, 16)} {p["name"]} profile · its own logins, history and extensions</div>'
            f'<div style="margin:20px 0 24px;display:flex;gap:4px;align-items:center;font-size:13px;color:var(--s-text3)"><span class="kbd">⌘</span><span class="kbd">T</span><span style="margin-left:4px">New Tab</span></div></div>')


def sign_in_card(state="rest"):
    """SP-12: at the top of a new profile's Today list. 112 pt tall, `selectedFill` card with the row shadow."""
    if state == "signed":
        return (f'<div class="sic"><div class="sih">{fav("gmail", 16)}{fav("gcal", 16)}<b>Add to Favorites?</b>'
                f'<span class="x">{icon("x", 11, 2.2)}</span></div>'
                f'<p>Pin Gmail and Calendar for this account to Favorites.</p>'
                f'<div class="sib"><span class="btn sm primary">Add both</span><span class="btn sm plain">Not now</span></div></div>')
    hov = ' style="background:color-mix(in srgb,var(--accent) 88%,#fff)"' if state == "hover" else ""
    return (f'<div class="sic"><div class="sih">{fav("google", 16)}<b>Sign in to Google</b><span class="x">{icon("x", 11, 2.2)}</span></div>'
            f'<p>A fresh profile. Sign in once and Google stays signed in here.</p>'
            f'<div class="sib"><span class="btn sm primary"{hov}>Sign in</span><span class="btn sm plain">Not now</span></div></div>')


SIGNIN_CSS = """
.sic{margin:4px 8px 6px;height:112px;border-radius:12px;background:var(--selected);box-shadow:var(--sel-shadow),0 0 0 .5px color-mix(in srgb,var(--text) 6%,transparent);padding:11px 12px 0;position:relative;color:var(--text)}
.sic .sih{display:flex;align-items:center;gap:7px;height:18px}
.sic .sih b{font-size:13px;font-weight:600;letter-spacing:-.04px}
.sic .x{position:absolute;right:7px;top:7px;width:20px;height:20px;border-radius:6px;display:grid;place-items:center;color:var(--text3)}
.sic p{font-size:12px;line-height:16px;color:var(--text2);margin-top:5px;padding-right:4px}
.sic .sib{display:flex;gap:4px;margin-top:9px}
.sic .btn.sm{height:24px}
.sic .btn.plain{color:var(--text2)}
.ring{display:block;animation:none}
"""


def loading_ring(size=14, color="var(--text2)", track="color-mix(in srgb,var(--text) 14%,transparent)", phase=0):
    """AircLoadingRing in the favicon slot: 14 pt, 1.75 pt stroke, a 0.28 arc on an ink 0.14 track."""
    r = (size - 1.75) / 2
    c = 2 * 3.14159 * r
    return (f'<svg class="ring" width="{size}" height="{size}" viewBox="0 0 {size} {size}" style="transform:rotate({phase}deg)">'
            f'<circle cx="{size / 2}" cy="{size / 2}" r="{r:.2f}" fill="none" stroke="{track}" stroke-width="1.75"/>'
            f'<circle cx="{size / 2}" cy="{size / 2}" r="{r:.2f}" fill="none" stroke="{color}" stroke-width="1.75" stroke-linecap="round" '
            f'stroke-dasharray="{c * 0.28:.2f} {c:.2f}"/></svg>')


def space_header(emoji, name, pid=None, hover=False, fade=False, multi=True, condensed=False):
    """The Space header with the profile indicator (SP-15) as a row: icon, name (fades out, never under the
    indicator), indicator, then ••• on hover."""
    ind = ""
    if pid and multi:
        p = PROFILES[pid]
        cv = f'<span style="display:grid;color:var(--text3)">{icon("chevdown", 10, 2.2)}</span>' if hover else ""
        label = "" if condensed else p["name"]
        ind = f'<div class="ind{" hov" if hover else ""}">{avatar(pid, 16)}{label}{cv}</div>'
    more = f'<div class="more">{icon("more", 16)}</div>' if hover else ""
    return (f'<div class="space"><div class="plate fx{" hover" if hover else ""}"><div class="emo">{emoji}</div>'
            f'<div class="nm">{name}</div>{ind}{more}</div></div>')


def build_profiles():
    frames = []
    cells_new = MULTI_FOOTER + [("🌱", None, "new")]
    art = ARTICLE.format(logo=fav("paper", 26))

    # 1. Create a Space, filled in
    sb = create_sidebar(create_card(name="Side project", theme="sky"), cells_new, 4)
    w = themed_window("sky", "light", sb, art, CURSOR.format(x=150, y=505))
    frames.append(frame("1 · Create a Space", " — SP-10: the card fills a new sidebar page; the whole window already wears the chosen theme. Profile and theme are one compact row each", w))

    # 2. States board
    cols = ""
    states = [
        ("Just opened", "name focused, Create Space at 0.4", dict(name="", hover_row=None)),
        ("Name typed", "Create Space live · Return creates and switches", dict(name="Side project")),
        ("Pointer on Profile", "row hover ink 0.09 · the pill opens the menu", dict(name="Side project", hover_row="profile", focus=False)),
        ("Leaving (90 ms in)", "bottom-up: 0 / 80 / 130 ms, each 150 ms, sinks 8 pt", dict(name="Side project", focus=False, leaving=0.32)),
    ]
    for i, (t, sub, kw) in enumerate(states):
        sbh = create_sidebar(create_card(top=150, theme="sky", **kw), cells_new, 4, height=640)
        cols += (f'<div class="col" style="left:{56 + i * 262}px"><div class="sbx" style="height:640px;{tvars("sky", "light")}"><div class="bg"></div>{sbh}</div>'
                 f'<div class="lbl"><b>{t}</b>{sub}</div></div>')
    notes = """<div class="notes" style="left:1104px;top:140px;width:280px">
<div><h6>Only four things</h6><p>Icon + name, Profile, Theme, Create. No profile list, no inline profile fields, no delete buttons: those live in Settings → Profiles and the Space menu.</p></div>
<div><h6>Rows</h6><p>200 × 36, radius 10, <code>fieldFill</code>. Label <code>body</code> in <code>textSecondary</code>; control at the trailing edge, 7 pt in.</p></div>
<div><h6>Profile pill</h6><p>22 pt, avatar 16 + name 12 medium + chevron. <code>tileHoverFill</code>. Opens the native profile menu under it.</p></div>
<div><h6>Create Space</h6><p>36 pt, radius 8, the <b>new theme's accent</b> (Airc blue on the default theme, as Arc). 0.4 until a name is typed.</p></div>
<div><h6>Esc · Cancel</h6><p>Cancel pages back to the previous Space on <code>AircSpring.settle</code>; nothing is created.</p></div></div>"""
    frames.append(frame("2 · Create a Space, states", " — the same card at 1:1 in each state, on the Sky theme it previews",
                        stage(cols + notes, "Create a Space", "Arc 1.171's card and copy. The theme row shows the current theme as a chip; the profile row is a pill. Everything else is gone.")))

    # 3. Profile pill menu
    menu = f"""<div class="menu" style="left:88px;top:434px">
<div class="mi"><span class="ck">{icon("check", 12, 2.6)}</span>{avatar("personal", 22)}<span class="tx">Personal<small>alex@example.com</small></span></div>
<div class="mi"><span class="ck"></span>{avatar("acme", 22)}<span class="tx">Acme<small>alex@acme.example</small></span></div>
<div class="mi one"><span class="ck"></span>{avatar("studio", 22)}<span class="tx">Studio</span></div>
<div class="sep"></div>
<div class="mi one hl"><span class="ck"></span><span class="plusg">{icon("plus", 12, 2.2)}</span><span class="tx">New Profile…</span></div>
</div>"""
    sb = create_sidebar(create_card(name="Side project", theme="sky", focus=False, hover_row="profile"), cells_new, 4)
    w = themed_window("sky", "light", sb, art, menu + CURSOR.format(x=170, y=560))
    frames.append(frame("3 · The Profile menu", " — SP-11: a native NSMenu under the pill. Avatar (Google photo once signed in, else emoji on colour), name, the account as subtitle, ✓, divider, New Profile…", w))

    # 4. Create Profile, step 1 (from the Space menu: two steps)
    studio = {
        "name": "Studio", "emoji": "🎨", "theme": "lilac", "host": "figma.com",
        "profile": PROFILES["studio"] | {"initial": "S"},
        "favorites": [{"fav": "figma"}, {"fav": "notion"}, {"fav": "docs"}],
        "pinned": [{"title": "Brand refresh – Figma", "fav": "figma"}, {"title": "Moodboard", "fav": "notion"}],
        "today": [{"title": "Type specimens – Google Docs", "fav": "docs", "sel": True}, {"title": "Colour studies", "fav": "figma"}],
    }
    em = "".join(f'<span class="{"on" if e == "🪴" else ""}">{e}</span>' for e in ["🪴", "🌱", "⚡️", "🍊", "🎧", "📚", "🧪", "🏄", "🐙"])
    em += '<span class="more">•••</span>'
    cols_html = "".join(f'<i class="{"on" if c == "#14A3A3" else ""}" style="background:{c};color:{c}"></i>' for c in PROFILE_COLORS)
    step1_tpl = f"""<div class="dlg" style="left:569px;top:178px">{dots(1, 2)}
<h2>Create a new Profile</h2>
<p>Each Profile keeps its own logins, history, saved passwords and extensions, so the Spaces that use it stay apart from the rest. Keep work and home signed in side by side.</p>
<div class="q">What do you want to call this Profile?</div>
<div class="idrow"><div class="big" style="background:color-mix(in oklab,#14A3A3 28%,#fff)">🪴</div>
<div style="flex:1"><div class="field focus">Freelance<span style="display:inline-block;width:1.5px;height:16px;background:var(--accent);margin-left:-6px"></span></div>
<div style="font-size:12px;color:var(--s-text3);margin-top:6px">Shown in the Space header and the Profile menu.</div></div></div>
<div class="pick"><div class="line"><span class="lab">Icon</span><div class="emos">{em}</div></div>
<div class="line"><span class="lab">Colour</span><div class="cols">{cols_html}</div></div></div>
<div class="acts"><span class="sp"></span><button class="btn lg secondary">Cancel</button><button class="btn lg primary">Next</button></div></div>"""
    step1 = step1_tpl
    sb_html = sidebar(studio, ["🏡", "💼", "🎨", "✈️"], 2)
    sb_html = sb_html.replace('<div class="space"><div class="plate"><div class="emo">🎨</div><div class="nm">Studio</div></div></div>',
                              space_header("🎨", "Studio", "studio"))
    sb_html = re.sub(r'<div class="footer">.*', lambda m: footer(MULTI_FOOTER, 2, False) + "\n</div>", sb_html, flags=re.S)
    w = (f'<div class="win" style="{tvars("lilac", "light")}"><div class="bg"></div>{sb_html}<div class="card">{art}</div>'
         f'<div class="scrim"></div>{step1}</div>')
    frames.append(frame("4 · Create Profile, step 1", " — SP-11: Arc's two-step card, centred over the page. From Create a Space it is one step: no dots, and the button reads Create Profile", w))

    # 5. Step 2: Which Spaces
    def stile(tid, mode, e, n, pid, on):
        t = tvars(tid, mode)
        acc = "var(--accent)"
        chk = icon("check", 10, 3) if on else ""
        return (f'<div class="stile{" on" if on else ""}" style="--sel-accent:{acc}"><div class="tb" style="{t}"><div class="bg"></div>'
                f'<div class="mini"><i></i><i style="width:70%"></i><i style="width:85%"></i></div><div class="e">{e}</div><div class="cb">{chk}</div></div>'
                f'<div class="n">{n}</div><div class="f">{avatar(pid, 12)} {PROFILES[pid]["name"]}</div></div>')
    tiles = (stile("mint", "light", "🏡", "Personal", "personal", False) + stile("ocean", "dark", "💼", "Work", "acme", False)
             + stile("lilac", "light", "🎨", "Studio", "studio", True) + stile("peach", "light", "✈️", "Travel", "personal", False)
             + stile("lemon", "light", "🤝", "Clients", "personal", True) + stile("midnight", "dark", "📚", "Reading", "personal", False)
             + stile("forest", "dark", "🏄", "Weekend", "personal", False))
    step2 = f"""<div class="dlg" style="left:569px;top:150px">{dots(2, 2)}
<h2>Choose the Spaces for this Profile</h2>
<p>In the new Profile these Spaces start clean: you’ll sign in to sites again and add your passwords and extensions there. You can move them back to their old Profile at any time.</p>
<div class="tiles">{tiles}</div>
<div class="sumline">{avatar("freelance", 16)}<span><b style="font-weight:600;color:var(--s-text)">Freelance</b> · Studio and Clients move over. Their pinned tabs and folders stay; open tabs reload.</span></div>
<div class="acts"><button class="btn lg plain">Back</button><span class="sp"></span><button class="btn lg secondary">Cancel</button><button class="btn lg primary">Create Profile</button></div></div>"""
    w = (f'<div class="win" style="{tvars("lilac", "light")}"><div class="bg"></div>{sb_html}<div class="card">{art}</div>'
         f'<div class="scrim"></div>{step2}</div>')
    frames.append(frame("5 · Create Profile, step 2", " — Space tiles drawn in each Space's own theme, as checkboxes; the current profile under each. Past five Spaces they wrap, left-aligned. Skipped when started from Create a Space", w))

    # 6. Theme picker
    import colorsys, math

    def hpos(hexc):
        r, g, b = (int(hexc[i:i + 2], 16) / 255 for i in (1, 3, 5))
        h, l, s = colorsys.rgb_to_hls(r, g, b)
        ang = h * 2 * math.pi            # clockwise from the right (screen y grows down)
        rad = (l - 0.12) / 0.8 * 160
        return 170 + rad * math.cos(ang), 170 + rad * math.sin(ang)
    def picker(c1, c2, preset_ids, selected, mode, left=242, top=200, arrow_y=456):
      (x1, y1), (x2, y2) = hpos(c1), hpos(c2)
      # The field as a grid of dots, each in the colour at its point: hue is the angle (clockwise from the right),
      # lightness grows from the centre to the edge, saturation 1. Dots near a handle grow, like Arc's.
      disc_dots = ""
      for gy in range(-156, 157, 12):
          for gx in range(-156, 157, 12):
              rr = math.hypot(gx, gy)
              if rr > 156:
                  continue
              hh = (math.atan2(gy, gx) / (2 * math.pi)) % 1
              r_, g_, b_ = colorsys.hls_to_rgb(hh, 0.12 + 0.8 * rr / 160, 1)
              near = min(math.hypot(170 + gx - x1, 170 + gy - y1), math.hypot(170 + gx - x2, 170 + gy - y2))
              dr = 3.0 + 1.6 * max(0, 1 - near / 60)
              disc_dots += f'<circle cx="{170 + gx}" cy="{170 + gy}" r="{dr:.2f}" fill="#{int(r_ * 255):02x}{int(g_ * 255):02x}{int(b_ * 255):02x}"/>'

      ln = math.hypot(x2 - x1, y2 - y1)
      ang = math.degrees(math.atan2(y2 - y1, x2 - x1))
      presets = ""
      for pid in preset_ids:
          t = THEMES[pid][mode]
          stops = ", ".join(f'{st["color"]} {st["location"] * 100:.0f}%' for st in t["gradient"])
          presets += (f'<i class="{"on" if pid == selected else ""}" style="background:{t["underlay"]}"><b style="position:absolute;inset:0;'
                      f'background:linear-gradient(135deg,{stops});opacity:{t["layerOpacity"]:.3f}"></b></i>')
      wave_pts = " ".join(f"{x:.1f},{22 + 6 * math.sin(x / 252 * 7 * 2 * math.pi):.2f}" for x in range(0, 253, 2))
      kx = 252 * 0.81
      dial = ""
      for k in range(24):
          a = -math.pi / 2 + k / 24 * 2 * math.pi
          on = k / 24 <= 0.25
          dial += f'<circle cx="{23 + 18 * math.cos(a):.2f}" cy="{23 + 18 * math.sin(a):.2f}" r="{1.9 if on else 1.4}" fill="currentColor" opacity="{0.75 if on else 0.22}"/>'
      a = -math.pi / 2 + 0.25 * 2 * math.pi
      dial += f'<circle cx="{23 + 10 * math.cos(a):.2f}" cy="{23 + 10 * math.sin(a):.2f}" r="3" fill="currentColor"/>'
      tp = f"""<div class="tp" style="left:{left}px;top:{top}px"><div class="arr" style="top:{arrow_y - top - 7}px"></div>
  <div class="fld"><div class="dg"></div><svg class="disc" width="340" height="340" viewBox="0 0 340 340">{disc_dots}</svg>
  <div class="link" style="left:{x1:.1f}px;top:{y1:.1f}px;width:{ln:.1f}px;transform:rotate({ang:.1f}deg)"></div>
  <div class="h" style="left:{x2:.1f}px;top:{y2:.1f}px;width:26px;height:26px;background:{c2}"></div>
  <div class="h" style="left:{x1:.1f}px;top:{y1:.1f}px;width:44px;height:44px;background:{c1}"></div></div>
  <div class="bar"><span class="rb">{svg('<path d="M6 12h12"/>', 13, 2.2)}</span><span class="rb">{icon("plus", 13, 2.2)}</span>
  <span class="cnt"><i class="on"></i><i class="on"></i><i></i></span>
  <span class="seg3"><span class="{"" if mode == "dark" else "on"}">{icon("auto", 14, 1.8)}</span><span>{icon("sun", 14, 1.8)}</span><span class="{"on" if mode == "dark" else ""}">{icon("moon", 14, 1.8)}</span></span></div>
  <div class="sw9"><span class="pg">{icon("back", 13, 2.2)}</span>{presets}<span class="pg">{icon("forward", 13, 2.2)}</span></div>
  <div class="lo"><div class="wv"><span class="lb">Intensity</span>
  <svg width="252" height="44" viewBox="0 0 252 44" style="position:absolute;left:0;top:0;overflow:visible">
  <defs><clipPath id="wl"><rect x="0" y="0" width="{kx:.1f}" height="44"/></clipPath></defs>
  <polyline points="{wave_pts}" fill="none" stroke="currentColor" stroke-opacity=".16" stroke-width="2.5" stroke-linecap="round"/>
  <polyline points="{wave_pts}" fill="none" stroke="var(--accent)" stroke-width="2.5" stroke-linecap="round" clip-path="url(#wl)"/>
  <circle cx="{kx:.1f}" cy="{22 + 6 * math.sin(kx / 252 * 7 * 2 * math.pi):.2f}" r="10" fill="#fff" stroke="rgba(0,0,0,.08)" stroke-width=".5" style="filter:drop-shadow(0 1px 1.5px rgba(0,0,0,.3))"/></svg></div>
  <div class="dial" style="color:var(--s-text)"><svg width="46" height="46" viewBox="0 0 46 46">{dial}</svg></div></div>
  </div>"""
      return tp

    tp = picker("#86CDF5", "#6D8CF0", ["paper", "mint", "sky", "lilac", "peach", "lemon"], "sky", "light")
    sb = create_sidebar(create_card(name="Side project", theme="sky", focus=False, hover_row="theme"), cells_new, 4)
    w = themed_window("sky", "light", sb, art, tp)
    frames.append(frame("6 · Choose a Theme", " — Arc's picker as a popover beside the card: colour disc with 1–3 handles, − / +, Auto · Light · Dark, presets in whole pages (light · dark · Arc), intensity wave in the theme's accent, grain dial. Live on every drag", w))

    # 7. Profile identity board
    def sbox(tid, mode, inner, h, w=228):
        return f'<div class="sbx" style="width:{w}px;height:{h}px;{tvars(tid, mode)}"><div class="bg"></div><div style="position:absolute;inset:0">{inner}</div></div>'

    def hdr(tid, mode, emoji, name, pid, hover=False, fade=False, multi=True, condensed=False):
        return sbox(tid, mode, f'<div style="position:absolute;left:0;right:0;top:0">{space_header(emoji, name, pid, hover, fade, multi, condensed)}</div>', 41)
    zoom = lambda html, z=2: f'<div class="zoom" style="transform:scale({z});width:{228 * z}px;height:{41 * z}px">{html}</div>'
    hdrs = [
        ("One profile in use", "no indicator (Arc: hasMultipleProfilesInUse)", hdr("mint", "light", "🏡", "Personal", "personal", multi=False)),
        ("Several profiles, rest", "avatar 16 + name, caption, textTertiary, no fill", hdr("mint", "light", "🏡", "Personal", "personal")),
        ("Hovered", "tileFill pill + chevron opens Set Profile ›; ••• appears. The pill condenses to the avatar so the name keeps its room", hdr("mint", "light", "🏡", "Personal", "personal", hover=True, condensed=True)),
        ("Long Space name", "the indicator condenses first (Arc: ProfileIndicatorView.Size .condensed), then the name fades out 20 pt before it", hdr("lilac", "light", "🎨", "Studio and brand refresh", "studio", condensed=True)),
        ("Dark theme, signed in", "the Google photo replaces the emoji", hdr("ocean", "dark", "💼", "Work", "acme")),
    ]
    blocks = ""
    for i, (t, s, h) in enumerate(hdrs):
        x = 56 + (i % 2) * 520
        y = 150 + (i // 2) * 150
        blocks += f'<div class="col" style="left:{x}px;top:{y}px">{zoom(h)}<div class="lbl"><b>{t}</b>{s}</div></div>'
    foot_light = sbox("mint", "light", footer(MULTI_FOOTER + [("🌱", "freelance", "")], 0, False), 50)
    foot_dark = sbox("ocean", "dark", footer(MULTI_FOOTER + [("🌱", "freelance", "")], 1, False), 50)
    blocks += f'<div class="col" style="left:56px;top:612px">{zoom(foot_light.replace("height:50px", "height:50px"), 2).replace("height:82px", "height:100px")}<div class="lbl"><b>Footer, light</b>6 pt dot in the profile colour, bottom-right of each cell, 1.5 pt cut-out ring</div></div>'
    blocks += f'<div class="col" style="left:576px;top:612px">{zoom(foot_dark, 2).replace("height:82px", "height:100px")}<div class="lbl"><b>Footer, dark</b>dots follow the cell (0.45 when not current); hidden with one profile</div></div>'
    av_row = "".join(f'<span style="display:flex;flex-direction:column;align-items:center;gap:8px">{avatar(pid, s)}<code>{s}</code></span>'
                     for pid, s in [("personal", 56), ("acme", 28), ("studio", 28), ("freelance", 20), ("studio", 16)])
    notes = f"""<div class="notes" style="left:1104px;top:140px;width:280px">
<div><h6>Avatar</h6><p style="display:flex;gap:14px;align-items:flex-end;margin:6px 0 10px">{av_row}</p><p>Google photo once signed in; otherwise the emoji on a pastel of the profile colour (OKLab, 28 % colour). 0.5 pt inner hairline. <code>AircProfileAvatar</code></p></div>
<div><h6>Only when it matters</h6><p>Indicator and dots appear once two or more profiles have Spaces. With one profile the sidebar looks exactly like Arc's.</p></div>
<div><h6>Never a manager</h6><p>The indicator opens the Space menu's <code>Set Profile ›</code>. Rename, colour and delete live in Settings → Profiles.</p></div></div>"""
    frames.append(frame("7 · Profiles as identities", " — SP-15: the indicator in the Space header and the dot on footer icons, shown only while several profiles are in use (2×)",
                        stage(blocks + notes, "Which profile is this Space?", "Arc's ProfileIndicatorView: avatar and name in the Space header, plus a profile-coloured dot on each footer icon. Hidden while only one profile is in use.")))

    # 8. Sign in to Google, full window
    side = {
        "name": "Side project", "emoji": "🌱", "theme": "sky", "host": "",
        "profile": PROFILES["freelance"] | {"initial": "F"}, "favorites": [], "pinned": [], "today": [],
    }
    sbh = sidebar(side, ["🏡", "💼", "🎨", "✈️", "🌱"], 4, show_clear=False)
    sbh = sbh.replace('<div class="space"><div class="plate"><div class="emo">🌱</div><div class="nm">Side project</div></div></div>',
                      space_header("🌱", "Side project", "freelance", condensed=True))
    sbh = sbh.replace('<span class="host"></span>', '<span class="host" style="color:var(--text3)">Search or enter URL…</span>')
    sbh = re.sub(r'(<div class="row newtab">.*?</div></div></div>)', lambda m: m.group(1) + sign_in_card(), sbh, count=1, flags=re.S)
    sbh = re.sub(r'<div class="footer">.*', lambda m: footer(MULTI_FOOTER + [("🌱", "freelance", "")], 4) + "\n</div>", sbh, flags=re.S)
    w = (f'<div class="win" style="{tvars("sky", "light")}"><div class="bg"></div>{sbh}'
         f'<div class="card">{empty_space_page("sky", "light", "🌱", "Side project", "freelance")}</div>{CURSOR.format(x=42, y=262)}</div>')
    frames.append(frame("8 · Sign in to Google", " — SP-12: a new profile's Space opens with this card at the top of Today. One click opens accounts.google.com here, in this profile", w))

    # 9. Sign-in sequence board
    def seq_sidebar(state):
        today = []
        hdr_pid = "freelance"
        card = sign_in_card("hover" if state == 0 else "signed") if state != 1 else ""
        if state >= 1:
            today = [{"title": "Sign in – Google Accounts", "fav": "google", "sel": state == 1, "loading": state == 1}]
        if state == 2:
            today = [{"title": "Inbox – Gmail", "fav": "gmail", "sel": True}]
        sp = dict(side, today=today, host="accounts.google.com" if state == 1 else ("mail.google.com" if state == 2 else ""))
        h = sidebar(sp, ["🏡", "💼", "🎨", "✈️", "🌱"], 4, show_clear=False)
        h = re.sub(r'<div class="space">.*?</div></div></div>', lambda m: space_header("🌱", "Side project", hdr_pid, condensed=True), h, count=1, flags=re.S)
        if state == 2:
            PROFILES["freelance_signed"] = PROFILES["personal"] | {"name": "Freelance"}
            h = h.replace(avatar("freelance", 16), avatar("freelance_signed", 16))
        if state == 1:
            h = re.sub(r'(<div class="fi" style="left:9px">)<svg viewBox="0 0 24 24" width="18" height="18"><path d="M20.6.*?</svg>',
                       lambda m: m.group(1) + f'<span style="display:grid;place-items:center;width:18px;height:18px">{loading_ring(14, phase=40)}</span>', h, count=1, flags=re.S)
        if state == 0:
            h = h.replace('<span class="host"></span>', '<span class="host" style="color:var(--text3)">Search or enter URL…</span>')
        if card:
            h = re.sub(r'(<div class="row newtab">.*?</div></div></div>)', lambda m: m.group(1) + card, h, count=1, flags=re.S)
        h = re.sub(r'<div class="footer">.*', lambda m: footer(MULTI_FOOTER + [("🌱", "freelance", "")], 4) + "\n</div>", h, flags=re.S)
        return h
    seq = ""
    labels = [("Before", "card at the top of Today · Sign in hovered"),
              ("Signing in", "the sign-in tab opens in this Space; ring in the favicon slot"),
              ("Signed in", "photo in the indicator · Gmail and Calendar offered as Favorites")]
    for i, (t, s) in enumerate(labels):
        seq += (f'<div class="col" style="left:{56 + i * 262}px"><div class="sbx" style="height:640px;{tvars("sky", "light")}"><div class="bg"></div>'
                f'<div style="position:absolute;inset:0;height:640px">{seq_sidebar(i)}</div></div><div class="lbl"><b>{t}</b>{s}</div></div>')
    notes = f"""<div class="notes" style="left:860px;top:140px;width:524px">
<div><h6>The card</h6><p>Top of Today, under + New Tab. 212 × 112, radius 12, <code>selectedFill</code> with the selected-row shadow so it reads as an object on the theme. Google G 16, title <code>body</code> semibold, copy <code>callout</code> in <code>textSecondary</code>, small primary + plain buttons, a 20 pt dismiss.</p></div>
<div><h6>One click</h6><p>Sign in opens accounts.google.com as a Today tab in this Space, so the cookies land in this profile (SP-3). The card hides while that tab is open and comes back if it closes without a sign-in.</p></div>
<div><h6>After sign-in</h6><p>ListAccounts gives the photo and address: the avatar swaps in the indicator, Profile menu and footer, with a 120 ms cross-fade. The card turns into the Favorites offer once; dismissing it never brings it back.</p></div>
<div><h6>Loading rows</h6><p>The favicon slot shows <code>AircLoadingRing</code> (14 pt, 1.75 pt stroke) only after 150 ms, fading in over 120 ms. The title keeps its full width and fades out at its end; nothing draws over text.</p></div></div>"""
    frames.append(frame("9 · Sign in, step by step", " — the same sidebar at 1:1 before, during and after sign-in",
                        stage(seq + notes, "Sign in to Google", "Right after a new profile is made, its Space asks once. The account photo then becomes the profile's face everywhere.")))

    # 10–13. The same surfaces in a dark Space (Work, Ocean), the case the owner uses daily.
    work = dict(WORK, today=WORK["today"][:3], pinned=WORK["pinned"][:2])
    wk_html = sidebar(work, ["🏡", "💼", "🎨", "✈️"], 1)
    wk_html = wk_html.replace('<div class="space"><div class="plate"><div class="emo">💼</div><div class="nm">Work</div></div></div>',
                              space_header("💼", "Work", "acme"))
    wk_html = re.sub(r'<div class="footer">.*', lambda m: footer(MULTI_FOOTER, 1, False) + "\n</div>", wk_html, flags=re.S)
    lin = LINEAR
    sbd = create_sidebar(create_card(name="Side project", theme="ocean", profile="acme"), MULTI_FOOTER + [("🌱", None, "new")], 4)
    frames.append(frame("10 · Create a Space, dark", " — the same card when the chosen theme is dark (Ocean): ink, fields and the pill come from the dark theme; Create Space in Ocean's accent",
                        themed_window("ocean", "dark", sbd, lin, CURSOR.format(x=150, y=505))))
    frames.append(frame("11 · Create Profile, step 1, dark", " — over the Work Space (Ocean): the card is the dark surface, the avatar keeps its pastel",
                        f'<div class="win" style="{tvars("ocean", "dark")}"><div class="bg"></div>{wk_html}<div class="card">{lin}</div><div class="scrim"></div>{step1_tpl}</div>'))
    frames.append(frame("12 · Create Profile, step 2, dark", " — seven Spaces wrap onto a second, left-aligned row; light Space tiles keep their own colours on the dark card",
                        f'<div class="win" style="{tvars("ocean", "dark")}"><div class="bg"></div>{wk_html}<div class="card">{lin}</div><div class="scrim"></div>{step2}</div>'))
    sbt = create_sidebar(create_card(name="Side project", theme="ocean", focus=False, hover_row="theme"), MULTI_FOOTER + [("🌱", None, "new")], 4)
    frames.append(frame("13 · Choose a Theme, dark", " — editing Ocean: the panel takes the dark surface, the dark presets page is showing, the wave is in Ocean's accent",
                        themed_window("ocean", "dark", sbt, lin, picker("#2F6AF0", "#13B5B0", ["ocean", "grape", "forest", "ember", "slate", "midnight"], "ocean", "dark"))))

    body = '<div style="width:1440px;margin:0 auto;padding-bottom:40px">' + "".join(frames) + "</div>"
    (HERE / "profiles.html").write_text(page("Airc · profiles", body, ARTICLE_CSS + LINEAR_CSS + PROF_CSS + STAGE_CSS + SIGNIN_CSS))


if __name__ == "__main__":
    build_window()
    build_command_bar()
    build_space_switch()
    build_onboarding()
    build_profiles()
    print("built", ", ".join(p.name for p in sorted(HERE.glob("*.html"))))
