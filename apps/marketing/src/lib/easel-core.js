// @ts-check
// A shared Easel's schema and limits (P19c; docs/dev/sharing-service.md, "Easel links"), checked all or nothing, the
// way AircKit's EaselPublic writes it. Plain JavaScript so the /e viewer, the API and its tests use this one copy.
//
// What a link holds is a read-only snapshot of what was on the Easel when it was shared: blocks in stacking order
// (back to front), each a frame on the Easel's plane (points, y down) with one kind of content. Colours are resolved
// to hex (the Easel's light look). Pictures are named by the SHA-256 of their bytes and uploaded separately. Nothing
// else: no ids, no undo history, no live Capture's profile, region or state (a live Capture is its last picture and
// its page's address), no cookies, no tokens.
import { isSafeAddress } from "./share-core.js";

export const EASEL_VERSION = 1;
export const MAX_EASEL_JSON = 1_048_576;
export const MAX_BLOCKS = 2_000;
export const MAX_ASSETS = 200;
/** One picture: under Vercel's 4.5 MB request body limit. */
export const MAX_ASSET_BYTES = 4_000_000;
export const MAX_TOTAL_ASSET_BYTES = 20_000_000;
const TITLE = 120, TEXT = 20_000, PARAGRAPHS = 2_000, RUNS = 4_000, LABEL = 500, COORD = 1_000_000, SIDE = 100_000;

/** @typedef {"damaged" | "tooLarge" | "unsafeAddress" | "newerVersion"} EaselFailure */
/** @typedef {{ x: number, y: number }} Point */
/** @typedef {{ x: number, y: number, width: number, height: number }} Frame */
/** @typedef {{ text: string, bold?: true, italic?: true, underline?: true, strike?: true, code?: true, link?: string }} Run */
/** @typedef {{ kind: "paragraph" | "heading1" | "heading2" | "heading3" | "bullet" | "numbered" | "checkbox", indent?: number, checked?: true, runs: Run[] }} Paragraph */
/**
 * @typedef {{ type: "text", paragraphs: Paragraph[], font: "clean" | "mono" | "fancy" | "hip", size: number, color: string, alignment: "left" | "center" | "right" }
 *   | { type: "image", asset: string, alt?: string }
 *   | { type: "shape", kind: "rectangle" | "ellipse", fill?: string, stroke?: string, strokeWidth: number, cornerRadius: number }
 *   | { type: "line", from: Point, to: Point, startHead: boolean, endHead: boolean, color: string, width: number }
 *   | { type: "link", url: string, title?: string, detail?: string, image?: string }
 *   | { type: "capture", asset: string, url?: string, title?: string }} Content
 */
/** @typedef {{ frame: Frame, rotation?: number, content: Content }} Block */
/** @typedef {{ name: string, size: number }} Asset */
/** @typedef {{ kind: "easel", version: number, title: string, background: string, blocks: Block[], assets: Asset[] }} Easel */

export const easelMessages = {
  damaged: "This Easel can't be shared: it isn't in the form aircbrowser.com takes.",
  tooLarge: "This Easel is too large to share. Share a selection, or fewer pictures.",
  unsafeAddress: "This Easel has an address that can't be shared (only web addresses can).",
  newerVersion: "This Easel was shared by a newer version of Airc.",
};

export class EaselRefused extends Error {
  /** @param {EaselFailure} why */
  constructor(why) {
    super(why);
    /** @type {EaselFailure} */
    this.why = why;
  }
}

/** @param {EaselFailure} why @returns {never} */
const fail = (why) => {
  throw new EaselRefused(why);
};

/** @param {unknown} v @returns {v is Record<string, unknown>} */
const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
/** @param {string} s */
const hasControl = (s) => /[\u0000-\u0008\u000b-\u001f\u007f-\u009f‪-‮⁦-⁩]/u.test(s);

/** `o` has exactly these keys (the optional ones may be missing), none of them null.
 *  @param {unknown} o @param {string[]} required @param {string[]} [optional] @returns {Record<string, unknown>} */
function keys(o, required, optional = []) {
  if (!isObject(o)) return fail("damaged");
  const k = Object.keys(o);
  if (!required.every((x) => x in o) || !k.every((x) => required.includes(x) || optional.includes(x))) fail("damaged");
  if (k.some((x) => o[x] === null)) fail("damaged");
  return o;
}

/** @param {unknown} v @param {number} lo @param {number} hi */
function num(v, lo, hi) {
  if (typeof v !== "number" || !Number.isFinite(v) || v < lo || v > hi) return fail("damaged");
  return v;
}

/** Text that may be empty (a title, a run), with no control or direction-override characters but newlines and tabs.
 *  @param {unknown} v @param {number} limit @param {boolean} [lines] */
function str(v, limit, lines = false) {
  if (typeof v !== "string" || v.length > limit || hasControl(v) || (!lines && /[\n\t]/.test(v))) return fail("damaged");
  return v;
}

/** A label shown on its own (a link's title): not empty. @param {unknown} v */
const label = (v) => {
  const s = str(v, LABEL);
  if (!s.trim()) fail("damaged");
  return s;
};

/** #RRGGBB or #RRGGBBAA, upper case. @param {unknown} v */
function hex(v) {
  if (typeof v !== "string" || !/^#[0-9A-F]{6}(?:[0-9A-F]{2})?$/.test(v)) return fail("damaged");
  return v;
}

/** A picture's name: the SHA-256 of its bytes and its type. */
export const ASSET = /^[0-9a-f]{64}\.(png|jpg|gif|webp)$/;
export const assetTypes = /** @type {const} */ ({ png: "image/png", jpg: "image/jpeg", gif: "image/gif", webp: "image/webp" });

/** The type the bytes are (by their first bytes), or null: only PNG, JPEG, GIF and WebP pictures are taken.
 *  @param {Uint8Array} b @returns {"png" | "jpg" | "gif" | "webp" | null} */
export function sniff(b) {
  const at = (/** @type {number[]} */ sig, o = 0) => sig.every((x, i) => b[o + i] === x);
  if (at([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "png";
  if (at([0xff, 0xd8, 0xff])) return "jpg";
  if (at([0x47, 0x49, 0x46, 0x38]) && (b[4] === 0x37 || b[4] === 0x39) && b[5] === 0x61) return "gif";
  if (at([0x52, 0x49, 0x46, 0x46]) && at([0x57, 0x45, 0x42, 0x50], 8)) return "webp";
  return null;
}

/** An address a link may carry (share-core's rule: absolute http(s), no credentials). @param {unknown} v */
function address(v) {
  if (typeof v !== "string") return fail("damaged");
  if (!isSafeAddress(v)) fail("unsafeAddress");
  return v;
}

/** @param {unknown} v @returns {Point} */
function point(v) {
  const o = keys(v, ["x", "y"]);
  return { x: num(o.x, -COORD, COORD), y: num(o.y, -COORD, COORD) };
}

/** @param {unknown} v @returns {Frame} */
function frame(v) {
  const o = keys(v, ["x", "y", "width", "height"]);
  return { x: num(o.x, -COORD, COORD), y: num(o.y, -COORD, COORD), width: num(o.width, 0, SIDE), height: num(o.height, 0, SIDE) };
}

const KINDS = ["paragraph", "heading1", "heading2", "heading3", "bullet", "numbered", "checkbox"];
const MARKS = ["bold", "italic", "underline", "strike", "code"];

/** @param {unknown} v @param {{ text: number, runs: number }} count @returns {Paragraph} */
function paragraph(v, count) {
  const o = keys(v, ["kind", "runs"], ["indent", "checked"]);
  if (typeof o.kind !== "string" || !KINDS.includes(o.kind)) fail("damaged");
  if (!Array.isArray(o.runs)) fail("damaged");
  /** @type {Paragraph} */
  const p = { kind: /** @type {Paragraph["kind"]} */ (o.kind), runs: [] };
  if ("indent" in o) {
    if (!Number.isInteger(o.indent)) fail("damaged");
    p.indent = num(o.indent, 0, 8);
  }
  if ("checked" in o) {
    if (o.checked !== true || o.kind !== "checkbox") fail("damaged");
    p.checked = true;
  }
  for (const r of /** @type {unknown[]} */ (o.runs)) {
    if (++count.runs > RUNS) fail("tooLarge");
    const ro = keys(r, ["text"], [...MARKS, "link"]);
    const text = str(ro.text, TEXT, true);
    count.text += text.length;
    if (count.text > TEXT) fail("tooLarge");
    /** @type {Run} */
    const run = { text };
    for (const m of MARKS) {
      if (m in ro) {
        if (ro[m] !== true) fail("damaged");
        /** @type {any} */ (run)[m] = true;
      }
    }
    if ("link" in ro) run.link = address(ro.link);
    p.runs.push(run);
  }
  return p;
}

/** @param {unknown} v @param {Set<string>} used @returns {Content} */
function content(v, used) {
  if (!isObject(v) || typeof v.type !== "string") return fail("damaged");
  /** @param {unknown} a */
  const asset = (a) => {
    if (typeof a !== "string" || !ASSET.test(a)) return fail("damaged");
    used.add(a);
    return a;
  };
  switch (v.type) {
    case "text": {
      const o = keys(v, ["type", "paragraphs", "font", "size", "color", "alignment"]);
      if (!Array.isArray(o.paragraphs) || o.paragraphs.length > PARAGRAPHS) fail("damaged");
      if (!["clean", "mono", "fancy", "hip"].includes(/** @type {string} */ (o.font))) fail("damaged");
      if (!["left", "center", "right"].includes(/** @type {string} */ (o.alignment))) fail("damaged");
      const count = { text: 0, runs: 0 };
      return {
        type: "text",
        paragraphs: /** @type {unknown[]} */ (o.paragraphs).map((p) => paragraph(p, count)),
        font: /** @type {any} */ (o.font),
        size: num(o.size, 4, 400),
        color: hex(o.color),
        alignment: /** @type {any} */ (o.alignment),
      };
    }
    case "image": {
      const o = keys(v, ["type", "asset"], ["alt"]);
      return { type: "image", asset: asset(o.asset), ...("alt" in o ? { alt: str(o.alt, LABEL) } : {}) };
    }
    case "shape": {
      const o = keys(v, ["type", "kind", "strokeWidth", "cornerRadius"], ["fill", "stroke"]);
      if (o.kind !== "rectangle" && o.kind !== "ellipse") fail("damaged");
      return {
        type: "shape",
        kind: o.kind,
        ...("fill" in o ? { fill: hex(o.fill) } : {}),
        ...("stroke" in o ? { stroke: hex(o.stroke) } : {}),
        strokeWidth: num(o.strokeWidth, 0, 200),
        cornerRadius: num(o.cornerRadius, 0, SIDE),
      };
    }
    case "line": {
      const o = keys(v, ["type", "from", "to", "startHead", "endHead", "color", "width"]);
      if (typeof o.startHead !== "boolean" || typeof o.endHead !== "boolean") fail("damaged");
      return { type: "line", from: point(o.from), to: point(o.to), startHead: o.startHead, endHead: o.endHead, color: hex(o.color), width: num(o.width, 0.25, 200) };
    }
    case "link": {
      const o = keys(v, ["type", "url"], ["title", "detail", "image"]);
      return {
        type: "link",
        url: address(o.url),
        ...("title" in o ? { title: label(o.title) } : {}),
        ...("detail" in o ? { detail: str(o.detail, 2 * LABEL, true) } : {}),
        ...("image" in o ? { image: asset(o.image) } : {}),
      };
    }
    case "capture": {
      const o = keys(v, ["type", "asset"], ["url", "title"]);
      return {
        type: "capture",
        asset: asset(o.asset),
        ...("url" in o ? { url: address(o.url) } : {}),
        ...("title" in o ? { title: label(o.title) } : {}),
      };
    }
    default:
      return fail("damaged");
  }
}

/** The shared Easel in `json`, fully checked; any problem throws EaselRefused.
 *  @param {string} json @returns {Easel} */
export function decodeEasel(json) {
  if (json.length > MAX_EASEL_JSON) fail("tooLarge");
  /** @type {unknown} */
  let top;
  try {
    top = JSON.parse(json);
  } catch {
    return fail("damaged");
  }
  if (!isObject(top) || top.kind !== "easel") return fail("damaged");
  if (typeof top.version === "number" && top.version > EASEL_VERSION) fail("newerVersion");
  const o = keys(top, ["kind", "version", "title", "background", "blocks", "assets"]);
  if (o.version !== EASEL_VERSION) fail("damaged");
  if (!Array.isArray(o.blocks) || !Array.isArray(o.assets)) return fail("damaged");
  if (o.blocks.length > MAX_BLOCKS || o.assets.length > MAX_ASSETS) fail("tooLarge");
  /** @type {Set<string>} */
  const used = new Set();
  const blocks = /** @type {unknown[]} */ (o.blocks).map((b) => {
    const bo = keys(b, ["frame", "content"], ["rotation"]);
    /** @type {Block} */
    const block = { frame: frame(bo.frame), content: content(bo.content, used) };
    if ("rotation" in bo) block.rotation = num(bo.rotation, -2 * Math.PI, 2 * Math.PI);
    return block;
  });
  if (blocks.length === 0) fail("damaged");
  /** @type {Asset[]} */
  const assets = [];
  let total = 0;
  for (const a of /** @type {unknown[]} */ (o.assets)) {
    const ao = keys(a, ["name", "size"]);
    if (typeof ao.name !== "string" || !ASSET.test(ao.name) || !Number.isInteger(ao.size)) fail("damaged");
    const size = num(ao.size, 1, MAX_ASSET_BYTES);
    total += size;
    if (total > MAX_TOTAL_ASSET_BYTES) fail("tooLarge");
    if (assets.some((x) => x.name === ao.name)) fail("damaged");
    assets.push({ name: /** @type {string} */ (ao.name), size });
  }
  // Every picture a block shows is listed, and only those.
  if (assets.length !== used.size || !assets.every((a) => used.has(a.name))) fail("damaged");
  return { kind: "easel", version: EASEL_VERSION, title: str(o.title, TITLE), background: hex(o.background), blocks, assets };
}

/** The box every block covers (a line's by its ends), or null. @param {Block[]} blocks */
export function contentBounds(blocks) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const b of blocks) {
    const f = b.frame, r = b.rotation ?? 0;
    const c = Math.abs(Math.cos(r)), s = Math.abs(Math.sin(r));
    const w = f.width * c + f.height * s, h = f.width * s + f.height * c;
    const cx = f.x + f.width / 2, cy = f.y + f.height / 2;
    x0 = Math.min(x0, cx - w / 2); y0 = Math.min(y0, cy - h / 2);
    x1 = Math.max(x1, cx + w / 2); y1 = Math.max(y1, cy + h / 2);
  }
  return Number.isFinite(x0) ? { x: x0, y: y0, width: x1 - x0, height: y1 - y0 } : null;
}

/** The name an Easel goes by. @param {Easel} e */
export const easelTitle = (e) => e.title.trim() || "Untitled Easel";
