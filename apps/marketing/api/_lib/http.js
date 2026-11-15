// Small helpers the sharing functions share: answers, bounded bodies, random ids and tokens.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { Conflict, Unavailable } from "./store.js";

export const SITE = "https://aircbrowser.com";

/** @param {unknown} body @param {number} [status] @param {Record<string, string>} [headers] */
export function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...headers,
    },
  });
}

/** An error answer: `{ error, message }`. @param {number} status @param {string} error @param {string} message
 *  @param {Record<string, string>} [headers] */
export const problem = (status, error, message, headers) => json({ error, message }, status, headers);

export class TooLarge extends Error {}

/** The request's body as text, refused past `limit` bytes before and while reading it. @param {Request} request
 *  @param {number} limit */
export async function readText(request, limit) {
  return new TextDecoder("utf-8", { fatal: true }).decode(await readBytes(request, limit));
}

/** The request's body, refused past `limit` bytes before and while reading it. @param {Request} request
 *  @param {number} limit @returns {Promise<Uint8Array>} */
export async function readBytes(request, limit) {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > limit) throw new TooLarge();
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  /** @type {Uint8Array[]} */
  const parts = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new TooLarge();
    }
    parts.push(value);
  }
  return new Uint8Array(Buffer.concat(parts));
}

/** The visitor's address as Vercel's edge saw it, for rate limits only (never stored: rate.js keeps a keyed hash).
 *  @param {Request} request */
export function clientAddress(request) {
  const h = request.headers;
  return h.get("x-real-ip") ?? h.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
}

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
/** A random id of `n` letters and digits (12 by default: about 71 bits, so links can't be guessed). */
export function newID(n = 12) {
  let out = "";
  while (out.length < n) {
    for (const b of randomBytes(n * 2)) {
      if (b < 248 && out.length < n) out += ALPHABET[b % 62];
    }
  }
  return out;
}
export const ID = /^[A-Za-z0-9]{12}$/;

/** A secret token (32 random bytes, base64url) and the hash that's stored instead of it. */
export function newToken() {
  const token = randomBytes(32).toString("base64url");
  return { token, hash: sha256(token) };
}
/** @param {string} s */
export const sha256 = (s) => createHash("sha256").update(s).digest("hex");

/** Whether `a` and `b` are equal, in time that doesn't depend on where they differ. @param {string} a @param {string} b */
export function sameSecret(a, b) {
  const x = createHash("sha256").update(a).digest(), y = createHash("sha256").update(b).digest();
  return timingSafeEqual(x, y) && a.length === b.length;
}

/** The site's own origin for links in answers: aircbrowser.com in Production, the deployment's own address elsewhere
 *  (Previews, `vercel dev`, the tests). @param {Request} request */
export function origin(request) {
  if (process.env.VERCEL_ENV === "production") return SITE;
  return new URL(request.url).origin;
}

/** Runs a handler, turning the store's and the body reader's failures into answers. @param {() => Promise<Response>} f */
export async function guarded(f) {
  try {
    return await f();
  } catch (e) {
    if (e instanceof TooLarge) return problem(413, "tooLarge", "This is too large to share.");
    if (e instanceof Unavailable) return problem(503, "unavailable", "Sharing is temporarily unavailable. Try again shortly.", { "Retry-After": "2" });
    if (e instanceof Conflict) return problem(409, "busy", "Something else changed this at the same moment. Try again.");
    if (e instanceof TypeError && /decod/i.test(String(e.message))) return problem(400, "damaged", "This isn't valid UTF-8 text.");
    console.error("sharing:", e);
    return problem(500, "failed", "Something went wrong. Try again in a moment.");
  }
}

/** HTML text, escaped for an element or a quoted attribute. @param {unknown} s */
export const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c);
