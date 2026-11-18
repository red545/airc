// Feedback sent from Airc (Help › Send Feedback…; docs/user/feedback.md, docs/dev/feedback-service.md): what an entry
// may hold, where it's kept, and the owner's notice. An entry has only what the person typed and chose to add: the
// message, an optional reply address, up to five pictures (the Airc window, or images the person pasted, dropped or
// chose), and optional app details from a fixed list. Anything else in a request refuses it whole.
// Pictures go one per request after the message (Vercel's functions take at most 4.5 MB a request), as Easel links do:
// the message names each picture (type, size, SHA-256), each PUT must match, and the entry shows once all arrived.
import { createHash } from "node:crypto";
import { esc } from "./http.js";

export const MAX_MESSAGE = 5000; // characters
export const MAX_EMAIL = 254;
export const MAX_SHOT = 2 * 1024 * 1024; // bytes of the picture itself
/** At most this many pictures per message. */
export const MAX_IMAGES = 5;
/** Bytes of one picture sent on its own (under Vercel's 4.5 MB request cap; the app re-encodes 5 MB files to fit). */
export const MAX_IMAGE = 4 * 1024 * 1024;
/** The request body: the (0.1.10–0.1.11) picture as base64 plus the rest, with room to spare. */
export const MAX_BODY = Math.ceil(MAX_SHOT / 3) * 4 + 64 * 1024;

export class Invalid extends Error {}
/** @param {string} why @returns {never} */
const invalid = (why) => {
  throw new Invalid(why);
};

/** @param {unknown} v @returns {v is Record<string, unknown>} */
const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
/** @param {Record<string, unknown>} o @param {string[]} keys @param {string} what */
function only(o, keys, what) {
  for (const k of Object.keys(o)) if (!keys.includes(k)) invalid(`${what} has a field Airc doesn't send (${k.slice(0, 40)}).`);
}

/** Control characters other than tab and line breaks, and bidirectional overrides (text that hides what it says). */
export const HIDDEN = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f؜‎‏‪-‮⁦-⁩]/;
const EMAIL = /^[^\s@<>"(),;:\\[\]]+@[^\s@<>"(),;:\\[\]]+\.[^\s@<>"(),;:\\[\]]+$/;

/** The app details a request may carry, each in its exact format (AircKit FeedbackReport.AppInfo). */
export const APP_FIELDS = {
  version: /^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$/,
  build: /^[0-9]{1,14}$|^dev$/,
  engine: /^(chromium|webkit)$/,
  macOS: /^[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?$/,
  model: /^[A-Za-z]{2,24}[0-9]{1,3},[0-9]{1,3}$/,
  locale: /^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$/,
};

/** The picture's type from its first bytes: PNG or JPEG only. @param {Uint8Array} b */
export function imageType(b) {
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (b.length > 8 && png.every((x, i) => b[i] === x)) return "image/png";
  return null;
}

/**
 * The picture without what could say who or where: a JPEG's Exif, XMP, IPTC, comments and maker segments (APP1, APP3–15,
 * COM; APP2 only as an ICC colour profile), a PNG's eXIf, text and time chunks. The app strips them already; this is
 * for any request that didn't. Also walks the whole structure, so a picture that isn't a well-formed PNG or JPEG is
 * refused. @param {Uint8Array} b @param {string} type @returns {Buffer}
 */
export function stripMetadata(b, type) {
  const bad = () => invalid("The picture isn't a well-formed PNG or JPEG.");
  const buf = Buffer.from(b.buffer, b.byteOffset, b.byteLength);
  if (type === "image/png") {
    if (imageType(buf) !== "image/png") bad();
    const out = [buf.subarray(0, 8)];
    let i = 8, ended = false;
    while (i + 12 <= buf.length) {
      const len = buf.readUInt32BE(i), name = buf.toString("latin1", i + 4, i + 8);
      if (!/^[A-Za-z]{4}$/.test(name) || len > buf.length - i - 12) bad();
      const end = i + 12 + len;
      if (!["eXIf", "tEXt", "zTXt", "iTXt", "tIME"].includes(name)) out.push(buf.subarray(i, end));
      i = end;
      if (name === "IEND") { ended = true; break; }
    }
    if (!ended) bad();
    return Buffer.concat(out);
  }
  if (type !== "image/jpeg" || imageType(buf) !== "image/jpeg") bad();
  const out = [buf.subarray(0, 2)];
  let i = 2;
  while (i + 4 <= buf.length) {
    if (buf[i] !== 0xff) bad();
    const m = buf[i + 1];
    if (m === 0xff) { i += 1; continue; } // fill byte
    if (m === 0xd9) return Buffer.concat([...out, buf.subarray(i, i + 2)]);
    if ((m >= 0xd0 && m <= 0xd7) || m === 0x01) { out.push(buf.subarray(i, i + 2)); i += 2; continue; }
    const len = buf.readUInt16BE(i + 2);
    if (len < 2 || i + 2 + len > buf.length) bad();
    const end = i + 2 + len;
    // Start of scan: the rest is the image's own data, to its end.
    if (m === 0xda) return Buffer.concat([...out, buf.subarray(i)]);
    const icc = m === 0xe2 && buf.toString("latin1", i + 4, i + 16) === "ICC_PROFILE\0";
    const drop = m === 0xe1 || (m >= 0xe3 && m <= 0xef) || m === 0xfe || (m === 0xe2 && !icc);
    if (!drop) out.push(buf.subarray(i, end));
    i = end;
  }
  return bad();
}

/**
 * @typedef {{ version?: string, build?: string, engine?: string, macOS?: string, model?: string, locale?: string }} AppInfo
 * @typedef {{ type: string, size: number, sha256: string }} ImageInfo
 * @typedef {{ message: string, email: string | null, app: AppInfo | null, shot: { type: string, bytes: Buffer } | null,
 *   images: ImageInfo[], client: string | null, writtenAt: string | null }} Feedback
 */

/** Checks a request's JSON and returns the entry it describes; throws Invalid with a reason the app can show.
 *  @param {string} text @returns {Feedback} */
export function decodeFeedback(text) {
  let v;
  try {
    v = JSON.parse(text);
  } catch {
    invalid("This isn't valid JSON.");
  }
  if (!isObject(v)) invalid("This isn't a feedback message.");
  only(v, ["version", "message", "email", "app", "screenshot", "images", "client", "writtenAt"], "The message");
  if (v.version !== 1) invalid("This version of Airc sends feedback in a format the site doesn't know.");

  if (typeof v.message !== "string" || v.message.trim() === "") invalid("Write a message first.");
  const message = v.message.replace(/\r\n?/g, "\n").trim();
  if ([...message].length > MAX_MESSAGE) invalid(`The message is longer than ${MAX_MESSAGE} characters.`);
  if (HIDDEN.test(message)) invalid("The message has hidden characters in it.");

  let email = null;
  if (v.email !== undefined && v.email !== null && v.email !== "") {
    if (typeof v.email !== "string") invalid("The reply address isn't text.");
    email = v.email.trim();
    if (email.length > MAX_EMAIL || !EMAIL.test(email) || HIDDEN.test(email)) invalid("The reply address doesn't look like an email address.");
  }

  /** @type {AppInfo | null} */
  let app = null;
  if (v.app !== undefined && v.app !== null) {
    if (!isObject(v.app)) invalid("The app details aren't in Airc's format.");
    only(v.app, Object.keys(APP_FIELDS), "The app details");
    app = {};
    for (const [k, re] of Object.entries(APP_FIELDS)) {
      const x = v.app[k];
      if (x === undefined) continue;
      if (typeof x !== "string" || !re.test(x)) invalid(`The app detail “${k}” isn't in Airc's format.`);
      /** @type {Record<string, string>} */ (app)[k] = x;
    }
  }

  let shot = null;
  if (v.screenshot !== undefined && v.screenshot !== null) {
    const s = v.screenshot;
    if (!isObject(s)) invalid("The screenshot isn't in Airc's format.");
    only(s, ["type", "base64"], "The screenshot");
    if (s.type !== "image/png" && s.type !== "image/jpeg") invalid("The screenshot must be a PNG or JPEG picture.");
    if (typeof s.base64 !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(s.base64) || s.base64.length % 4 !== 0) {
      invalid("The screenshot isn't valid base64.");
    }
    if (s.base64.length > Math.ceil(MAX_SHOT / 3) * 4) invalid("The screenshot is larger than 2 MB.");
    const bytes = Buffer.from(s.base64, "base64");
    if (bytes.length === 0) invalid("The screenshot is empty.");
    if (bytes.length > MAX_SHOT) invalid("The screenshot is larger than 2 MB.");
    if (imageType(bytes) !== s.type) invalid("The screenshot isn't the picture type it says it is.");
    shot = { type: s.type, bytes };
  }

  /** @type {ImageInfo[]} */
  const images = [];
  if (v.images !== undefined && v.images !== null) {
    if (!Array.isArray(v.images)) invalid("The pictures aren't in Airc's format.");
    if (shot) invalid("The pictures aren't in Airc's format.");
    if (v.images.length > MAX_IMAGES) invalid(`At most ${MAX_IMAGES} pictures go with one message.`);
    for (const i of v.images) {
      if (!isObject(i)) invalid("The pictures aren't in Airc's format.");
      only(i, ["type", "size", "sha256"], "A picture");
      if (i.type !== "image/png" && i.type !== "image/jpeg") invalid("Pictures must be PNG or JPEG.");
      if (!Number.isInteger(i.size) || /** @type {number} */ (i.size) < 1) invalid("A picture's size isn't in Airc's format.");
      if (/** @type {number} */ (i.size) > MAX_IMAGE) invalid("A picture is larger than 4 MB.");
      if (typeof i.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(i.sha256)) invalid("A picture's checksum isn't in Airc's format.");
      images.push({ type: i.type, size: /** @type {number} */ (i.size), sha256: i.sha256 });
    }
  }

  let client = null;
  if (v.client !== undefined && v.client !== null) {
    if (typeof v.client !== "string" || !/^[A-Za-z0-9-]{16,64}$/.test(v.client)) invalid("The message's id isn't in Airc's format.");
    client = v.client;
  }
  // The message's id is what lets its own copy of Airc send the pictures after it.
  if (images.length && !client) invalid("The message's id isn't in Airc's format.");

  let writtenAt = null;
  if (v.writtenAt !== undefined && v.writtenAt !== null) {
    const t = typeof v.writtenAt === "string" && /^\d{4}-\d\d-\d\dT[\d:.]+Z$/.test(v.writtenAt) ? Date.parse(v.writtenAt) : NaN;
    if (!Number.isFinite(t)) invalid("The time it was written isn't in Airc's format.");
    writtenAt = new Date(t).toISOString();
  }
  return { message, email, app, shot, images, client, writtenAt };
}

/** @param {string} id */
export const entryKey = (id) => `feedback/entries/${id}.json`;
/** @param {string} id @param {string} type */
export const shotKey = (id, type) => `feedback/shots/${id}.${type === "image/png" ? "png" : "jpg"}`;
/** The `n`th picture sent after the message. @param {string} id @param {number} n @param {string} type */
export const imageKey = (id, n, type) => `feedback/images/${id}/${n}.${type === "image/png" ? "png" : "jpg"}`;
/** Every picture of an entry: the old single screenshot, and the ones sent after it. @param {any} e
 *  @returns {{ key: string, type: string }[]} */
export const picturesOf = (e) => [
  ...(e.shot ? [{ key: e.shot, type: e.shotType === "image/png" ? "image/png" : "image/jpeg" }] : []),
  ...(Array.isArray(e.images) ? e.images.map((/** @type {any} */ i) => ({ key: i.key, type: i.type })) : []),
];
/** The marker that makes a resend of the same message (a queued one whose answer was lost) one entry, by the app's
 *  random id for it, hashed. @param {string} client */
export const clientKey = (client) => `feedback/clients/${createHash("sha256").update(client).digest("hex").slice(0, 40)}.json`;

/** The app details as one line. @param {AppInfo | null | undefined} a */
export function appLine(a) {
  if (!a || !Object.keys(a).length) return "";
  const parts = [];
  if (a.version) parts.push(`Airc ${a.version}${a.build ? ` (${a.build})` : ""}`);
  if (a.engine) parts.push(a.engine === "chromium" ? "Chromium" : "WebKit");
  if (a.macOS) parts.push(`macOS ${a.macOS}`);
  if (a.model) parts.push(a.model);
  if (a.locale) parts.push(a.locale);
  return parts.join(" · ");
}

export const INBOX = "hello@aircbrowser.com";
/** The reply labels the admin page offers (api/_lib/reply.js sends them). */
export const REPLY_LABELS = ["working-on-it", "released", "follow-up"];

/**
 * Tells the owner: an email to hello@aircbrowser.com through Resend, the same way the waitlist does, which the
 * mail forwarder (infra/mail-forward) passes on. The message itself is in it; the picture stays on the admin page.
 * Production only: a Preview or a test never mails anyone. Returns whether Resend took it.
 * @param {{ id: string, message: string, email: string | null, app: AppInfo | null, shot?: string | null, images?: any[] }} entry
 * @param {{ fetch?: typeof fetch, key?: string, site?: string }} [o]
 */
export async function notify(entry, o = {}) {
  const key = o.key ?? process.env.RESEND_API_KEY;
  if (!key) return false;
  const first = entry.message.split("\n")[0];
  const subject = `Feedback: ${[...first].length > 60 ? [...first].slice(0, 59).join("") + "…" : first}`;
  const lines = [
    entry.message,
    "",
    "—",
    `Reply to: ${entry.email ?? "(no address given)"}`,
    `App: ${appLine(entry.app) || "(not included)"}`,
    `Pictures: ${picturesOf(entry).length ? `${picturesOf(entry).length}, on the admin page` : "none"}`,
    `${o.site ?? "https://aircbrowser.com"}/admin/feedback#f-${entry.id}`,
  ];
  try {
    const res = await (o.fetch ?? fetch)("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "Idempotency-Key": `feedback-${entry.id}` },
      body: JSON.stringify({
        from: `Airc feedback <${INBOX}>`,
        to: INBOX,
        ...(entry.email ? { reply_to: entry.email } : {}),
        subject,
        text: lines.join("\n"),
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) console.error("feedback: resend", res.status, (await res.text()).slice(0, 300));
    return res.ok;
  } catch (e) {
    console.error("feedback: resend", e);
    return false;
  }
}

/** One entry on the admin page. @param {any} e @param {string} path */
export function entryHTML(e, path) {
  /** @param {string} action @param {string} label @param {string} [cls] */
  const button = (action, label, cls = "btn-quiet") =>
    `<form method="post" action="${path}"><input type="hidden" name="action" value="${action}"><input type="hidden" name="id" value="${esc(e.id)}"><button class="${cls}">${label}</button></form>`;
  const when = esc(e.receivedAt) + (e.writtenAt && Date.parse(e.receivedAt) - Date.parse(e.writtenAt) > 60_000 ? ` (written ${esc(e.writtenAt)}, sent later)` : "");
  return `<div class="item" id="f-${esc(e.id)}">
<h3>${e.done ? "Done · " : ""}${when}</h3>
<p class="meta">${e.email ? `Reply to <a href="mailto:${esc(e.email)}">${esc(e.email)}</a>` : "No reply address"}${e.app ? ` · ${esc(appLine(e.app))}` : " · no app details"}</p>
<pre aria-label="Message">${esc(e.message)}</pre>
${picturesOf(e).map((_, n) => {
    const src = `${path}?shot=${esc(e.id)}${n ? `&amp;n=${n}` : ""}`;
    return `<a href="${src}"><img alt="Picture ${n + 1} sent with this message" src="${src}" loading="lazy"></a>`;
  }).join("\n")}
${repliesHTML(e, path)}
<p class="actions">${e.done ? button("open", "Mark as open") : button("done", "Mark as done", "btn-open")}${button("delete", "Delete", "btn-quiet danger")}</p>
</div>`;
}

/** The replies sent to an entry's sender, and a form for the next one (only with a reply address). @param {any} e
 *  @param {string} path */
function repliesHTML(e, path) {
  const sent = Array.isArray(e.replies) ? e.replies : [];
  const shown = sent.map((/** @type {any} */ r) => `<p class="meta reply-sent">Replied · ${esc(r.label)} · ${esc(r.sentAt)} · ${esc(r.subject)}</p>
<pre aria-label="Reply ${esc(r.label)}">${esc(r.text)}</pre>`).join("\n");
  if (!e.email) return shown;
  const taken = new Set(sent.map((/** @type {any} */ r) => r.label));
  const options = REPLY_LABELS.map((l) => `<option value="${l}"${taken.has(l) ? " disabled" : ""}>${l}${taken.has(l) ? " (sent)" : ""}</option>`).join("");
  return `${shown}
<details class="reply"><summary>Reply to ${esc(e.email)}…</summary>
<form method="post" action="${path}"><input type="hidden" name="action" value="reply"><input type="hidden" name="id" value="${esc(e.id)}">
<label>Label <select name="label" required>${options}</select></label>
<label>Subject <input name="subject" maxlength="200" placeholder="Re: your Airc feedback"></label>
<label>Text <textarea name="text" rows="8" maxlength="5000" required></textarea></label>
<p class="meta">Sent from Airc &lt;${INBOX}&gt;, once per label. Keep the entry until the last reply is sent.</p>
<button class="btn-open">Send reply</button></form></details>`;
}

/** The admin page's styles for replies. */
export const REPLY_CSS = `.reply summary { margin: 12px 0 0; cursor: pointer; font-size: 14px; font-weight: 600; }
.reply form { display: grid; gap: 10px; margin: 10px 0 0; }
.reply label { display: grid; gap: 4px; font-size: 13px; color: var(--t3); }
.reply input, .reply select, .reply textarea { font: inherit; font-size: 14px; padding: 8px 10px; border: 0; border-radius: 9px;
  background: var(--bg-sunk); box-shadow: inset 0 0 0 1px var(--hl-strong); color: inherit; }
.reply button { justify-self: start; }
.reply-sent { color: #1d6b3a; }`;
