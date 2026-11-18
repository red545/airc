// Per-visitor rate limits, in hour windows. A window's counters are named by a keyed hash of the visitor's address
// (HMAC with SHARING_RATE_SALT, a secret, and the window), never by the address. They expire lazily: a visitor's
// first request in a new hour deletes their counter of the hour before, and the daily sweep (api/sweep.js) deletes
// every past window that's left, so no counter outlives its hour by more than a day.
import { createHmac } from "node:crypto";
import { clientAddress, problem } from "./http.js";
import { Conflict } from "./store.js";

export const WINDOW_SECONDS = 3600;

/** Requests one visitor may make per hour, by kind. */
export const LIMITS = {
  share: 30, // new share links (Spaces, folders, Easels)
  asset: 400, // an Easel link's pictures (at most 200 each)
  revoke: 60,
  submit: 10, // Boosts sent to the gallery
  report: 20,
  admin: 20, // failed admin sign-ins
  feedback: 10, // feedback sent from Airc (api/feedback.js)
  feedbackImage: 60, // the pictures sent after a feedback message (at most 5 each)
  feedbackReply: 30, // the admin's replies to feedback senders (api/_lib/reply.js)
};

/** @param {number} [now] */
export const windowOf = (now = Date.now()) => Math.floor(now / 1000 / WINDOW_SECONDS);

/**
 * Counts one request of `kind` for this visitor; a Response (429) when they're over the limit, else null.
 * @param {import("./store.js").Store} s @param {Request} request @param {keyof typeof LIMITS} kind
 */
export async function limit(s, request, kind) {
  const salt = process.env.SHARING_RATE_SALT;
  if (!salt && process.env.SHARING_MEMORY_STORE !== "1") {
    return problem(503, "unavailable", "Sharing isn't set up on this deployment.");
  }
  const w = windowOf();
  /** @param {number} window */
  const keyOf = (window) =>
    `rate/${window}/${kind}-${createHmac("sha256", salt ?? "test").update(`${window}\n${kind}\n${clientAddress(request)}`).digest("hex").slice(0, 32)}.json`;
  const key = keyOf(w);
  const max = LIMITS[kind];
  for (let i = 0; i < 4; i++) {
    const r = await s.get(key);
    // The first request of a new hour: this visitor's counter of the hour before goes (expiry on use).
    if (!r && i === 0) await s.del(keyOf(w - 1));
    const n = r ? Number(JSON.parse(r.text).n) || 0 : 0;
    if (n >= max) {
      const retry = String((w + 1) * WINDOW_SECONDS - Math.floor(Date.now() / 1000));
      return problem(429, "rateLimited", "Too many requests from here. Try again later.", { "Retry-After": retry });
    }
    try {
      await s.put(key, JSON.stringify({ n: n + 1 }), r ? { ifMatch: r.etag } : {});
      return null;
    } catch (e) {
      if (!(e instanceof Conflict)) throw e;
    }
  }
  return problem(429, "rateLimited", "Too many requests from here. Try again later.");
}

/** Deletes every window before the current one. @param {import("./store.js").Store} s */
export async function sweep(s) {
  const current = windowOf();
  const old = (await s.list("rate/")).filter((b) => Number(b.key.split("/")[1]) < current).map((b) => b.key);
  for (let i = 0; i < old.length; i += 500) await s.del(old.slice(i, i + 500));
  return old.length;
}
