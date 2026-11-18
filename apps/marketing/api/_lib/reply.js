// The owner's replies to feedback (docs/dev/feedback-service.md, "Replies"): a short email from hello@aircbrowser.com
// to the address a sender left, such as "we're working on it" and later "it's released". Only the admin can send one
// (api/feedback.js: POST /api/admin/feedback-reply, or the form on /admin/feedback), and only to the entry's own reply
// address, looked up here: a request never names a recipient. Each (entry, label) is sent at most once: a claim record
// under feedback/replies/ is made before the send, Resend gets an Idempotency-Key of the same pair, and the sent reply
// is recorded on the entry (time, label, subject, text), where the admin page shows it.
import { entryKey, HIDDEN, INBOX, REPLY_LABELS } from "./feedback.js";
import { Conflict, getJSON, update } from "./store.js";

export const FROM = `Airc <${INBOX}>`;
/** A reply's label: what it says, in a word or a few joined with dashes ("working-on-it", "released"). */
export const LABEL = /^[a-z0-9][a-z0-9-]{0,31}$/;
export { REPLY_LABELS };
export const MAX_REPLY = 5000; // characters
export const MAX_SUBJECT = 200;
export const DEFAULT_SUBJECT = "Re: your Airc feedback";
/** A claim this old whose send never finished (the function stopped mid-way) may be taken over. */
export const STALE_MS = 2 * 60 * 1000;

/** The claim record of one reply. @param {string} id @param {string} label */
export const replyKey = (id, label) => `feedback/replies/${id}/${label}.json`;

/** An answer for the request: HTTP status, error code and a message the admin can read. */
export class ReplyError extends Error {
  /** @param {number} status @param {string} code @param {string} message */
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/**
 * Checks a reply's label, text and subject; throws ReplyError (422) with the reason.
 * @param {{ label?: unknown, text?: unknown, subject?: unknown }} v
 * @returns {{ label: string, text: string, subject: string }}
 */
export function decodeReply(v) {
  const bad = (/** @type {string} */ why) => {
    throw new ReplyError(422, "invalid", why);
  };
  if (typeof v.label !== "string" || !LABEL.test(v.label)) bad("The label is a few lowercase words joined with dashes, like working-on-it.");
  if (typeof v.text !== "string" || v.text.trim() === "") bad("Write the reply first.");
  const text = v.text.replace(/\r\n?/g, "\n").trim();
  if ([...text].length > MAX_REPLY) bad(`The reply is longer than ${MAX_REPLY} characters.`);
  if (HIDDEN.test(text)) bad("The reply has hidden characters in it.");
  let subject = DEFAULT_SUBJECT;
  if (v.subject !== undefined && v.subject !== null && v.subject !== "") {
    if (typeof v.subject !== "string") bad("The subject isn't text.");
    subject = v.subject.trim();
    if (!subject || [...subject].length > MAX_SUBJECT || /[\r\n]/.test(subject) || HIDDEN.test(subject)) bad("The subject is one line of at most 200 characters.");
  }
  return { label: v.label, text, subject };
}

/**
 * Sends one reply to entry `id`'s reply address and records it. Returns the answer's status and body:
 * 201 { sent: true, … } when it went out now, 200 { sent: false, already: true, … } when this label was sent before.
 * Throws ReplyError for anything refused (no entry, no reply address, a send in progress, Resend failing).
 * @param {import("./store.js").Store} s @param {string} id @param {{ label: string, text: string, subject: string }} reply
 * @param {{ fetch?: typeof fetch, key?: string, now?: () => number }} [o]
 */
export async function sendReply(s, id, reply, o = {}) {
  const now = o.now ?? Date.now;
  const r = await getJSON(s, entryKey(id));
  if (!r || r.value.pending) throw new ReplyError(404, "notFound", "No such entry.");
  const to = r.value.email;
  if (!to) throw new ReplyError(422, "noAddress", "This entry has no reply address.");
  const before = (r.value.replies ?? []).find((/** @type {any} */ x) => x.label === reply.label);
  if (before) return { status: 200, body: { sent: false, already: true, label: reply.label, sentAt: before.sentAt } };
  const key = o.key ?? process.env.RESEND_API_KEY;
  if (!key) throw new ReplyError(503, "noMail", "Mail isn't set up on this deployment (RESEND_API_KEY).");

  // The claim: only one request sends a given (entry, label).
  const claim = replyKey(id, reply.label);
  try {
    await s.put(claim, JSON.stringify({ state: "sending", at: now() }));
  } catch (e) {
    if (!(e instanceof Conflict)) throw e;
    const c = await getJSON(s, claim);
    if (c?.value.state === "sent") return { status: 200, body: { sent: false, already: true, label: reply.label, sentAt: c.value.sentAt } };
    if (c && now() - Number(c.value.at) < STALE_MS) throw new ReplyError(409, "inProgress", "This reply is being sent right now.");
    try {
      if (c) await s.put(claim, JSON.stringify({ state: "sending", at: now() }), { ifMatch: c.etag });
      else await s.put(claim, JSON.stringify({ state: "sending", at: now() }));
    } catch (e2) {
      if (e2 instanceof Conflict) throw new ReplyError(409, "inProgress", "This reply is being sent right now.");
      throw e2;
    }
  }

  let resendId = null;
  try {
    const res = await (o.fetch ?? fetch)("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "Idempotency-Key": `reply-${id}-${reply.label}` },
      body: JSON.stringify({ from: FROM, to: [to], reply_to: INBOX, subject: reply.subject, text: reply.text }),
      signal: AbortSignal.timeout(10000),
    });
    const answer = await res.text();
    if (!res.ok) {
      console.error("feedback reply: resend", res.status, answer.slice(0, 300));
      throw new ReplyError(502, "sendFailed", `The mail service refused it (${res.status}). Nothing was sent; try again.`);
    }
    try {
      resendId = JSON.parse(answer).id ?? null;
    } catch {
      resendId = null;
    }
  } catch (e) {
    await s.del(claim).catch(() => {});
    if (e instanceof ReplyError) throw e;
    console.error("feedback reply: resend", e);
    throw new ReplyError(502, "sendFailed", "The mail service didn't answer. Nothing was sent; try again.");
  }

  const sentAt = new Date(now()).toISOString();
  const record = { label: reply.label, sentAt, subject: reply.subject, text: reply.text, ...(resendId ? { resendId: String(resendId).slice(0, 64) } : {}) };
  try {
    await update(s, entryKey(id), (/** @type {any} */ old) => {
      if (!old) throw new ReplyError(404, "gone", "The entry was deleted while the reply was sent.");
      return { ...old, replies: [...(old.replies ?? []).filter((/** @type {any} */ x) => x.label !== reply.label), record] };
    });
  } catch (e) {
    if (!(e instanceof ReplyError)) throw e;
  }
  await s.put(claim, JSON.stringify({ state: "sent", at: now(), sentAt }), { overwrite: true });
  return { status: 201, body: { sent: true, label: reply.label, sentAt } };
}
