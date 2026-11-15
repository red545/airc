// The gallery's static review of a submitted Boost (docs/dev/sharing-service.md), before the owner sees it. A
// submission is Airc's Boost file, version 2 (AircKit BoostFile), checked the way Airc checks a file it opens (exact
// keys, types, ranges, sizes, no hidden text), plus the gallery's own rules: nothing in it may load from another site.
// Code that passes still waits for the owner, who reads all of it on the admin page; the review also lists what they
// should look at closely ("notes").

export const MAX_FILE = 512 * 1024;
export const MAX_CODE = 128 * 1024;
export const MAX_PREVIEW = 300 * 1024;
const FAMILIES = ["system", "helvetica", "avenir", "georgia", "charter", "menlo"];
const CASES = ["capitalize", "uppercase", "lowercase"];

export class Rejected extends Error {}
/** @param {string} why @returns {never} */
const reject = (why) => {
  throw new Rejected(why);
};

/** @param {unknown} v @returns {v is Record<string, unknown>} */
const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
/** @param {Record<string, unknown>} o @param {string[]} required @param {string[]} optional */
function exact(o, required, optional = []) {
  const ok = required.every((k) => k in o && o[k] !== null) && Object.keys(o).every((k) => required.includes(k) || optional.includes(k));
  if (!ok || Object.values(o).some((v) => v === null)) reject("This is not a valid Airc Boost file. Check its fields and settings.");
}
const FORMAT = "This is not a valid Airc Boost file. Check its fields and settings.";
const utf8 = (/** @type {string} */ s) => Buffer.byteLength(s, "utf8");

/** Text a review can't show as it is: bidirectional controls and marks ("Trojan Source") and control characters
 *  (tab and line breaks only in multi-line text), as BoostFile.hidesText. @param {string} s @param {boolean} multiline */
export function hidesText(s, multiline) {
  for (const ch of s) {
    const u = /** @type {number} */ (ch.codePointAt(0));
    if (u === 0x09 || u === 0x0a || u === 0x0d) {
      if (!multiline) return true;
    } else if (u <= 0x1f || (u >= 0x7f && u <= 0x9f) || u === 0x061c || u === 0x200e || u === 0x200f ||
               (u >= 0x202a && u <= 0x202e) || (u >= 0x2066 && u <= 0x2069)) return true;
  }
  return false;
}
/** One line: not blank, at most `max` characters, nothing hidden. @param {unknown} s @param {number} max */
const plainLine = (s, max) => typeof s === "string" && s.trim() !== "" && [...s].length <= max && !hidesText(s, false);

/** A host name as Airc writes it: lowercase letters, digits and hyphens in dot-separated labels. @param {string} h */
const validHost = (h) =>
  h.length <= 253 && h.split(".").every((l) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(l));
/** A registrable site (Airc checks the full public suffix list when it opens the file): a host with a dot, not an
 *  IP address. @param {unknown} s */
const validSite = (s) => typeof s === "string" && validHost(s) && s.includes(".") && !/^[\d.]+$/.test(s);

/** The preview picture's bytes and type, if it's a PNG or JPEG of at most 300 KB. @param {string} b64 */
export function previewImage(b64) {
  if (b64.length > Math.ceil(MAX_PREVIEW / 3) * 4 + 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) return null;
  const bytes = Buffer.from(b64, "base64");
  if (bytes.length === 0 || bytes.length > MAX_PREVIEW) return null;
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return { bytes, type: "image/jpeg" };
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (png.every((b, i) => bytes[i] === b)) return { bytes, type: "image/png" };
  return null;
}

/** Where a URL in the CSS would load from: null when it's the CSS itself (data:), the page's own origin (relative) or
 *  the Boost's site; otherwise the reason it's refused. @param {string} raw @param {string} site */
function cssURLProblem(raw, site) {
  const u = raw.trim().replace(/^["']|["']$/g, "").trim();
  if (/^data:/i.test(u)) return /^data:(text\/css|image\/(png|jpeg|gif|webp|svg\+xml))[;,]/i.test(u) ? null : "a data: URL that isn't CSS or a picture";
  if (/^[a-z][a-z0-9+.-]*:/i.test(u)) {
    let host;
    try {
      const p = new URL(u);
      if (p.protocol !== "https:" && p.protocol !== "http:") return `a ${p.protocol} URL`;
      host = p.hostname.toLowerCase();
    } catch {
      return "an address that can't be read";
    }
    return host === site || host.endsWith("." + site) ? null : `an address on another site (${host})`;
  }
  if (u.startsWith("//")) {
    const host = u.slice(2).split(/[/?#]/)[0].toLowerCase().replace(/:\d+$/, "");
    return host === site || host.endsWith("." + site) ? null : `an address on another site (${host})`;
  }
  return null; // relative: the page's own origin
}

/** The gallery's rules for the CSS: no loads from other sites (imports, fonts, pictures), no legacy script hooks.
 *  @param {string} css @param {string} site */
function reviewCSS(css, site) {
  const flat = css;
  if (/expression\s*\(|-moz-binding|(?<![-\w])behavior\s*:|javascript\s*:|vbscript\s*:/i.test(flat)) {
    reject("Its CSS uses a script hook (expression(), -moz-binding, behavior or a javascript: URL), which the gallery doesn't take.");
  }
  if (/\\[0-9a-f]/i.test(flat)) reject("Its CSS uses \\ escapes. Gallery CSS must be readable as written.");
  const urls = [...flat.matchAll(/url\(\s*([^)]*?)\s*\)/gi)].map((m) => m[1]);
  // Quoted addresses anywhere (@import "…", image-set("…"), src: "…").
  urls.push(...[...flat.matchAll(/(["'])((?:https?:)?\/\/[^"']*)\1/gi)].map((m) => m[2]));
  for (const u of urls) {
    const why = cssURLProblem(u, site);
    if (why) reject(`Its CSS loads ${why}. Gallery Boosts load nothing from other sites: put the CSS itself in the Boost.`);
  }
}

/** Patterns that would load code or contact a site from a Boost's JavaScript: refused in the gallery. */
const JS_REFUSED = [
  [/<\s*script/i, "writes a <script> element"],
  [/createElement\s*\(\s*(["'`])\s*script\s*\1/i, "creates a <script> element"],
  [/\bimport\s*\(/, "imports a module"],
  [/^\s*import[\s{*"']/m, "imports a module"],
  [/\bimportScripts\b/, "imports scripts"],
  [/\beval\s*\(/, "runs text as code (eval)"],
  [/\bnew\s+Function\b|\bFunction\s*\(/, "runs text as code (Function)"],
  [/\bset(?:Timeout|Interval)\s*\(\s*["'`]/, "runs text as code (a string timer)"],
  [/\bdocument\s*\.\s*write(?:ln)?\b/, "writes into the page with document.write"],
  [/\bfetch\s*\(/, "makes network requests (fetch)"],
  [/\bXMLHttpRequest\b/, "makes network requests (XMLHttpRequest)"],
  [/\bWebSocket\b|\bEventSource\b|\bWebTransport\b|\bRTCPeerConnection\b/, "opens a network connection"],
  [/\bsendBeacon\b/, "sends data away (sendBeacon)"],
  [/\b(?:Shared)?Worker\s*\(|\bserviceWorker\b/, "starts a worker"],
  [/\.\s*(?:src|href|action|srcdoc|data)\s*=|setAttribute\s*\(\s*(["'`])(?:src|href|action|srcdoc)\1/i, "points an element at an address"],
  [/\bwindow\s*\.\s*open\s*\(|\blocation\s*(?:\.\s*(?:href|assign|replace)\b|=)/, "opens or changes the page's address"],
  [/(["'`])(?:https?:)?\/\/[^"'`\s]+\1/i, "contains a web address"],
];
/** What the owner should read closely in code that passed. */
const JS_NOTES = [
  [/\bdocument\s*\.\s*cookie\b/, "reads or writes cookies"],
  [/\b(?:local|session)Storage\b|\bindexedDB\b/, "uses the site's storage"],
  [/\binnerHTML\b|\bouterHTML\b|\binsertAdjacentHTML\b/, "inserts HTML"],
  [/\baddEventListener\s*\(\s*["'`](?:key|input|submit|paste|copy)/i, "listens to typing, forms or the clipboard"],
  [/\bpassword\b/i, "mentions passwords"],
];

/**
 * Reviews a submission (the request body). Returns the file as it will be published (without its preview), the
 * preview, and notes for the owner; throws Rejected with a sentence for the submitter.
 * @param {string} text
 */
export function reviewBoost(text) {
  if (utf8(text) > MAX_FILE + Math.ceil(MAX_PREVIEW / 3) * 4 + 1024) reject("This Boost is too large for the gallery.");
  /** @type {unknown} */
  let top;
  try {
    top = JSON.parse(text);
  } catch {
    return reject(FORMAT);
  }
  if (!isObject(top)) return reject(FORMAT);
  const b = top;
  if (b.version !== 2) reject(b.version === 1 ? "Update Airc and share this Boost again: the gallery takes the current file format." : FORMAT);
  exact(b, ["version", "name", "site", "createdAt", "colors", "font", "zaps", "css", "js"],
        ["scriptHost", "id", "revision", "author", "about", "preview"]);
  if (!isObject(b.colors) || !isObject(b.font) || !Array.isArray(b.zaps)) return reject(FORMAT);
  exact(b.colors, ["hue", "tint", "brightness", "contrast", "invert"], ["saturation"]);
  exact(b.font, ["size"], ["family", "case"]);
  const c = b.colors, f = b.font;
  /** @param {unknown} v @param {number} lo @param {number} hi */
  const within = (v, lo, hi) => typeof v === "number" && Number.isFinite(v) && v >= lo && v <= hi;
  if (!within(c.hue, 0, 1) || !within(c.tint, 0, 1) || !within(c.brightness, 0.5, 1.5) || !within(c.contrast, 0.5, 1.5) ||
      typeof c.invert !== "boolean" || ("saturation" in c && !within(c.saturation, 0, 1))) reject(FORMAT);
  if (!Number.isInteger(f.size) || !within(f.size, -2, 3) || ("family" in f && !FAMILIES.includes(/** @type {string} */ (f.family))) ||
      ("case" in f && !CASES.includes(/** @type {string} */ (f.case)))) reject(FORMAT);
  if (typeof b.name !== "string" || !plainLine(b.name, 120)) reject("Give the Boost a name (one line, at most 120 characters).");
  if (!validSite(b.site)) reject("This Boost must name a registrable site, not an address, public suffix or subdomain.");
  const site = /** @type {string} */ (b.site);
  if ("scriptHost" in b && (typeof b.scriptHost !== "string" || !validHost(b.scriptHost) ||
      !(b.scriptHost === site || b.scriptHost.endsWith("." + site)))) reject(FORMAT);
  if (typeof b.createdAt !== "string" || Number.isNaN(Date.parse(b.createdAt))) reject(FORMAT);
  if (typeof b.css !== "string" || typeof b.js !== "string") return reject(FORMAT);
  if (utf8(b.css) > MAX_CODE || utf8(b.js) > MAX_CODE || b.zaps.length > 200) {
    reject("This Boost is too large. CSS and JavaScript may be at most 128 KB each, with at most 200 zaps.");
  }
  if (hidesText(b.css, true) || hidesText(b.js, true)) {
    reject("Its code has hidden or reordering characters (control or bidirectional marks), which the gallery doesn't take.");
  }
  const selectors = new Set();
  for (const z of b.zaps) {
    if (!isObject(z)) return reject(FORMAT);
    exact(z, ["selector", "label"], ["frame"]);
    const s = z.selector, l = z.label;
    if (typeof s !== "string" || typeof l !== "string" || !s || [...s].length > 600 || /[{};@\n\r]|\/\*/.test(s) ||
        hidesText(s, false) || hidesText(l, false) || [...l].length > 80 || ("frame" in z && z.frame !== true) || selectors.has(s)) {
      reject(FORMAT);
    }
    selectors.add(s);
  }
  if (("id" in b) !== ("revision" in b)) reject(FORMAT);
  if ("id" in b && (typeof b.id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(b.id))) reject(FORMAT);
  if ("revision" in b && (!Number.isInteger(b.revision) || !within(b.revision, 1, 1_000_000))) reject(FORMAT);
  if ("author" in b && !plainLine(b.author, 60)) reject("The author name must be one line of at most 60 characters.");
  if ("about" in b && !plainLine(b.about, 280)) reject("The description must be one line of at most 280 characters.");
  /** @type {{ bytes: Buffer, type: string } | null} */
  let preview = null;
  if ("preview" in b) {
    preview = typeof b.preview === "string" ? previewImage(b.preview) : null;
    if (!preview) reject("The preview must be a PNG or JPEG picture of at most 300 KB.");
  }

  // Checked as written, comments included: stripping comments first would let a "/*" inside a string hide code.
  reviewCSS(b.css, site);
  const js = b.js;
  if (js.split("\n").some((line) => line.length > 400)) {
    reject("Its JavaScript has lines over 400 characters. Gallery code must be readable: no minified or packed code.");
  }
  if (/\\u|\\x/.test(js)) reject("Its JavaScript uses \\u or \\x escapes. Gallery code must be readable as written.");
  for (const [re, what] of JS_REFUSED) {
    if (/** @type {RegExp} */ (re).test(js)) reject(`Its JavaScript ${what}. Gallery Boosts can change the page but not load code or contact other sites.`);
  }

  /** @type {string[]} */
  const notes = [];
  if (b.js.trim()) notes.push("has JavaScript: read all of it (a static review can't see through obfuscated code; reject what you can't read)");
  for (const [re, what] of JS_NOTES) if (/** @type {RegExp} */ (re).test(b.js)) notes.push(`its JavaScript ${what}`);
  if (/@import/i.test(b.css)) notes.push("its CSS imports CSS from the site itself");

  const { preview: _drop, ...file } = b;
  const published = JSON.stringify(file);
  if (utf8(published) > MAX_FILE) reject("This Boost is too large. Files may be at most 512 KB.");
  return { file: /** @type {Record<string, unknown>} */ (file), published, preview, notes };
}
