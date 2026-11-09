// Reads a share link's fragment (`v1.<payload>`, docs/dev/share-links.md) the way Airc does (AircKit ShareLink), all or
// nothing, in the browser. It never sends anything anywhere: it's used only by /s, which runs no analytics.

export type Failure = "damaged" | "newerVersion" | "tooLarge" | "unsafeAddress" | "unsupported";
export type Tab = { type: "tab"; url: string; title?: string };
export type Node = Tab | { type: "folder"; name: string; items: Node[] } | { type: "split"; axis: "horizontal" | "vertical"; items: Tab[] };
export type Snapshot =
  | { kind: "space" | "folder"; name: string; icon?: string; items: Node[]; tabs: number; folders: number }
  | { kind: "boost"; name: string; site: string; author?: string; about?: string; code: boolean };

export const messages: Record<Failure, string> = {
  damaged: "This link is damaged or incomplete.",
  newerVersion: "This link was made by a newer version of Airc. Update Airc to open it.",
  tooLarge: "This link is too large to open.",
  unsafeAddress: "This link contains an address Airc doesn't open (only web addresses can be shared).",
  unsupported: "This browser can't read the link. Open it in Airc instead.",
};

const VERSION = 1;
const MAX_PAYLOAD = 32_000;
const MAX_JSON = 524_288;
const MAX_TABS = 2_000;
const MAX_NODES = 4_000;
const MAX_DEPTH = 10;
const NAME = 200, TITLE = 500, URL_LIMIT = 4_096, ICON = 16;

class Refused extends Error {
  why: Failure;
  constructor(why: Failure) {
    super(why);
    this.why = why;
  }
}
const fail = (why: Failure): never => {
  throw new Refused(why);
};

const isControl = (cp: number) => cp < 0x20 || (cp >= 0x7f && cp <= 0x9f);
const hasControl = (s: string) => [...s].some((c) => isControl(c.codePointAt(0)!));
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

/** `o` has exactly these keys, none of them null. */
function exact(o: Record<string, unknown>, required: string[], optional: string[] = []) {
  const keys = Object.keys(o);
  if (!required.every((k) => k in o) || !keys.every((k) => required.includes(k) || optional.includes(k))) fail("damaged");
  if (keys.some((k) => o[k] === null)) fail("damaged");
}

/** A required string: 1 to `limit` UTF-16 units, not only whitespace, no control characters. */
function text(v: unknown, limit: number): string {
  if (typeof v !== "string" || v.length > limit || v.trim() === "" || hasControl(v)) fail("damaged");
  return v as string;
}

/** An emoji icon: 1–16 UTF-16 units, each character non-ASCII with an emoji in it. */
function isEmojiText(s: string): boolean {
  if (!s || s.length > ICON || hasControl(s)) return false;
  const chars = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(s)].map((x) => x.segment);
  return chars.every((ch) => /[^\x00-\x7f]/.test(ch) && /\p{Emoji}/u.test(ch) && !/^[\x00-\x7f]+$/.test(ch));
}

/** The authority of an http(s) address, or null: absolute, with a host, no user name or password (an "@" at all). */
function authority(s: string): string | null {
  const m = /^https?:\/\/([^/?#]*)/i.exec(s);
  if (!m || !m[1] || m[1].includes("@")) return null;
  const host = m[1].replace(/:\d*$/, "");
  return host && host !== "[]" ? host : null;
}

/** An address a link may carry: absolute http(s) with a host, no credentials, no whitespace, control characters or
 *  backslashes, at most 4,096 UTF-16 units. */
export function isSafeAddress(s: string): boolean {
  if (!s || s.length > URL_LIMIT || /\s|\\/u.test(s) || hasControl(s) || !authority(s)) return false;
  try {
    const u = new URL(s);
    return (u.protocol === "http:" || u.protocol === "https:") && u.hostname !== "" && u.username === "" && u.password === "";
  } catch {
    return false;
  }
}

/** The host to show for a tab without a title: the address's own host, as written. */
export const hostOf = (url: string) => authority(url) ?? url;

function unbase64url(s: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(s) || s.length % 4 === 1) fail("damaged");
  let b = s.replace(/-/g, "+").replace(/_/g, "/");
  while (b.length % 4) b += "=";
  try {
    const bin = atob(b);
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return fail("damaged");
  }
}

/** Raw DEFLATE, stopped as soon as it passes the cap (a "zip bomb" isn't inflated any further). */
async function inflate(bytes: Uint8Array): Promise<Uint8Array> {
  if (typeof DecompressionStream === "undefined") fail("unsupported");
  let stream: ReadableStream<Uint8Array>;
  try {
    stream = new Blob([bytes as BlobPart]).stream().pipeThrough(new DecompressionStream("deflate-raw" as CompressionFormat));
  } catch {
    return fail("unsupported");
  }
  const reader = stream.getReader();
  const parts: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    let r: ReadableStreamReadResult<Uint8Array>;
    try {
      r = await reader.read();
    } catch {
      return fail("damaged");
    }
    if (r.done) break;
    total += r.value.length;
    if (total > MAX_JSON) {
      reader.cancel().catch(() => {});
      return fail("tooLarge");
    }
    parts.push(r.value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** The deepest bracket nesting outside strings, counted up to `limit` + 1 (so a deep payload is refused before parsing). */
function nesting(json: string, limit: number): number {
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

function boost(o: unknown): Snapshot {
  // Airc's Boost file, version 1 or 2, without its picture: the same keys and types Airc's own reader accepts.
  if (!isObject(o) || "preview" in o) fail("damaged");
  const b = o as Record<string, unknown>;
  const version = b.version;
  if (typeof version !== "number" || !Number.isInteger(version) || version < 1 || version > 2) fail("damaged");
  const two = version === 2;
  const keys = (v: unknown, required: string[], optional: string[]) => {
    if (!isObject(v)) fail("damaged");
    const x = v as Record<string, unknown>;
    if (!required.every((k) => k in x && x[k] !== null) || !Object.keys(x).every((k) => required.includes(k) || optional.includes(k))) fail("damaged");
    return x;
  };
  keys(b, ["version", "name", "site", "createdAt", "colors", "font", "zaps", "css", "js"], ["scriptHost", ...(two ? ["id", "revision", "author", "about"] : [])]);
  const colors = keys(b.colors, ["hue", "tint", "brightness", "contrast", "invert"], two ? ["saturation"] : []);
  const font = keys(b.font, ["size"], two ? ["family", "case"] : ["family"]);
  if (!Array.isArray(b.zaps)) fail("damaged");
  for (const z of b.zaps as unknown[]) {
    const zap = keys(z, ["selector", "label"], two ? ["frame"] : []);
    if (typeof zap.selector !== "string" || typeof zap.label !== "string" || ("frame" in zap && zap.frame !== true)) fail("damaged");
  }
  const num = (v: unknown) => typeof v === "number" && Number.isFinite(v);
  const str = (v: unknown) => typeof v === "string";
  const opt = (v: unknown, check: (v: unknown) => boolean) => v === undefined || check(v);
  if (!["hue", "tint", "brightness", "contrast"].every((k) => num(colors[k])) || typeof colors.invert !== "boolean" || !opt(colors.saturation, num)) fail("damaged");
  if (!Number.isInteger(font.size) || !opt(font.family, str) || !opt(font.case, str)) fail("damaged");
  if (!str(b.name) || !str(b.css) || !str(b.js) || !str(b.createdAt) || Number.isNaN(Date.parse(b.createdAt as string))) fail("damaged");
  if (!opt(b.scriptHost, str) || !opt(b.id, str) || !opt(b.revision, Number.isInteger) || !opt(b.author, str) || !opt(b.about, str)) fail("damaged");
  // A registrable site: lowercase host labels (Airc also checks it against the public suffix list when you review it).
  const site = b.site as string;
  if (!str(site) || site.length > 253 || !site.includes(".") || !site.split(".").every((l) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(l))) fail("damaged");
  const name = (b.name as string).trim();
  return {
    kind: "boost",
    name: name || site,
    site,
    author: typeof b.author === "string" && b.author.trim() ? b.author.trim() : undefined,
    about: typeof b.about === "string" && b.about.trim() ? b.about.trim() : undefined,
    code: (b.js as string).trim() !== "",
  };
}

function decode(json: string): Snapshot {
  const allowed = 3 + 2 * (MAX_DEPTH + 1) + 3;
  if (nesting(json, allowed) > allowed) fail("tooLarge");
  let top: unknown;
  try {
    top = JSON.parse(json);
  } catch {
    return fail("damaged");
  }
  if (!isObject(top) || typeof top.kind !== "string") fail("damaged");
  const t = top as Record<string, unknown>;
  if (t.kind === "boost") {
    exact(t, ["kind", "boost"]);
    return boost(t.boost);
  }
  if (t.kind !== "space" && t.kind !== "folder") fail("damaged");
  exact(t, ["kind", "name", "items"], ["icon"]);
  const name = text(t.name, NAME);
  let icon: string | undefined;
  if ("icon" in t) {
    if (typeof t.icon !== "string" || !isEmojiText(t.icon)) fail("damaged");
    icon = t.icon as string;
  }
  let tabs = 0, nodes = 0, folders = 0;
  const tab = (v: unknown): Tab => {
    if (!isObject(v) || v.type !== "tab") fail("damaged");
    const o = v as Record<string, unknown>;
    exact(o, ["type", "url"], ["title"]);
    if (typeof o.url !== "string") fail("damaged");
    if (!isSafeAddress(o.url as string)) fail("unsafeAddress");
    if (++tabs > MAX_TABS) fail("tooLarge");
    return { type: "tab", url: o.url as string, ...("title" in o ? { title: text(o.title, TITLE) } : {}) };
  };
  const list = (v: unknown, depth: number): Node[] => {
    if (!Array.isArray(v)) fail("damaged");
    return (v as unknown[]).map((x): Node => {
      if (++nodes > MAX_NODES) fail("tooLarge");
      if (!isObject(x) || typeof x.type !== "string") fail("damaged");
      const o = x as Record<string, unknown>;
      if (o.type === "tab") return tab(o);
      if (o.type === "folder") {
        if (depth >= MAX_DEPTH) fail("tooLarge");
        exact(o, ["type", "name", "items"]);
        folders++;
        return { type: "folder", name: text(o.name, NAME), items: list(o.items, depth + 1) };
      }
      if (o.type === "split") {
        exact(o, ["type", "items"], ["axis"]);
        let axis: "horizontal" | "vertical" = "horizontal";
        if ("axis" in o) {
          if (o.axis !== "horizontal" && o.axis !== "vertical") fail("damaged");
          axis = o.axis as "horizontal" | "vertical";
        }
        if (!Array.isArray(o.items) || o.items.length < 2 || o.items.length > 4) fail("damaged");
        return { type: "split", axis, items: (o.items as unknown[]).map(tab) };
      }
      return fail("damaged");
    });
  };
  const items = list(t.items, 0);
  if (tabs < 1) fail("damaged");
  return { kind: t.kind as "space" | "folder", name, ...(icon ? { icon } : {}), items, tabs, folders };
}

/** The snapshot in `fragment` (location.hash without the "#"), or why it's refused. */
export async function read(fragment: string): Promise<{ ok: true; snapshot: Snapshot } | { ok: false; why: Failure }> {
  try {
    const m = /^v([^.]*)\.(.*)$/s.exec(fragment);
    if (!m || !/^[1-9]\d{0,8}$/.test(m[1])) fail("damaged");
    const v = Number(m![1]);
    if (v !== VERSION) fail(v > VERSION ? "newerVersion" : "damaged");
    const payload = m![2];
    if (payload.length > MAX_PAYLOAD) fail("tooLarge");
    if (!payload) fail("damaged");
    const bytes = await inflate(unbase64url(payload));
    let json: string;
    try {
      json = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch {
      return { ok: false, why: "damaged" };
    }
    return { ok: true, snapshot: decode(json) };
  } catch (e) {
    if (e instanceof Refused) return { ok: false, why: e.why };
    return { ok: false, why: "damaged" };
  }
}

/** Every tab's address, in order, one per line: what "Copy all links" copies. */
export function addresses(nodes: Node[]): string[] {
  return nodes.flatMap((n) => (n.type === "tab" ? [n.url] : addresses(n.items)));
}
