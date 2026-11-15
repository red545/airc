// @ts-check
// The share snapshot's schema and limits (docs/dev/share-links.md), checked the way Airc checks it (AircKit ShareLink):
// all or nothing. Plain JavaScript so that both the /s viewer (through share-link.ts) and the sharing functions in
// api/ (Vercel's Node runtime, the API tests) use this one copy.

/** @typedef {"damaged" | "newerVersion" | "tooLarge" | "unsafeAddress" | "unsupported"} Failure */
/** @typedef {{ type: "tab", url: string, title?: string }} Tab */
/** @typedef {Tab | { type: "folder", name: string, items: Node[] } | { type: "split", axis: "horizontal" | "vertical", items: Tab[] }} Node */
/** @typedef {{ kind: "space" | "folder", name: string, icon?: string, items: Node[], tabs: number, folders: number }} TreeSnapshot */
/** @typedef {{ kind: "boost", name: string, site: string, author?: string, about?: string, code: boolean }} BoostSnapshot */
/** @typedef {TreeSnapshot | BoostSnapshot} Snapshot */

export const VERSION = 1;
export const MAX_PAYLOAD = 32_000;
export const MAX_JSON = 524_288;
export const MAX_TABS = 2_000;
export const MAX_NODES = 4_000;
export const MAX_DEPTH = 10;
const NAME = 200, TITLE = 500, URL_LIMIT = 4_096, ICON = 16;

/** @type {Record<Failure, string>} */
export const messages = {
  damaged: "This link is damaged or incomplete.",
  newerVersion: "This link was made by a newer version of Airc. Update Airc to open it.",
  tooLarge: "This link is too large to open.",
  unsafeAddress: "This link contains an address Airc doesn't open (only web addresses can be shared).",
  unsupported: "This browser can't read the link. Open it in Airc instead.",
};

export class Refused extends Error {
  /** @param {Failure} why */
  constructor(why) {
    super(why);
    /** @type {Failure} */
    this.why = why;
  }
}

/** @param {Failure} why @returns {never} */
export const fail = (why) => {
  throw new Refused(why);
};

/** @param {number} cp */
const isControl = (cp) => cp < 0x20 || (cp >= 0x7f && cp <= 0x9f);
/** @param {string} s */
const hasControl = (s) => [...s].some((c) => isControl(/** @type {number} */ (c.codePointAt(0))));
/** @param {unknown} v @returns {v is Record<string, unknown>} */
const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);

/** `o` has exactly these keys, none of them null.
 *  @param {Record<string, unknown>} o @param {string[]} required @param {string[]} [optional] */
function exact(o, required, optional = []) {
  const keys = Object.keys(o);
  if (!required.every((k) => k in o) || !keys.every((k) => required.includes(k) || optional.includes(k))) fail("damaged");
  if (keys.some((k) => o[k] === null)) fail("damaged");
}

/** A required string: 1 to `limit` UTF-16 units, not only whitespace, no control characters.
 *  @param {unknown} v @param {number} limit @returns {string} */
function text(v, limit) {
  if (typeof v !== "string" || v.length > limit || v.trim() === "" || hasControl(v)) return fail("damaged");
  return v;
}

/** An emoji icon: 1–16 UTF-16 units, each character non-ASCII with an emoji in it. @param {string} s */
export function isEmojiText(s) {
  if (!s || s.length > ICON || hasControl(s)) return false;
  const chars = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(s)].map((x) => x.segment);
  return chars.every((ch) => /[^\x00-\x7f]/.test(ch) && /\p{Emoji}/u.test(ch) && !/^[\x00-\x7f]+$/.test(ch));
}

/** The authority of an http(s) address, or null: absolute, with a host, no user name or password (an "@" at all).
 *  @param {string} s */
function authority(s) {
  const m = /^https?:\/\/([^/?#]*)/i.exec(s);
  if (!m || !m[1] || m[1].includes("@")) return null;
  const host = m[1].replace(/:\d*$/, "");
  return host && host !== "[]" ? host : null;
}

/** An address a link may carry: absolute http(s) with a host, no credentials, no whitespace, control characters or
 *  backslashes, at most 4,096 UTF-16 units. So javascript:, data:, file: and every other scheme are refused.
 *  @param {string} s */
export function isSafeAddress(s) {
  if (typeof s !== "string" || !s || s.length > URL_LIMIT || /\s|\\/u.test(s) || hasControl(s) || !authority(s)) return false;
  try {
    const u = new URL(s);
    return (u.protocol === "http:" || u.protocol === "https:") && u.hostname !== "" && u.username === "" && u.password === "";
  } catch {
    return false;
  }
}

/** The host to show for a tab without a title: the address's own host, as written. @param {string} url */
export const hostOf = (url) => authority(url) ?? url;

/** The deepest bracket nesting outside strings, counted up to `limit` + 1 (so a deep payload is refused before parsing).
 *  @param {string} json @param {number} limit */
function nesting(json, limit) {
  let depth = 0, deepest = 0, inString = false, escaped = false;
  for (let i = 0; i < json.length; i++) {
    const c = json[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
    } else if (c === '"') inString = true;
    else if (c === "[" || c === "{") {
      deepest = Math.max(deepest, ++depth);
      if (deepest > limit) return deepest;
    } else if (c === "]" || c === "}") depth--;
  }
  return deepest;
}

/** Airc's Boost file, version 1 or 2, without its picture: the same keys and types Airc's own reader accepts.
 *  @param {unknown} o @returns {BoostSnapshot} */
function boost(o) {
  if (!isObject(o) || "preview" in o) return fail("damaged");
  const b = o;
  const version = b.version;
  if (typeof version !== "number" || !Number.isInteger(version) || version < 1 || version > 2) fail("damaged");
  const two = version === 2;
  /** @param {unknown} v @param {string[]} required @param {string[]} optional */
  const keys = (v, required, optional) => {
    if (!isObject(v)) return fail("damaged");
    if (!required.every((k) => k in v && v[k] !== null) || !Object.keys(v).every((k) => required.includes(k) || optional.includes(k))) fail("damaged");
    return v;
  };
  keys(b, ["version", "name", "site", "createdAt", "colors", "font", "zaps", "css", "js"], ["scriptHost", ...(two ? ["id", "revision", "author", "about"] : [])]);
  const colors = keys(b.colors, ["hue", "tint", "brightness", "contrast", "invert"], two ? ["saturation"] : []);
  const font = keys(b.font, ["size"], two ? ["family", "case"] : ["family"]);
  if (!Array.isArray(b.zaps)) fail("damaged");
  for (const z of /** @type {unknown[]} */ (b.zaps)) {
    const zap = keys(z, ["selector", "label"], two ? ["frame"] : []);
    if (typeof zap.selector !== "string" || typeof zap.label !== "string" || ("frame" in zap && zap.frame !== true)) fail("damaged");
  }
  /** @param {unknown} v */
  const num = (v) => typeof v === "number" && Number.isFinite(v);
  /** @param {unknown} v */
  const str = (v) => typeof v === "string";
  /** @param {unknown} v @param {(v: unknown) => boolean} check */
  const opt = (v, check) => v === undefined || check(v);
  if (!["hue", "tint", "brightness", "contrast"].every((k) => num(colors[k])) || typeof colors.invert !== "boolean" || !opt(colors.saturation, num)) fail("damaged");
  if (!Number.isInteger(font.size) || !opt(font.family, str) || !opt(font.case, str)) fail("damaged");
  if (!str(b.name) || !str(b.css) || !str(b.js) || !str(b.createdAt) || Number.isNaN(Date.parse(/** @type {string} */ (b.createdAt)))) fail("damaged");
  if (!opt(b.scriptHost, str) || !opt(b.id, str) || !opt(b.revision, Number.isInteger) || !opt(b.author, str) || !opt(b.about, str)) fail("damaged");
  // A registrable site: lowercase host labels (Airc also checks it against the public suffix list when you review it).
  const site = /** @type {string} */ (b.site);
  if (!str(site) || site.length > 253 || !site.includes(".") || !site.split(".").every((l) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(l))) fail("damaged");
  const name = /** @type {string} */ (b.name).trim();
  return {
    kind: "boost",
    name: name || site,
    site,
    author: typeof b.author === "string" && b.author.trim() ? b.author.trim() : undefined,
    about: typeof b.about === "string" && b.about.trim() ? b.about.trim() : undefined,
    code: /** @type {string} */ (b.js).trim() !== "",
  };
}

/** The snapshot in `json` (the inflated payload), fully checked; any problem throws Refused.
 *  @param {string} json @returns {Snapshot} */
export function decodeSnapshot(json) {
  if (json.length > MAX_JSON) fail("tooLarge");
  const allowed = 3 + 2 * (MAX_DEPTH + 1) + 3;
  if (nesting(json, allowed) > allowed) fail("tooLarge");
  /** @type {unknown} */
  let top;
  try {
    top = JSON.parse(json);
  } catch {
    return fail("damaged");
  }
  if (!isObject(top) || typeof top.kind !== "string") return fail("damaged");
  const t = top;
  if (t.kind === "boost") {
    exact(t, ["kind", "boost"]);
    return boost(t.boost);
  }
  if (t.kind !== "space" && t.kind !== "folder") fail("damaged");
  exact(t, ["kind", "name", "items"], ["icon"]);
  const name = text(t.name, NAME);
  /** @type {string | undefined} */
  let icon;
  if ("icon" in t) {
    if (typeof t.icon !== "string" || !isEmojiText(t.icon)) fail("damaged");
    icon = /** @type {string} */ (t.icon);
  }
  let tabs = 0, nodes = 0, folders = 0;
  /** @param {unknown} v @returns {Tab} */
  const tab = (v) => {
    if (!isObject(v) || v.type !== "tab") return fail("damaged");
    const o = v;
    exact(o, ["type", "url"], ["title"]);
    if (typeof o.url !== "string") return fail("damaged");
    if (!isSafeAddress(o.url)) fail("unsafeAddress");
    if (++tabs > MAX_TABS) fail("tooLarge");
    return { type: "tab", url: o.url, ...("title" in o ? { title: text(o.title, TITLE) } : {}) };
  };
  /** @param {unknown} v @param {number} depth @returns {Node[]} */
  const list = (v, depth) => {
    if (!Array.isArray(v)) return fail("damaged");
    return v.map((x) => {
      if (++nodes > MAX_NODES) fail("tooLarge");
      if (!isObject(x) || typeof x.type !== "string") return fail("damaged");
      const o = x;
      if (o.type === "tab") return tab(o);
      if (o.type === "folder") {
        if (depth >= MAX_DEPTH) fail("tooLarge");
        exact(o, ["type", "name", "items"]);
        folders++;
        return /** @type {Node} */ ({ type: "folder", name: text(o.name, NAME), items: list(o.items, depth + 1) });
      }
      if (o.type === "split") {
        exact(o, ["type", "items"], ["axis"]);
        /** @type {"horizontal" | "vertical"} */
        let axis = "horizontal";
        if ("axis" in o) {
          if (o.axis !== "horizontal" && o.axis !== "vertical") fail("damaged");
          axis = /** @type {"horizontal" | "vertical"} */ (o.axis);
        }
        if (!Array.isArray(o.items) || o.items.length < 2 || o.items.length > 4) fail("damaged");
        return /** @type {Node} */ ({ type: "split", axis, items: /** @type {unknown[]} */ (o.items).map(tab) });
      }
      return fail("damaged");
    });
  };
  const items = list(t.items, 0);
  if (tabs < 1) fail("damaged");
  return { kind: /** @type {"space" | "folder"} */ (t.kind), name, ...(icon ? { icon } : {}), items, tabs, folders };
}

/** The snapshot as Airc writes it (docs/dev/share-links.md): the tree without the counts.
 *  @param {TreeSnapshot} s */
export function treeJSON(s) {
  return { kind: s.kind, name: s.name, ...(s.icon ? { icon: s.icon } : {}), items: s.items };
}

/** Every tab's address, in order, one per line: what "Copy all links" copies. @param {Node[]} nodes @returns {string[]} */
export function addresses(nodes) {
  return nodes.flatMap((n) => (n.type === "tab" ? [n.url] : addresses(n.items)));
}
