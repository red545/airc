#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Steepwell, the made-up coffee and tea shop of the homepage's Airc Agent demo (marketing part "aidemo").

Writes the static pages into site/ (assets are already there: fonts under OFL, product photos rendered by
render/products.py). The app serves site/ on loopback (Debug/MarketingAgentDemo.swift): `/name.html` as `/name`,
`index.html` as `/`. Everything here is invented: brand, products, prices, reviews, people and the address.

The agent's script clicks fixed points, so every control it uses sits at the same place at a 1280 × 800 viewport;
`#m` on any page puts those controls' centres (elements with data-m) in the title, for measure.py.
"""
import html
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(HERE, "site")

PRODUCTS = {
    "pour": dict(name="Pour gooseneck kettle", short="Pour", price=79, rating=4.8, reviews=1284, img="pour", alt="pour-side",
                 colour="Slate", colours=[("Slate", "#2b2d30"), ("Sage", "#7d9283")],
                 blurb="A slow, steady stream for pour-over, and any temperature from 40 to 100 °C, held to the degree."),
    "rapid": dict(name="Rapid kettle 1.7 L", short="Rapid", price=64, rating=4.6, reviews=2031, img="rapid", alt="rapid-side",
                  colour="Brushed steel", colours=[("Brushed steel", "#c9cbcd"), ("Matte black", "#1d1e20")],
                  blurb="Our fastest boil: a litre in 2 min 40 s, four tea presets and a 30-minute keep-warm."),
    "cone": dict(name="Cone dripper 02", short="Cone", price=26, rating=4.9, reviews=846, img="cone",
                 colour="Oat glaze", colours=[("Oat", "#ece4d6"), ("Clay", "#b9805d")],
                 blurb="Glazed stoneware with spiral ribs for an even, unhurried extraction."),
    "carafe": dict(name="Carafe 600 ml", short="Carafe", price=34, rating=4.7, reviews=512, img="carafe",
                   colour="Glass & oak", colours=[("Oak", "#c7a27a")],
                   blurb="Heat-proof borosilicate with an oak collar that stays cool to hold."),
    "mugs": dict(name="Stack mugs, set of 2", short="Stack mugs", price=32, rating=4.8, reviews=693, img="mugs",
                 colour="Oat & Moss", colours=[("Oat & Moss", "#9db0a0")],
                 blurb="Thick-walled stoneware that keeps a flat white warm to the last sip."),
    "mill": dict(name="Mill hand grinder", short="Mill", price=119, rating=4.7, reviews=388, img="grinder",
                 colour="Steel & walnut", colours=[("Steel", "#c9cbcd")],
                 blurb="Steel conical burrs, 40 click settings, from espresso to cold brew."),
    "gram": dict(name="Gram brew scale", short="Gram", price=49, rating=4.6, reviews=274, img="scale",
                 colour="Black", colours=[("Black", "#1d1e20")],
                 blurb="0.1 g precision and a built-in timer, under a silicone pad."),
}

COMPARE = [
    ("Capacity", "0.9 L", "1.7 L"),
    ("Spout", "Gooseneck, flow-controlled", "Wide pouring spout"),
    ("Temperature", "40–100 °C, to the degree", "4 presets: 70, 80, 90, 100 °C"),
    ("Holds temperature", "Up to 60 min", "Keep-warm, 30 min"),
    ("Boils 1 litre", "4 min 10 s (0.9 L)", "2 min 40 s"),
    ("Power", "1200 W", "2400 W"),
    ("Brew timer", "Built into the base", "—"),
    ("Materials", "Stainless steel, walnut handle", "Brushed stainless steel"),
    ("Best for", "Pour-over, green and white tea", "Big pots of tea, cooking"),
    ("Warranty", "2 years", "2 years"),
]

REVIEWS = {
    "pour": [
        (5, "Mara K.", "Finally a steady pour", "The stream is thin and even, so my V-cone brews are consistent for the first time. Holds 94 °C while I grind."),
        (5, "Tomás R.", "Beautiful on the counter", "The walnut handle feels lovely and the base is quiet. Sets to the exact degree for my sencha."),
        (4, "Jun H.", "Small but perfect", "0.9 L is plenty for two cups of pour-over. Wish it boiled a little faster."),
    ],
    "rapid": [
        (5, "Priya S.", "Really is rapid", "A full jug for the family's tea in no time. The presets are handy."),
        (4, "Olu A.", "Great everyday kettle", "Boils fast and pours cleanly into a pot. Too gushy for my pour-over, though."),
        (5, "Elin B.", "Solid and quiet", "Brushed steel hides fingerprints, and the blue ring is a nice touch."),
    ],
}

FONTS = """
@font-face{font-family:Inter;src:url(/assets/fonts/inter-latin-wght.woff2) format("woff2");font-weight:100 900;font-display:block}
@font-face{font-family:"Instrument Serif";src:url(/assets/fonts/InstrumentSerif-Regular.ttf) format("truetype");font-display:block}
@font-face{font-family:"Instrument Serif";font-style:italic;src:url(/assets/fonts/InstrumentSerif-Italic.ttf) format("truetype");font-display:block}
"""

CSS = FONTS + """
:root{--bg:#f6f2ec;--paper:#fffdf9;--ink:#1d1a16;--muted:#6f675e;--line:#e6ded3;--pine:#24453a;--pine-2:#1b362d;--sand:#eae2d6;
--gold:#c58b3a;--radius:18px;--max:1200px}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 Inter,system-ui,sans-serif;-webkit-font-smoothing:antialiased;
font-feature-settings:"cv11","ss01"}
a{color:inherit;text-decoration:none}img{display:block;max-width:100%}
.wrap{max-width:var(--max);margin:0 auto;padding:0 40px}
.serif{font-family:"Instrument Serif",Georgia,serif;font-weight:400;letter-spacing:-.01em}
.muted{color:var(--muted)}
.notice{height:36px;background:var(--pine);color:#e9efe9;font-size:12.5px;letter-spacing:.02em;display:flex;align-items:center;justify-content:center;gap:28px}
.notice b{font-weight:600;color:#fff}
header.top{height:72px;background:var(--paper);border-bottom:1px solid var(--line)}
header.top .wrap{height:100%;display:flex;align-items:center;gap:36px}
.logo{display:flex;align-items:center;gap:9px;font-family:"Instrument Serif",Georgia,serif;font-size:30px;line-height:1;letter-spacing:-.02em}
.logo svg{width:22px;height:22px;flex:none}
nav.main{display:flex;gap:26px;font-size:14px;font-weight:500}
nav.main a{color:#3c362f}nav.main a.on{color:var(--ink);text-decoration:underline;text-decoration-thickness:2px;text-underline-offset:8px}
.search{margin-left:auto;position:relative;width:300px;flex:none}
.search input{width:100%;height:42px;border-radius:999px;border:1px solid var(--line);background:#f4efe8;padding:0 16px 0 42px;
font:inherit;font-size:14px;color:var(--ink);outline:none}
.search input:focus{border-color:#cbbfae;background:#fff;box-shadow:0 0 0 4px rgba(36,69,58,.08)}
.search svg{position:absolute;left:15px;top:13px;width:16px;height:16px;color:#8a8178}
.icons{display:flex;gap:18px;align-items:center;flex:none}
.bag{display:flex;align-items:center;gap:8px;font-size:14px;font-weight:500}
.bag svg{width:20px;height:20px}
.count{min-width:20px;height:20px;border-radius:10px;background:var(--ink);color:#fff;font-size:11.5px;font-weight:600;display:inline-flex;align-items:center;justify-content:center;padding:0 6px}
.count.zero{background:#d9d1c5;color:#5c554d}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;height:48px;padding:0 26px;border-radius:999px;border:0;
background:var(--pine);color:#fff;font:600 15px Inter,sans-serif;cursor:pointer;white-space:nowrap}
.btn:hover{background:var(--pine-2)}
.btn.ghost{background:transparent;color:var(--ink);box-shadow:inset 0 0 0 1px #cfc5b7}
.btn.light{background:#fff;color:var(--ink)}
.stars{display:inline-flex;gap:1px;vertical-align:-2px}.stars svg{width:14px;height:14px}
.rating{font-size:13px;color:var(--muted);display:flex;align-items:center;gap:7px}
.rating b{color:var(--ink);font-weight:600}
.chip{display:inline-flex;align-items:center;height:34px;padding:0 15px;border-radius:999px;border:1px solid var(--line);background:var(--paper);font-size:13.5px;font-weight:500;color:#3c362f}
.chip.on{background:var(--ink);border-color:var(--ink);color:#fff}
.swatches{display:flex;gap:6px}.swatches i{width:14px;height:14px;border-radius:50%;box-shadow:inset 0 0 0 1px rgba(0,0,0,.12)}
.crumbs{font-size:13px;color:var(--muted);display:flex;gap:8px}.crumbs span:last-child{color:var(--ink)}
footer{margin-top:90px;border-top:1px solid var(--line);background:var(--paper)}
footer .wrap{display:grid;grid-template-columns:1.6fr 1fr 1fr 1fr;gap:30px;padding-top:46px;padding-bottom:46px;font-size:13.5px}
footer h4{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 12px;font-weight:600}
footer p{margin:0 0 7px;color:#4a443d}
.demo-note{font-size:12px;color:var(--muted);text-align:center;padding:0 0 26px}

/* home */
.hero{position:relative;margin-top:28px;border-radius:26px;overflow:hidden;background:#e7dccd;aspect-ratio:2/1;max-height:520px;width:100%}
.hero img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;object-position:70% 60%}
.hero .copy{position:absolute;left:48px;top:46px;max-width:420px}
.hero h1{font-size:64px;line-height:.98;margin:0 0 16px}
.hero h1 em{font-style:italic;color:var(--pine)}
.hero p{font-size:16.5px;color:#4b443c;margin:0 0 26px;max-width:340px}
.section-h{display:flex;align-items:baseline;justify-content:space-between;margin:64px 0 22px}
.section-h h2{font-size:40px;margin:0}
.section-h a{font-size:14px;font-weight:600;border-bottom:1px solid currentColor}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:22px}
.card{position:relative;display:block}
.card .ph{background:#ece6dd;border-radius:var(--radius);overflow:hidden;aspect-ratio:1/1;position:relative}
.card .ph img{width:100%;height:100%;object-fit:cover;transition:transform .5s}
.card:hover .ph img{transform:scale(1.03)}
.badge{position:absolute;left:12px;top:12px;background:var(--paper);border-radius:999px;font-size:11.5px;font-weight:600;padding:5px 10px;letter-spacing:.01em}
.card h3{font-size:15px;font-weight:600;margin:14px 0 2px}
.card .meta{display:flex;justify-content:space-between;align-items:center;margin-top:6px}
.price{font-weight:600;font-size:15px}
.values{display:grid;grid-template-columns:repeat(3,1fr);gap:22px;margin-top:64px}
.value{background:var(--paper);border:1px solid var(--line);border-radius:var(--radius);padding:26px 26px 24px}
.value h3{font-family:"Instrument Serif",serif;font-weight:400;font-size:26px;margin:0 0 6px}
.value p{margin:0;color:var(--muted)}

/* results */
.results-head{display:flex;align-items:flex-end;justify-content:space-between;margin:30px 0 18px}
.results-head h1{font-size:46px;margin:6px 0 0;line-height:1}
.filters{display:flex;gap:8px;margin-bottom:22px}
.compare-box{display:flex;align-items:center;gap:9px;margin-top:12px;height:36px;padding:0 14px 0 10px;border-radius:999px;border:1px solid var(--line);
background:var(--paper);font-size:13.5px;font-weight:500;cursor:pointer;user-select:none;width:max-content}
.compare-box i{width:18px;height:18px;border-radius:6px;border:1.5px solid #b9ae9f;display:inline-flex;align-items:center;justify-content:center;background:#fff}
.compare-box.on{border-color:var(--pine);background:#eef3ef}
.compare-box.on i{background:var(--pine);border-color:var(--pine)}
.compare-box.on i:after{content:"";width:9px;height:5px;border:2px solid #fff;border-top:0;border-right:0;transform:rotate(-45deg) translate(1px,-1px)}
.tray{position:fixed;left:50%;bottom:22px;transform:translate(-50%,140%);transition:transform .35s cubic-bezier(.2,.9,.3,1.1);
background:var(--ink);color:#fff;border-radius:999px;display:flex;align-items:center;gap:18px;padding:8px 8px 8px 22px;width:440px;box-shadow:0 14px 40px rgba(0,0,0,.22);font-size:14px;z-index:5}
.tray.up{transform:translate(-50%,0)}
.tray .thumbs{display:flex;margin-left:auto}.tray .thumbs img{width:34px;height:34px;border-radius:50%;border:2px solid var(--ink);object-fit:cover;margin-left:-8px;background:#eee}
.tray .btn{height:42px;background:#fff;color:var(--ink)}

/* compare */
.cmp{display:grid;grid-template-columns:240px 1fr 1fr;gap:0 24px;margin-top:26px}
.cmp .prod{background:var(--paper);border:1px solid var(--line);border-radius:22px;padding:18px;display:grid;grid-template-columns:150px 1fr;gap:20px;align-items:center}
.cmp .prod .ph{border-radius:14px;overflow:hidden;background:#ece6dd;aspect-ratio:1/1}
.cmp .prod h2{font-size:30px;margin:0 0 4px;line-height:1.05}
.cmp .prod .price{font-size:20px;margin:8px 0 14px}
.cmp .prod .btn{height:42px;padding:0 20px;font-size:14px}
.cmp .intro h1{font-size:46px;line-height:1;margin:6px 0 10px}
.spec{display:grid;grid-template-columns:240px 1fr 1fr;gap:0 24px;border-top:1px solid var(--line);padding:14px 0;font-size:14.5px}
.spec div:first-child{color:var(--muted)}
.spec .win{font-weight:600}
.spec .win:before{content:"";display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--pine);margin-right:8px;vertical-align:2px}
.quotes{display:grid;grid-template-columns:240px 1fr 1fr;gap:0 24px;margin-top:36px}
.quote{background:var(--paper);border:1px solid var(--line);border-radius:var(--radius);padding:18px 20px;margin-bottom:14px}
.quote b{display:block;font-size:14.5px;margin:6px 0 4px}.quote p{margin:0;color:#4a443d;font-size:14px}
.quote .who{font-size:12.5px;color:var(--muted);margin-top:8px}

/* product */
.pdp{display:grid;grid-template-columns:1.15fr 1fr;gap:56px;margin-top:26px}
.gallery{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.gallery .main{grid-column:1/3;border-radius:22px;overflow:hidden;background:#ece6dd;aspect-ratio:4/3}
.gallery .main img{width:100%;height:100%;object-fit:cover}
.gallery .sub{border-radius:16px;overflow:hidden;background:#ece6dd;aspect-ratio:1/1}
.pdp h1{font-size:52px;line-height:1;margin:10px 0 10px}
.pdp .price{font-size:24px;margin:16px 0}
.pdp ul{padding-left:18px;color:#4a443d}.pdp li{margin:6px 0}

/* bag + checkout */
.two{display:grid;grid-template-columns:1fr 380px;gap:36px;margin-top:26px;align-items:start}
.panel{background:var(--paper);border:1px solid var(--line);border-radius:22px;padding:24px 26px}
.line{display:grid;grid-template-columns:120px 1fr auto;gap:20px;align-items:center}
.line .ph{border-radius:14px;overflow:hidden;background:#ece6dd;aspect-ratio:1/1}
.line h3{margin:0 0 3px;font-size:16px}
.qty{display:inline-flex;align-items:center;border:1px solid var(--line);border-radius:999px;height:34px;margin-top:12px;font-size:14px}
.qty span{width:34px;text-align:center;color:var(--muted)}.qty b{width:26px;text-align:center;font-weight:600}
.sum{display:flex;justify-content:space-between;padding:7px 0;font-size:14.5px}
.sum.total{border-top:1px solid var(--line);margin-top:10px;padding-top:16px;font-size:17px;font-weight:600}
.steps{display:flex;gap:10px;align-items:center;font-size:13px;color:var(--muted);margin-top:30px}
.steps b{color:var(--ink);font-weight:600}.steps i{width:22px;height:1px;background:#cfc5b7}
.field{border:1px solid var(--line);border-radius:14px;padding:12px 16px;background:#fff;margin-top:10px}
.field small{display:block;font-size:12px;color:var(--muted)}
.opt{display:flex;align-items:center;gap:14px;border:1px solid var(--line);border-radius:14px;padding:14px 16px;background:#fff;margin-top:10px;font-size:14.5px}
.opt.on{border-color:var(--pine);box-shadow:inset 0 0 0 1px var(--pine)}
.opt .dot{width:18px;height:18px;border-radius:50%;border:1.5px solid #b9ae9f;flex:none}
.opt.on .dot{border:5px solid var(--pine)}
.opt .r{margin-left:auto;font-weight:600}
.card-ic{width:38px;height:26px;border-radius:5px;background:linear-gradient(135deg,#2f5547,#1c3a30);position:relative;flex:none}
.card-ic:after{content:"";position:absolute;left:6px;top:8px;width:9px;height:7px;border-radius:2px;background:#d8b46a}
h2.h{font-size:28px;margin:0 0 6px}
.mini{display:grid;grid-template-columns:64px 1fr auto;gap:14px;align-items:center;margin-bottom:16px;font-size:14px}
.mini .ph{border-radius:10px;overflow:hidden;background:#ece6dd;aspect-ratio:1/1}
.secure{display:flex;gap:8px;align-items:center;justify-content:center;font-size:12.5px;color:var(--muted);margin-top:12px}

.done{max-width:640px;margin:70px auto 0;text-align:center}
.done .tick{width:64px;height:64px;border-radius:50%;background:var(--pine);margin:0 auto 22px;display:flex;align-items:center;justify-content:center}
.done h1{font-size:54px;line-height:1;margin:0 0 12px}

/* narrower windows (the person's own tab, phones) */
@media (max-width:1080px){
  .wrap{padding:0 28px}nav.main{display:none}.search{width:240px}
  .hero{aspect-ratio:auto;max-height:none;display:flex;flex-direction:column-reverse;background:#c6bdb3}
  .hero img{position:static;width:100%;height:auto;aspect-ratio:2/1;margin-top:-56px;-webkit-mask-image:linear-gradient(to bottom,transparent,#000 24%);mask-image:linear-gradient(to bottom,transparent,#000 24%)}
  .hero .copy{position:relative;z-index:1;left:auto;top:auto;max-width:none;padding:38px 40px 0}
  .hero h1{font-size:50px}.hero p{max-width:420px}
  .grid{grid-template-columns:repeat(2,1fr)}
  .cmp,.spec,.quotes{grid-template-columns:150px 1fr 1fr}.cmp .prod{grid-template-columns:1fr}
  .pdp,.two{grid-template-columns:1fr}
  footer .wrap{grid-template-columns:1fr 1fr}
}
@media (max-width:640px){
  .wrap{padding:0 16px}.search{display:none}.notice span+span{display:none}
  .hero .copy{padding:24px 20px 0}.hero h1{font-size:40px}
  .values{grid-template-columns:1fr}.cmp,.spec,.quotes{grid-template-columns:1fr 1fr}.cmp .intro,.spec div:first-child{grid-column:1/3}
  .quotes>div:first-child{display:none}
}
"""

LOGO = ('<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.5c3.6 4.3 6.5 8 6.5 11.6A6.5 6.5 0 0 1 5.5 14.1C5.5 10.5 8.4 6.8 12 2.5Z" '
        'fill="#24453a"/><path d="M9 14.5c.3 1.6 1.5 2.7 3.2 2.9" stroke="#fff" stroke-width="1.6" fill="none" stroke-linecap="round"/></svg>')
SEARCH = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="7" cy="7" r="5"/><path d="m11 11 3.5 3.5" stroke-linecap="round"/></svg>'
BAG = ('<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 6.5h12l-1 10.5H5L4 6.5Z" stroke-linejoin="round"/>'
       '<path d="M7.5 8.5V5.5a2.5 2.5 0 0 1 5 0v3" stroke-linecap="round"/></svg>')
STAR = '<svg viewBox="0 0 14 14"><path d="m7 1.2 1.75 3.8 4.1.45-3.05 2.8.85 4.05L7 10.2l-3.65 2.1.85-4.05L1.15 5.45l4.1-.45Z" fill="{c}"/></svg>'

MEASURE = """<script>
if(location.hash.startsWith("#m"))addEventListener("load",()=>{if(location.hash==="#m2")document.querySelectorAll(".compare-box").forEach(b=>b.click());setTimeout(()=>{const o={};document.querySelectorAll("[data-m]").forEach(e=>{const r=e.getBoundingClientRect();
o[e.dataset.m]=[Math.round(r.left+r.width/2),Math.round(r.top+r.height/2),Math.round(r.width),Math.round(r.height)]});document.title=JSON.stringify(o)},900)});
</script>"""


def esc(s):
    return html.escape(s, quote=True)


def stars(r):
    full = int(r + 0.25)
    return '<span class="stars">' + "".join(STAR.format(c="#c58b3a" if i < full else "#d9d1c5") for i in range(5)) + "</span>"


def rating(p):
    return f'<div class="rating">{stars(p["rating"])}<b>{p["rating"]}</b><span>({p["reviews"]:,})</span></div>'


def page(title, body, bag=0, nav=None, search=""):
    navs = "".join(f'<a href="/search"{" class=on" if n == nav else ""}>{n}</a>' for n in ["Kettles", "Brewing", "Grinders", "Cups", "Journal"])
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(title)}</title><link rel="icon" href="/assets/favicon.png"><link rel="stylesheet" href="/assets/style.css">{MEASURE}</head>
<body>
<div class="notice"><span><b>Free delivery</b> on orders over €50</span><span>30-night home trial on every kettle</span><span>Two-year warranty</span></div>
<header class="top"><div class="wrap">
<a class="logo" href="/" data-m="logo">{LOGO}steepwell</a>
<nav class="main">{navs}</nav>
<form class="search" action="/search" method="get" role="search">{SEARCH}
<input name="q" value="{esc(search)}" placeholder="Search kettles, drippers, grinders" aria-label="Search" autocomplete="off" data-m="search"></form>
<div class="icons"><a class="bag" href="/bag" data-m="bag">{BAG}Bag <span class="count{' zero' if not bag else ''}">{bag}</span></a></div>
</div></header>
<main class="wrap">
{body}
</main>
<footer><div class="wrap">
<div><a class="logo" href="/">{LOGO}steepwell</a><p class="muted" style="margin-top:14px;max-width:300px">Tools for slow coffee and good tea, designed in a small studio and built to last.</p></div>
<div><h4>Shop</h4><p>Kettles</p><p>Brewing</p><p>Grinders</p><p>Cups</p></div>
<div><h4>Help</h4><p>Delivery</p><p>Returns</p><p>Warranty</p><p>Contact</p></div>
<div><h4>Studio</h4><p>Journal</p><p>Brew guides</p><p>Stockists</p></div>
</div><div class="demo-note">Steepwell is a made-up shop for a demo. Nothing here is sold, charged or shipped.</div></footer>
</body></html>
"""


def card(pid, extra="", badge=None, m=None):
    p = PRODUCTS[pid]
    sw = "".join(f'<i style="background:{c}" title="{esc(n)}"></i>' for n, c in p["colours"])
    b = f'<span class="badge">{badge}</span>' if badge else ""
    mm = f' data-m="{m}"' if m else ""
    return f"""<div class="card"><a href="/p/{pid}"{mm}><div class="ph">{b}<img src="/assets/img/{p['img']}.webp" alt="{esc(p['name'])}"></div>
<h3>{esc(p['name'])}</h3></a><div class="muted" style="font-size:13.5px">{esc(p['colour'])}</div>
<div class="meta"><span class="price">€{p['price']}</span><span class="swatches">{sw}</span></div>{rating(p)}{extra}</div>"""


def home():
    body = f"""
<section class="hero"><img src="/assets/img/hero.webp" alt="A Pour kettle, a Cone dripper on a Carafe, and two Stack mugs on an oak counter">
<div class="copy"><h1 class="serif">Slow coffee,<br><em>beautifully</em> made.</h1>
<p>Kettles, drippers and grinders for the ten quiet minutes that start your day.</p>
<a class="btn" href="/search">Shop kettles</a></div></section>
<div class="section-h"><h2 class="serif">Bestsellers</h2><a href="/search">View all</a></div>
<div class="grid">{card("pour", badge="Bestseller")}{card("cone")}{card("mill", badge="New")}{card("carafe")}</div>
<div class="values">
<div class="value"><h3>Tested in our studio</h3><p>Every piece brews a hundred cups with us before it reaches you.</p></div>
<div class="value"><h3>30 nights at home</h3><p>Try a kettle for a month. If it isn't right, we collect it for free.</p></div>
<div class="value"><h3>Repairable</h3><p>Spare bases, lids and handles for ten years after you buy.</p></div>
</div>"""
    return page("Steepwell · Tools for slow coffee and good tea", body)


def search():
    tray = """<div class="tray" id="tray"><span id="tray-n">Compare 2 kettles</span><span class="thumbs" id="tray-t"></span>
<a class="btn" href="/compare" data-m="compare-go">Compare</a></div>
<script>
const picked=new Set();
document.querySelectorAll(".compare-box").forEach(b=>b.addEventListener("click",e=>{e.preventDefault();const id=b.dataset.id;
picked.has(id)?picked.delete(id):picked.add(id);b.classList.toggle("on",picked.has(id));
document.getElementById("tray").classList.toggle("up",picked.size>0);
document.getElementById("tray-n").textContent=picked.size>1?`Compare ${picked.size} kettles`:"Pick one more to compare";
document.getElementById("tray-t").innerHTML=[...picked].map(i=>`<img src="/assets/img/${i}.webp" alt="">`).join("")}));
</script>"""
    cmp = lambda pid: f'<label class="compare-box" data-id="{pid}" data-m="compare-{pid}"><i></i>Compare</label>'
    body = f"""
<div class="results-head"><div><div class="crumbs"><span>Shop</span><span>/</span><span>Search</span></div>
<h1 class="serif">Kettles</h1></div><div class="muted" style="font-size:14px">2 kettles · 2 to brew with</div></div>
<div class="filters"><span class="chip on">All</span><span class="chip">Electric</span><span class="chip">Gooseneck</span><span class="chip">Under €80</span><span class="chip">In stock</span></div>
<div class="grid">{card("pour", cmp("pour"), badge="Bestseller", m="card-pour")}{card("rapid", cmp("rapid"), m="card-rapid")}{card("cone", badge="Goes with kettles")}{card("carafe")}</div>
{tray}"""
    return page("Search results for “kettle” · Steepwell", body, nav="Kettles", search="kettle")


def compare():
    a, b = PRODUCTS["pour"], PRODUCTS["rapid"]

    def prod(pid, p):
        return f"""<div class="prod"><div class="ph"><img src="/assets/img/{p['img']}.webp" alt="{esc(p['name'])}"></div>
<div><h2 class="serif">{esc(p['short'])}</h2><div class="muted" style="font-size:13.5px">{esc(p['name'])} · {esc(p['colour'])}</div>
<div class="price">€{p['price']}.00</div>{rating(p)}
<a class="btn" style="margin-top:14px" href="/bag" data-m="add-{pid}">Add to bag</a></div></div>"""
    wins = {"Spout": 1, "Temperature": 1, "Holds temperature": 1, "Boils 1 litre": 2, "Capacity": 2, "Brew timer": 1}
    specs = "".join(f'<div class="spec"><div>{k}</div><div class="{"win" if wins.get(k) == 1 else ""}">{x}</div>'
                    f'<div class="{"win" if wins.get(k) == 2 else ""}">{y}</div></div>' for k, x, y in COMPARE)

    def quotes(pid):
        return "".join(f'<div class="quote">{stars(n)}<b>{esc(t)}</b><p>{esc(q)}</p><div class="who">{esc(w)} · Verified buyer</div></div>'
                       for n, w, t, q in REVIEWS[pid][:2])
    body = f"""
<div class="cmp"><div class="intro"><div class="crumbs" style="margin-top:8px"><span>Kettles</span><span>/</span><span>Compare</span></div>
<h1 class="serif">Side by side</h1><p class="muted" style="font-size:14px;margin:0">Dots mark the stronger of the two.</p></div>
{prod("pour", a)}{prod("rapid", b)}</div>
<div style="margin-top:26px">{specs}</div>
<div class="quotes"><div><h2 class="serif" style="font-size:30px;margin:0">What owners say</h2></div><div>{quotes("pour")}</div><div>{quotes("rapid")}</div></div>"""
    return page("Compare Pour and Rapid · Steepwell", body, nav="Kettles")


def product(pid):
    p = PRODUCTS[pid]
    sub = p.get("alt", p["img"])
    third = {"pour": "pour-sage", "rapid": "mugs"}.get(pid, "mugs")
    feats = {"pour": ["0.9 L, enough for two cups of pour-over", "Set 40–100 °C to the degree; holds it for 60 minutes",
                      "Flow-controlled gooseneck spout", "Brew timer built into the base", "Walnut handle and lid knob"],
             "rapid": ["1.7 L, boils a litre in 2 min 40 s", "Four presets: 70, 80, 90 and 100 °C", "30-minute keep-warm",
                       "Wide spout with limescale filter", "Brushed stainless steel"]}.get(pid, [p["blurb"]])
    li = "".join(f"<li>{esc(f)}</li>" for f in feats)
    sw = "".join(f'<span class="chip{" on" if i == 0 else ""}">{esc(n)}</span>' for i, (n, c) in enumerate(p["colours"]))
    body = f"""
<div class="pdp"><div class="gallery"><div class="main"><img src="/assets/img/{p['img']}.webp" alt="{esc(p['name'])}"></div>
<div class="sub"><img src="/assets/img/{sub}.webp" alt=""></div><div class="sub"><img src="/assets/img/{third}.webp" alt=""></div></div>
<div><div class="crumbs"><span>Shop</span><span>/</span><span>Kettles</span></div><h1 class="serif">{esc(p['name'])}</h1>{rating(p)}
<div class="price">€{p['price']}.00</div><p style="font-size:16px;color:#4a443d">{esc(p['blurb'])}</p>
<div style="display:flex;gap:8px;margin:18px 0 22px">{sw}</div>
<a class="btn" href="/bag" style="width:100%">Add to bag · €{p['price']}.00</a>
<ul style="margin-top:26px">{li}</ul></div></div>"""
    return page(f"{p['name']} · Steepwell", body, nav="Kettles")


def bag():
    p = PRODUCTS["pour"]
    body = f"""
<div class="steps"><b>Bag</b><i></i><span>Details</span><i></i><span>Payment</span></div>
<div class="two"><div><h1 class="serif" style="font-size:46px;margin:6px 0 18px">Your bag</h1>
<div class="panel"><div class="line"><div class="ph"><img src="/assets/img/pour.webp" alt=""></div>
<div><h3>{esc(p['name'])}</h3><div class="muted" style="font-size:13.5px">Slate · 0.9 L</div><div class="qty"><span>−</span><b>1</b><span>+</span></div></div>
<div class="price">€79.00</div></div></div>
<div class="panel" style="margin-top:16px;display:flex;gap:16px;align-items:center"><div class="card-ic" style="background:linear-gradient(135deg,#c58b3a,#a56d26)"></div>
<div style="font-size:14px"><b>30-night home trial.</b> <span class="muted">Not the right kettle? We collect it for free.</span></div></div></div>
<div class="panel"><h2 class="h serif">Summary</h2><div class="sum"><span>Subtotal</span><span>€79.00</span></div>
<div class="sum"><span>Delivery</span><span>Free</span></div><div class="sum total"><span>Total</span><span>€79.00</span></div>
<a class="btn" href="/checkout" style="width:100%;margin-top:18px" data-m="continue">Continue to delivery</a>
<div class="secure">Taxes included · Free returns</div></div></div>"""
    return page("Your bag · Steepwell", body, bag=1)


def checkout():
    body = f"""
<div class="steps"><span>Bag</span><i></i><span>Details</span><i></i><b>Payment</b></div>
<div class="two"><div><h1 class="serif" style="font-size:46px;margin:6px 0 18px">Almost there</h1>
<div class="panel"><h2 class="h serif">Delivery</h2>
<div class="field"><small>Deliver to</small>Ada Example · Rua das Flores 12, 1200-195 Lisboa</div>
<div class="opt on"><span class="dot"></span><div>Standard<div class="muted" style="font-size:13px">Arrives Thursday</div></div><span class="r">Free</span></div>
<div class="opt"><span class="dot"></span><div>Next day<div class="muted" style="font-size:13px">Arrives tomorrow</div></div><span class="r">€6.00</span></div></div>
<div class="panel" style="margin-top:16px"><h2 class="h serif">Payment</h2>
<div class="opt on"><span class="dot"></span><span class="card-ic"></span><div>Saved card ending 4242<div class="muted" style="font-size:13px">Ada Example · expires 08/29</div></div></div></div></div>
<div class="panel"><h2 class="h serif">Your order</h2>
<div class="mini"><div class="ph"><img src="/assets/img/pour.webp" alt=""></div><div><b>Pour gooseneck kettle</b><div class="muted">Slate · Qty 1</div></div><span>€79.00</span></div>
<div class="sum"><span>Subtotal</span><span>€79.00</span></div><div class="sum"><span>Delivery</span><span>Free</span></div>
<div class="sum total"><span>Total</span><span>€79.00</span></div>
<form action="/order" method="post"><button class="btn" style="width:100%;margin-top:18px" data-m="pay">Pay €79.00</button></form>
<div class="secure">Demo shop: nothing is charged</div></div></div>"""
    return page("Payment · Steepwell", body, bag=1)


def order():
    body = """
<div class="done"><div class="tick"><svg width="28" height="28" viewBox="0 0 28 28" fill="none" stroke="#fff" stroke-width="3"><path d="m7 14.5 5 5L21.5 9" stroke-linecap="round" stroke-linejoin="round"/></svg></div>
<h1 class="serif">Thank you, Ada.</h1><p style="font-size:17px;color:#4a443d;margin:0 0 6px">Order <b>SW-48213</b> is confirmed: Pour gooseneck kettle in Slate, €79.00.</p>
<p class="muted" style="margin:0 0 28px">It arrives Thursday at Rua das Flores 12. We'll email you when it ships.</p>
<a class="btn ghost" href="/">Keep browsing</a>
<p class="muted" style="font-size:12.5px;margin-top:30px">Steepwell is a demo shop: nothing was charged or shipped.</p></div>"""
    return page("Order confirmed · Steepwell", body)


def main():
    os.makedirs(os.path.join(SITE, "p"), exist_ok=True)
    out = {"index.html": home(), "search.html": search(), "compare.html": compare(), "bag.html": bag(),
           "checkout.html": checkout(), "order.html": order()}
    for pid in PRODUCTS:
        out[f"p/{pid}.html"] = product(pid)
    for name, text in out.items():
        with open(os.path.join(SITE, name), "w") as f:
            f.write(text)
    with open(os.path.join(SITE, "assets", "style.css"), "w") as f:
        f.write(CSS.strip() + "\n")
    print("wrote", len(out), "pages")


if __name__ == "__main__":
    main()
