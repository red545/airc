"""Builds the macOS app icon sources from the logo geometry in build.py.

    python3 appicon.py        # writes airc-icon-small.svg and build/appicon-*.html
    ./appicon.sh              # on the Mac: renders them with WebKit, then sips + iconutil

The big sizes (32 pt @2x and up) use airc-holographic.svg as is. At 16 and 32 px its 16 px outline (on the 600 px
canvas) falls under half a device pixel and the ring blurs into the face, so those sizes use a small-size
variant drawn the same way (`build.vector_outline`, the same face gradient): no ring, the face filling the
whole squircle, a 40 px outline and a 22 px border.
"""
import base64
import contextlib
import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).parent
with contextlib.redirect_stdout(io.StringIO()):
    import build  # noqa: E402  (regenerates the three logo SVGs deterministically; same output)

SMALL_LINE, SMALL_BORDER = 40, 22


def small_icon(uid="fs"):
    """The holographic icon simplified for 16 and 32 px: no ring, thicker outline and border."""
    svg = build.icon(330, SMALL_BORDER, SMALL_LINE, holo=True, uid=uid)
    face = build.squircle(300, 300, 250)
    full = build.squircle(300, 300, 288 - SMALL_BORDER / 2)
    # Drop the ring and let the face (gradient, blobs, border) fill the ring's silhouette.
    svg = re.sub(r'<path d="[^"]*" fill="url\(#ring' + uid + r'\)"/>\n', "", svg)
    svg = svg.replace(f'd="{face}"', f'd="{full}"')
    # Scale the mark up with the face so it keeps its proportion inside it.
    k = (288 - SMALL_BORDER / 2) / 250
    s = build.S_FIXED * k
    tx, ty = 300 - build.CXL * s, 300 - build.CYL * s
    svg = re.sub(r'<g transform="translate\([^)]*\) scale\([^)]*\)">',
                 f'<g transform="translate({tx:.2f} {ty:.2f}) scale({s:.4f})">', svg, count=1)
    return svg


# macOS icon grid (Big Sur and later): a 1024 canvas, the body 824 × 824 centred, a soft drop shadow.
BODY = 824 / 1024
PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;background:transparent}}
.c{{width:512px;height:512px;display:grid;place-items:center}}
img{{width:{w:.3f}px;height:{w:.3f}px;filter:drop-shadow(0 {dy}px {blur}px rgba(0,0,0,{a}))}}
</style></head><body><div class="c"><img src="{src}"></div></body></html>"""


def data_uri(path, mime):
    return f"data:{mime};base64," + base64.b64encode(Path(path).read_bytes()).decode()


def page(src, shadow=True):
    # The SVG's silhouette spans 576 of its 600 units; size it so the silhouette is the 824 px body.
    w = 512 * BODY * 600 / 576
    dy, blur, a = (5, 6, 0.28) if shadow else (0, 0, 0)
    return PAGE.format(w=w, src=data_uri(ROOT / src, "image/svg+xml"), dy=dy, blur=blur, a=a)


def contact_sheet():
    """Every size at 4× (pixelated, to judge the pixels) and at 1×, on light and dark."""
    out = ROOT / "build"
    sheet = ["<!doctype html><html><body style='margin:0;background:#ECEAE6;font:12px -apple-system'>"]
    for bg in ("#ECEAE6", "#1E1C1B"):
        sheet.append(f"<div style='display:flex;gap:28px;align-items:end;padding:20px;background:{bg}'>")
        for name in ("16", "16@2x", "32", "32@2x", "128"):
            px = {"16": 16, "16@2x": 32, "32": 32, "32@2x": 64, "128": 128, "256": 256}[name]
            pt = {"16": 16, "16@2x": 16, "32": 32, "32@2x": 32, "128": 128, "256": 256}[name]
            file = f"icon_{name.split('@')[0]}x{name.split('@')[0]}{'@2x' if '@2x' in name else ''}.png"
            uri = data_uri(out / "AppIcon.iconset" / file, "image/png")
            zoom = f"<img src='{uri}' style='width:{pt * 8}px;height:{pt * 8}px;image-rendering:pixelated'>" if pt <= 32 else ""
            sheet.append(f"<figure style='margin:0;text-align:center;color:#888'>{zoom}"
                         f"<img src='{uri}' style='width:{pt}px;height:{pt}px;margin-left:8px'>"
                         f"<figcaption>{name} ({px} px)</figcaption></figure>")
        sheet.append("</div>")
    (out / "contact-sheet.html").write_text("".join(sheet) + "</body></html>")


if __name__ == "__main__":
    if sys.argv[1:] == ["sheet"]:
        contact_sheet()
        sys.exit()
    (ROOT / "airc-icon-small.svg").write_text(small_icon())
    out = ROOT / "build"
    out.mkdir(exist_ok=True)
    (out / "appicon-large.html").write_text(page("airc-holographic.svg"))
    (out / "appicon-small.html").write_text(page("airc-icon-small.svg", shadow=False))
    print("wrote airc-icon-small.svg, build/appicon-large.html, build/appicon-small.html")
