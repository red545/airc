#!/usr/bin/env python3
"""Builds the homepage's product shots as HTML, from the design mockups (docs/design/mockups/build.py).

    python3 apps/marketing/scripts/shots.py            # writes apps/marketing/.shots/*.html

Then `apps/marketing/scripts/shots.sh` renders them on the build Mac with WebKit and the real SF fonts and
turns them into WebP under apps/marketing/src/assets/shots/.

The mockups are reused as they are, with two changes for a public page: the demo data is neutral (no real
usernames, repos or email addresses) and the design annotations (captions, labels) are left out.
"""
import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parents[1] / ".shots"

spec = importlib.util.spec_from_file_location("mockups", ROOT / "docs/design/mockups/build.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Neutral demo data: the mockups' repo row becomes the demo blog's repo.
for item in m.PERSONAL["pinned"]:
    if item.get("fav") == "github":
        item["title"] = "papertrail/web"

EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
DEMO_EMAILS = {"alex@example.com", "alex@acme.example"}

NO_ANNOTATIONS = ".caption,.ob-cap{display:none!important}"


def write(name, body, css=""):
    OUT.mkdir(exist_ok=True)
    html = m.page(f"Airc · {name}", body, css + NO_ANNOTATIONS)
    # Only reserved example addresses may appear (the grain and icons are data: URIs, so skip those).
    text = re.sub(r"data:[^\"')]+", "", html)
    leaked = set(EMAIL.findall(text)) - DEMO_EMAILS
    if leaked:
        sys.exit(f"{name}: non-demo email addresses: {sorted(leaked)}")
    (OUT / f"{name}.html").write_text(html)


def desk(inner):
    return f'<div class="desk">{m.wallpaper()}{m.MENUBAR}{inner}</div>'


def floating_browser(sp, mode, more, left, top, w, h, card, current=0):
    sb = m.sidebar(sp, m.SPACE_ICONS, current)
    return (f'<div class="tw bw{" dark" if mode == "dark" else ""}" style="{m.tvars(sp["theme"], mode)};left:{left}px;'
            f'top:{top}px;width:{w}px;height:{h}px">{m.tbg(more)}{sb}<div class="card">{card}</div></div>')


article = m.ARTICLE.format(logo=m.fav("paper", 26))
css = m.ARTICLE_CSS + m.LINEAR_CSS

# Hero: the Personal Space in Mint, translucent over the desktop (light); the Work Space in Ocean (dark).
write("hero-light", desk(floating_browser(m.PERSONAL, "light", False, 60, 64, 1320, 800, article)), css)
write("hero-dark", desk(floating_browser(m.WORK, "dark", False, 60, 64, 1320, 800, m.LINEAR, current=1)), css)

# Spaces: the same window in two Spaces with two profiles.
write("space-personal", m.window(m.PERSONAL, m.SPACE_ICONS, 0, article), css)
write("space-work", m.window(m.WORK, m.SPACE_ICONS, 1, m.LINEAR, hover_header=True), css)

# Command bar: build_command_bar writes into the mockups folder, so capture its body instead.
captured = {}
orig_page = m.page
m.page = lambda title, body, extra_css="": captured.setdefault(title, (body, extra_css)) and ""


class Sink:
    def __truediv__(self, _):
        return self

    def write_text(self, _):
        pass


m.HERE = Sink()
m.build_command_bar()
m.build_onboarding()
m.page = orig_page

body, extra = captured["Airc · command bar"]
write("command-bar", body, extra)

# Onboarding: one desk per step; keep "Import from Arc", with neutral addresses.
body, extra = captured["Airc · onboarding"]
# The Personal profile's account first, then the work one.
addresses = iter(["alex@example.com", "alex@acme.example"])
seen = {}
body = EMAIL.sub(lambda mt: seen.setdefault(mt.group(0), next(addresses, "alex@example.com")), body)
frames = re.findall(r'<div class="caption">.*?</div>(<div class="desk">.*?)(?=<div class="caption">|</div>$)', body, re.S)
if len(frames) != 6:
    sys.exit(f"expected 6 onboarding frames, found {len(frames)}")
write("import", frames[1], extra)

print("wrote", ", ".join(sorted(p.name for p in OUT.glob("*.html"))))
