// A shared Easel as HTML (P19c): every block absolutely placed on a board that keeps the Easel's proportions at any
// width. Positions are percentages of the board; sizes in text are container query units (cqw) of its width, so the
// whole board scales as one picture would, without scripts. Every string goes through esc(); addresses were checked by
// easel-core.js (http(s) only) and open in a new tab without a referrer. AircKit's EaselHTML writes the same board for
// File › Export Easel… (HTML), so an exported Easel and a shared one look alike.
import { contentBounds } from "../../src/lib/easel-core.js";
import { esc } from "./http.js";

/** @typedef {import("../../src/lib/easel-core.js").Easel} Easel */
/** @typedef {import("../../src/lib/easel-core.js").Block} Block */
/** @typedef {import("../../src/lib/easel-core.js").Run} Run */
/** @typedef {import("../../src/lib/easel-core.js").Paragraph} Paragraph */

export const MARGIN = 24;

export const BOARD_CSS = `
.easel { position: relative; width: 100%; margin: 24px auto 0; container-type: inline-size; overflow: hidden;
  border-radius: 12px; box-shadow: 0 0 0 1px rgb(20 17 15 / 0.08); }
.easel .b { position: absolute; box-sizing: border-box; transform-origin: 50% 50%; }
.easel .tx { overflow: hidden; line-height: 1.3; overflow-wrap: anywhere; }
.easel .tx p, .easel .tx h1, .easel .tx h2, .easel .tx h3 { margin: 0; font-size: 1em; font-weight: inherit; }
.easel .tx h1 { font-size: 1.6em; font-weight: 700; } .easel .tx h2 { font-size: 1.3em; font-weight: 650; }
.easel .tx h3 { font-size: 1.12em; font-weight: 650; } .easel .tx .done { opacity: 0.55; text-decoration: line-through; }
.easel .tx code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }
.easel .tx a { color: inherit; text-decoration: underline; }
.easel .f-clean { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
.easel .f-mono { font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace; }
.easel .f-fancy { font-family: ui-serif, "New York", Georgia, serif; }
.easel .f-hip { font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; font-stretch: 125%; }
.easel img { display: block; width: 100%; height: 100%; object-fit: cover; }
.easel .pic { overflow: hidden; box-shadow: 0 0.2cqw 0.8cqw rgb(0 0 0 / 0.14); }
.easel .lc { display: flex; overflow: hidden; background: #fff; box-shadow: 0 0 0 1px rgb(0 0 0 / 0.1), 0 0.2cqw 0.8cqw rgb(0 0 0 / 0.08);
  color: rgb(20 20 20); font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; text-decoration: none; }
.easel .lc .ci { flex: none; height: 100%; width: auto; aspect-ratio: 1; object-fit: cover; }
.easel .lc .cb { display: flex; flex-direction: column; justify-content: center; min-width: 0; }
.easel .lc .ct { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.easel .lc .cd { opacity: 0.6; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.easel .lc .ch { opacity: 0.45; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.easel svg { display: block; width: 100%; height: 100%; overflow: visible; }
`;

/** A number for CSS: at most four decimals. @param {number} n */
const n = (n) => String(Math.round(n * 10000) / 10000);

/** How the board maps the plane: its origin (top left, in points) and its size. @param {Easel} e */
export function boardOf(e) {
  const b = contentBounds(e.blocks) ?? { x: 0, y: 0, width: 1, height: 1 };
  return { x: b.x - MARGIN, y: b.y - MARGIN, width: Math.max(1, b.width + 2 * MARGIN), height: Math.max(1, b.height + 2 * MARGIN) };
}

/** @param {Run} r */
function run(r) {
  let s = esc(r.text).replace(/\n/g, "<br>");
  if (r.code) s = `<code>${s}</code>`;
  if (r.italic) s = `<em>${s}</em>`;
  if (r.bold) s = `<strong>${s}</strong>`;
  if (r.underline) s = `<u>${s}</u>`;
  if (r.strike) s = `<s>${s}</s>`;
  if (r.link) s = `<a href="${esc(r.link)}" target="_blank" rel="noopener noreferrer nofollow">${s}</a>`;
  return s;
}

/** The paragraphs of a text block: lists as marked lines, numbered in order per level. @param {Paragraph[]} ps */
function paragraphs(ps) {
  /** @type {number[]} */
  const numbers = [];
  return ps.map((p) => {
    const inner = p.runs.map(run).join("") || "<br>";
    const indent = p.indent ?? 0;
    if (p.kind !== "numbered") numbers.length = Math.min(numbers.length, indent);
    switch (p.kind) {
      case "heading1": return `<h1>${inner}</h1>`;
      case "heading2": return `<h2>${inner}</h2>`;
      case "heading3": return `<h3>${inner}</h3>`;
      case "paragraph": return `<p>${inner}</p>`;
      default: {
        let mark = "•";
        if (p.kind === "numbered") {
          numbers.length = indent + 1;
          numbers[indent] = (numbers[indent] ?? 0) + 1;
          mark = `${numbers[indent]}.`;
        } else if (p.kind === "checkbox") mark = p.checked ? "☑" : "☐";
        return `<p style="padding-left:${n(1.3 * (indent + 1))}em;text-indent:-1.3em"${p.checked ? ' class="done"' : ""}>${mark}&#8194;${inner}</p>`;
      }
    }
  }).join("");
}

/**
 * The board's HTML. `asset(name)` is a picture's address (`/e/<id>/a/<name>` on the site, `assets/<name>` in an export).
 * @param {Easel} e @param {(name: string) => string} asset
 */
export function board(e, asset) {
  const B = boardOf(e);
  /** Points to cqw (a share of the board's width). @param {number} pt */
  const cq = (pt) => `${n((pt / B.width) * 100)}cqw`;
  /** @param {{ x: number, y: number, width: number, height: number }} f @param {number} [rot] */
  const place = (f, rot = 0) =>
    `left:${n(((f.x - B.x) / B.width) * 100)}%;top:${n(((f.y - B.y) / B.height) * 100)}%;width:${n((f.width / B.width) * 100)}%;` +
    `height:${n((f.height / B.height) * 100)}%` + (rot ? `;transform:rotate(${n(rot)}rad)` : "");
  const link = (/** @type {string} */ url, /** @type {string} */ inner, attrs = "") =>
    `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer nofollow"${attrs}>${inner}</a>`;
  const blocks = e.blocks.map((b) => {
    const c = b.content, f = b.frame, rot = b.rotation ?? 0;
    switch (c.type) {
      case "text":
        return `<div class="b tx f-${c.font}" style="${place(f, rot)};font-size:${cq(c.size)};padding:${cq(4)};color:${c.color};text-align:${c.alignment}">` +
          `${paragraphs(c.paragraphs)}</div>`;
      case "image":
        return `<div class="b pic" style="${place(f, rot)};border-radius:${cq(6)}"><img src="${esc(asset(c.asset))}" alt="${esc(c.alt ?? "")}" loading="lazy"></div>`;
      case "capture": {
        const img = `<img src="${esc(asset(c.asset))}" alt="${esc(c.title ?? "A picture of a page")}" loading="lazy">`;
        return `<div class="b pic" style="${place(f, rot)};border-radius:${cq(10)}">${c.url ? link(c.url, img) : img}</div>`;
      }
      case "shape": {
        const border = c.stroke ? `;border:${cq(c.strokeWidth)} solid ${c.stroke}` : "";
        const radius = c.kind === "ellipse" ? "50%" : cq(Math.min(c.cornerRadius, f.width / 2, f.height / 2));
        return `<div class="b" style="${place(f, rot)};background:${c.fill ?? "transparent"};border-radius:${radius}${border}"></div>`;
      }
      case "line": {
        const pad = c.width / 2 + (c.startHead || c.endHead ? c.width * 3 + 6 : 2);
        const box = { x: f.x - pad, y: f.y - pad, width: f.width + 2 * pad, height: f.height + 2 * pad };
        const head = (/** @type {{x:number,y:number}} */ tip, /** @type {{x:number,y:number}} */ from) => {
          const a = Math.atan2(tip.y - from.y, tip.x - from.x), l = c.width * 3 + 4, w = 0.5;
          const p = [tip, { x: tip.x - l * Math.cos(a - w), y: tip.y - l * Math.sin(a - w) }, { x: tip.x - l * Math.cos(a + w), y: tip.y - l * Math.sin(a + w) }];
          return `<polygon points="${p.map((q) => `${n(q.x)},${n(q.y)}`).join(" ")}" fill="${c.color}"/>`;
        };
        return `<div class="b" style="${place(box)}"><svg viewBox="${n(box.x)} ${n(box.y)} ${n(box.width)} ${n(box.height)}" aria-hidden="true">` +
          `<line x1="${n(c.from.x)}" y1="${n(c.from.y)}" x2="${n(c.to.x)}" y2="${n(c.to.y)}" stroke="${c.color}" stroke-width="${n(c.width)}" stroke-linecap="round"/>` +
          (c.endHead ? head(c.to, c.from) : "") + (c.startHead ? head(c.from, c.to) : "") + `</svg></div>`;
      }
      case "link": {
        let host = c.url;
        try { host = new URL(c.url).host.replace(/^www\./, ""); } catch { /* checked already */ }
        const inner = (c.image ? `<img class="ci" src="${esc(asset(c.image))}" alt="" loading="lazy">` : "") +
          `<span class="cb" style="padding:0 ${cq(14)};gap:${cq(2)}"><span class="ct" style="font-size:${cq(14)}">${esc(c.title ?? host)}</span>` +
          (c.detail ? `<span class="cd" style="font-size:${cq(12)}">${esc(c.detail)}</span>` : "") +
          `<span class="ch" style="font-size:${cq(11.5)}">${esc(host)}</span></span>`;
        return `<div class="b" style="${place(f, rot)}">${link(c.url, inner, ` class="lc" style="width:100%;height:100%;border-radius:${cq(12)}"`)}</div>`;
      }
      default:
        return "";
    }
  }).join("\n");
  return `<div class="easel" style="aspect-ratio:${n(B.width)} / ${n(B.height)};max-width:${Math.ceil(Math.max(B.width, 320))}px;background:${e.background}">\n${blocks}\n</div>`;
}
