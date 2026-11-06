"""Generates the Airc logo files in this folder.  Run: python3 build.py   (PNGs: see README)."""
import math, subprocess
from pathlib import Path
ROOT = Path(__file__).parent


# ---- geometry (variant E) ------------------------------------------------------
import os
OUT = int(os.environ.get("OUT", 138)); HALF = int(os.environ.get("HALF", 185))
R, APEX, FEET, GAP, A_END = 300, 100, 520, 8, 50
DY, DR, HALO = int(os.environ.get("DY",175)), round(46 * OUT / 112), 10
th = math.atan(HALF / (FEET - APEX))
hole_top = APEX + (OUT / 2) / math.sin(th)
arc_y = hole_top + OUT / 2 + 60
cy = arc_y + R
pt = lambda d: (300 + R * math.sin(math.radians(d)), cy - R * math.cos(math.radians(d)))
FL, FR = (300 - HALF, FEET), (300 + HALF, FEET)
a1 = A_END
while a1 > 20 and math.hypot(pt(a1)[0] - FR[0], pt(a1)[1] - FR[1]) < OUT + GAP:
    a1 -= 1
P0, P1 = pt(-40), pt(a1)
ARC = f"M{P0[0]:.1f} {P0[1]:.1f} A{R} {R} 0 0 1 {P1[0]:.1f} {P1[1]:.1f}"
edge = (OUT / 2) / math.cos(th)
DX = 300 + (DY - APEX) * math.tan(th) + edge + 8
A_PATH = f"M{FL[0]} {FL[1]} L300 {APEX} L{FR[0]} {FR[1]}"
LEG_L, LEG_R = f"M300 {APEX} L{FL[0]} {FL[1]}", f"M300 {APEX} L{FR[0]} {FR[1]}"
CUT_R = f"M300 {APEX} L{FL[0]} {FL[1]} L{FL[0]} 900 L900 900 L900 -300 L300 -300Z"
ABOVE_ARC = f"{ARC} L900 {P1[1]:.1f} L900 -300 L{P0[0]:.1f} -300Z"
BX0, BX1 = min(FL[0] - OUT / 2, DX - DR - 6), max(FR[0] + OUT / 2, P1[0] + OUT / 2)
BY0, BY1 = APEX - OUT / 2, FEET + OUT / 2
CXL, CYL, BW, BH = (BX0 + BX1) / 2, (BY0 + BY1) / 2, BX1 - BX0, BY1 - BY0

def stroke(d, col, w):
    return f'<path d="{d}" fill="none" stroke="{col}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>'

def stadium(p, q, rho):
    ux, uy = q[0] - p[0], q[1] - p[1]; L = math.hypot(ux, uy); ux, uy = ux / L, uy / L
    nx, ny = -uy, ux
    f = lambda a, b, k: (a[0] + k * rho * nx, a[1] + k * rho * ny)
    a1_, b1_, b2_, a2_ = f(p, q, 1), f(q, p, 1), f(q, p, -1), f(p, q, -1)
    b1_, b2_ = (q[0] + rho * nx, q[1] + rho * ny), (q[0] - rho * nx, q[1] - rho * ny)
    return (f"M{a1_[0]:.2f} {a1_[1]:.2f} L{b1_[0]:.2f} {b1_[1]:.2f} A{rho:.2f} {rho:.2f} 0 0 0 {b2_[0]:.2f} {b2_[1]:.2f} "
            f"L{a2_[0]:.2f} {a2_[1]:.2f} A{rho:.2f} {rho:.2f} 0 0 0 {a1_[0]:.2f} {a1_[1]:.2f}Z")

def vector_outline(line, uid):
    """black outline only, interiors genuinely transparent (masks, no blend modes / filters)"""
    inner = OUT - 2 * line
    big = 'x="-400" y="-400" width="1600" height="1800" maskUnits="userSpaceOnUse"'
    # shapes back -> front: (kind, path/center, clip id)
    # rounded stroke ends where the dot cuts the A's outline: caps centred on the cut circle, band cut square behind them
    ddx, ddy = FR[0] - 300, FR[1] - APEX; dl = math.hypot(ddx, ddy)
    ux, uy, nx, ny = ddx / dl, ddy / dl, ddy / dl, -ddx / dl
    rho, Rc = OUT / 2 - line / 2, (DR + line / 2) + HALO + line / 2
    px, py = 300 + rho * nx - DX, APEX + rho * ny - DY
    b = px * ux + py * uy; disc = math.sqrt(b * b - (px * px + py * py - Rc * Rc))
    caps, cuts = "", ""
    for t, dirn in ((-b - disc, 1), (-b + disc, -1)):
        cx, cy2 = 300 + rho * nx + t * ux, APEX + rho * ny + t * uy
        caps += f'<circle cx="{cx:.2f}" cy="{cy2:.2f}" r="{line / 2:.2f}" fill="#000"/>'
        w, L = line * 0.9, line * 2.5
        pts = [(cx + nx * w, cy2 + ny * w), (cx - nx * w, cy2 - ny * w),
               (cx - nx * w + dirn * ux * L, cy2 - ny * w + dirn * uy * L), (cx + nx * w + dirn * ux * L, cy2 + ny * w + dirn * uy * L)]
        cuts += '<polygon points="' + " ".join(f"{x:.2f},{y:.2f}" for x, y in pts) + '" fill="#000"/>'
    shapes = [("p", A_PATH, None), ("p", ARC, "cr"), ("p", LEG_L, "ct"), ("c", None, None)]
    rd = DR + line / 2           # dot outer radius
    ri = DR - line / 2
    def footprint(sh):  # black = hide earlier shapes underneath
        kind, d, clip = sh
        if kind == "c":
            return f'<circle cx="{DX:.1f}" cy="{DY}" r="{rd + HALO + line / 2}" fill="#000"/>' + cuts
        g = stroke(d, "#000", OUT)
        if clip == "ct": clip = "cf"   # hide earlier shapes slightly below where the band starts, so the two bands overlap (no gap)
        return f'<g clip-path="url(#{clip}{uid})">{g}</g>' if clip else g
    def band(sh):
        kind, d, clip = sh
        if kind == "c":
            return f'<circle cx="{DX:.1f}" cy="{DY}" r="{rd}" fill="#fff"/><circle cx="{DX:.1f}" cy="{DY}" r="{ri}" fill="#000"/>'
        if clip == "ct":   # single ring path: no stacked strokes, so no hairline at the clip edge
            g = stroke(stadium((300, APEX), FL, OUT / 2 - line / 2), "#fff", line)
        else:
            g = stroke(d, "#fff", OUT) + stroke(d, "#000", inner)
        return f'<g clip-path="url(#{clip}{uid})">{g}</g>' if clip else g
    out = f'<defs><clipPath id="cr{uid}"><path d="{CUT_R}"/></clipPath><clipPath id="ct{uid}"><rect x="-400" y="{hole_top:.1f}" width="1600" height="1800"/></clipPath><clipPath id="cf{uid}"><rect x="-400" y="{hole_top + 4:.1f}" width="1600" height="1800"/></clipPath>'
    body = ""
    for i, sh in enumerate(shapes):
        later = "".join(footprint(s) for s in shapes[i + 1:])
        out += f'<mask id="m{uid}{i}" {big}><rect x="-400" y="-400" width="1600" height="1800" fill="#000"/>{band(sh)}{later}</mask>'
        body += f'<rect x="-400" y="-400" width="1600" height="1800" fill="#000" mask="url(#m{uid}{i})"/>'
    return out + "</defs>" + body + caps

def squircle(cx, cy_, a, n=5, k=240):
    pts = []
    for i in range(k):
        t = 2 * math.pi * i / k
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(c) ** (2 / n), c), cy_ + a * math.copysign(abs(s) ** (2 / n), s)))
    return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + "Z"

S_FIXED = 0.6203007518796992   # scale of the 112-thick design, kept constant so thicker strokes don't shrink the mark

def icon(logo_w, border, line_px, holo=False, uid="x"):
    s = S_FIXED
    tx, ty = 300 - CXL * s, 300 - CYL * s
    line = line_px / s
    face = squircle(300, 300, 262 if not holo else 250)
    logo = f'<g transform="translate({tx:.2f} {ty:.2f}) scale({s:.4f})">{vector_outline(line, uid)}</g>'
    if not holo:
        return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600"><rect width="600" height="600" fill="#fff"/>
<path d="{face}" fill="#fff" stroke="#000" stroke-width="{border}" stroke-linejoin="round"/>{logo}</svg>'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600">
<defs>
<linearGradient id="ring{uid}" x1="40" y1="560" x2="560" y2="40" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#5fe3b4"/><stop offset=".25" stop-color="#7fb0ff"/><stop offset=".5" stop-color="#c79bff"/><stop offset=".72" stop-color="#ff93c0"/><stop offset=".88" stop-color="#ffc999"/><stop offset="1" stop-color="#9aeccd"/></linearGradient>
<linearGradient id="face{uid}" x1="40" y1="40" x2="560" y2="560" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#b4f0da"/><stop offset=".25" stop-color="#c4e0ff"/><stop offset=".5" stop-color="#e2d0ff"/><stop offset=".75" stop-color="#ffd3e3"/><stop offset="1" stop-color="#cdebdd"/></linearGradient>
<radialGradient id="b1{uid}" cx="76%" cy="22%" r="40%"><stop offset="0" stop-color="#ffb8cf" stop-opacity=".9"/><stop offset="1" stop-color="#ffb8cf" stop-opacity="0"/></radialGradient>
<radialGradient id="b2{uid}" cx="22%" cy="82%" r="44%"><stop offset="0" stop-color="#bda5ff" stop-opacity=".9"/><stop offset="1" stop-color="#bda5ff" stop-opacity="0"/></radialGradient>
<radialGradient id="b3{uid}" cx="82%" cy="86%" r="34%"><stop offset="0" stop-color="#8eeec6" stop-opacity=".9"/><stop offset="1" stop-color="#8eeec6" stop-opacity="0"/></radialGradient>
<radialGradient id="b4{uid}" cx="26%" cy="20%" r="34%"><stop offset="0" stop-color="#fff" stop-opacity=".85"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<clipPath id="in{uid}"><path d="{face}"/></clipPath></defs>
<path d="{squircle(300, 300, 288)}" fill="url(#ring{uid})"/>
<path d="{face}" fill="url(#face{uid})"/>
<g clip-path="url(#in{uid})"><rect width="600" height="600" fill="url(#b1{uid})"/><rect width="600" height="600" fill="url(#b2{uid})"/><rect width="600" height="600" fill="url(#b3{uid})"/><rect width="600" height="600" fill="url(#b4{uid})"/></g>
{logo}
<path d="{face}" fill="none" stroke="#000" stroke-width="{border}" stroke-linejoin="round"/></svg>'''

def shoot(svg_path, png, size=600, transparent=True):
    flag = ["--default-background-color=00000000"] if transparent else []
    subprocess.run(["google-chrome", "--headless", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", *flag,
                    f"--screenshot={png}", f"--window-size={size},{size}", f"file://{svg_path}"], capture_output=True)




def mark(line_px=16):
    pad = 24
    x0, y0, w, h = BX0 - pad, BY0 - pad, BW + 2 * pad, BH + 2 * pad
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x0:.0f} {y0:.0f} {w:.0f} {h:.0f}">'
            f'{vector_outline(line_px / S_FIXED, "m")}</svg>')

(ROOT / "airc-holographic.svg").write_text(icon(330, 12, 16, holo=True, uid="fh"))
(ROOT / "airc-outline-squircle.svg").write_text(icon(330, 12, 16, holo=False, uid="fo"))
(ROOT / "airc-mark-outline.svg").write_text(mark())
