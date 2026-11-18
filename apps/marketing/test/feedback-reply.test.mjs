// The owner's replies to feedback (api/_lib/reply.js; POST /api/admin/feedback-reply and the admin page's form) against
// the in-memory store and a fake Resend: nothing is ever mailed from here.
//   cd apps/marketing && node --test test/
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, test } from "node:test";

process.env.SHARING_MEMORY_STORE = "1";
process.env.SHARING_ADMIN_SECRET = "test-admin-secret-0123456789abcdef";
delete process.env.SHARING_READ_WRITE_TOKEN;
delete process.env.VERCEL_ENV;
delete process.env.RESEND_API_KEY;

const feedback = await import("../api/feedback.js");
const lib = await import("../api/_lib/feedback.js");
const reply = await import("../api/_lib/reply.js");
const { resetMemoryStore } = await import("../api/_lib/store.js");
const { LIMITS } = await import("../api/_lib/rate.js");

const BASE = "https://test.example";
let ip = 0;
function req(path, { method = "GET", body, headers = {}, from, type = "application/json" } = {}) {
  return new Request(BASE + path, {
    method,
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    headers: { "x-real-ip": from ?? `10.2.${Math.floor(++ip / 250)}.${ip % 250}`, ...(body !== undefined && type ? { "content-type": type } : {}), ...headers },
  });
}
const ADMIN = { authorization: `Basic ${Buffer.from("lead:test-admin-secret-0123456789abcdef").toString("base64")}` };
const WRONG = { authorization: `Basic ${Buffer.from("lead:not-the-password").toString("base64")}` };
// What vercel.json rewrites POST /api/admin/feedback-reply to.
const REPLY = "/api/feedback?view=admin&reply=1";
const post = (body, o = {}) => feedback.POST(req(REPLY, { method: "POST", body, ...o, headers: { ...ADMIN, ...(o.headers ?? {}) } }));
const TEXT = "Hi,\n\nthanks for the report. We're working on it.\n\nThe Airc team";

let s, calls, answer;
beforeEach(() => {
  s = resetMemoryStore();
  calls = [];
  answer = () => new Response(JSON.stringify({ id: "fake-email-1" }), { status: 200 });
  globalThis.__realFetch ??= globalThis.fetch;
  globalThis.fetch = async (url, init) => (calls.push({ url: String(url), init, body: JSON.parse(init.body) }), answer());
  process.env.RESEND_API_KEY = "fake-resend-key-for-tests";
});
afterEach(() => {
  globalThis.fetch = globalThis.__realFetch;
  delete process.env.RESEND_API_KEY;
});

/** A published entry, sent the way Airc sends it. */
async function entry(over = {}) {
  const r = await feedback.POST(req("/api/feedback", { method: "POST", body: { version: 1, message: "Dark mode doesn't work.", ...over } }));
  assert.equal(r.status, 201);
  return (await r.json()).id;
}

describe("POST /api/admin/feedback-reply", () => {
  test("closed without the admin password (401), and wrong passwords count toward the limit", async () => {
    const id = await entry({ email: "sender@example.com" });
    assert.equal((await feedback.POST(req(REPLY, { method: "POST", body: { id, label: "working-on-it", text: TEXT } }))).status, 401);
    assert.equal((await feedback.POST(req(REPLY, { method: "POST", body: { id, label: "working-on-it", text: TEXT }, headers: WRONG }))).status, 401);
    for (let i = 0; i < LIMITS.admin; i++) await feedback.POST(req(REPLY, { method: "POST", body: {}, headers: WRONG, from: "198.51.100.20" }));
    assert.equal((await feedback.POST(req(REPLY, { method: "POST", body: {}, headers: WRONG, from: "198.51.100.20" }))).status, 429);
    assert.equal(calls.length, 0);
  });

  test("mails the entry's own address from hello@, records it, and a retry doesn't send again", async () => {
    const id = await entry({ email: "sender@example.com" });
    const r = await post({ id, label: "working-on-it", text: TEXT, subject: "Re: your Airc feedback (dark mode)" });
    assert.equal(r.status, 201);
    const got = await r.json();
    assert.equal(got.sent, true);
    assert.equal(got.label, "working-on-it");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://api.resend.com/emails");
    assert.deepEqual(calls[0].body, {
      from: "Airc <hello@aircbrowser.com>", to: ["sender@example.com"], reply_to: "hello@aircbrowser.com",
      subject: "Re: your Airc feedback (dark mode)", text: TEXT,
    });
    assert.equal(calls[0].init.headers["Idempotency-Key"], `reply-${id}-working-on-it`);
    assert.equal(calls[0].init.headers.Authorization, "Bearer fake-resend-key-for-tests");

    const e = JSON.parse((await s.get(lib.entryKey(id))).text);
    assert.equal(e.replies.length, 1);
    assert.equal(e.replies[0].label, "working-on-it");
    assert.equal(e.replies[0].text, TEXT);
    assert.equal(e.replies[0].sentAt, got.sentAt);
    assert.equal(e.replies[0].resendId, "fake-email-1");

    const again = await post({ id, label: "working-on-it", text: "something else" });
    assert.equal(again.status, 200);
    assert.deepEqual(await again.json(), { sent: false, already: true, label: "working-on-it", sentAt: got.sentAt });
    assert.equal(calls.length, 1);

    // Another label is another email; the default subject when none is given.
    const released = await post({ id, label: "released", text: "It's out in 0.1.33." });
    assert.equal(released.status, 201);
    assert.equal(calls.length, 2);
    assert.equal(calls[1].body.subject, "Re: your Airc feedback");
    assert.equal(JSON.parse((await s.get(lib.entryKey(id))).text).replies.length, 2);
  });

  test("never takes a recipient, and refuses entries without a reply address", async () => {
    const id = await entry({ email: "sender@example.com" });
    const to = await post({ id, label: "working-on-it", text: TEXT, to: "someone-else@example.com" });
    assert.equal(to.status, 422);
    const none = await entry();
    const r = await post({ id: none, label: "working-on-it", text: TEXT });
    assert.equal(r.status, 422);
    assert.equal((await r.json()).error, "noAddress");
    assert.equal((await post({ id: "AbCdEfGhIjKl", label: "working-on-it", text: TEXT })).status, 404);
    assert.equal((await post({ id: "../x", label: "working-on-it", text: TEXT })).status, 404);
    assert.equal(calls.length, 0);
  });

  test("refuses bad labels, empty or hidden text, multi-line subjects, forms and other sites", async () => {
    const id = await entry({ email: "sender@example.com" });
    for (const body of [
      { id, label: "Working On It", text: TEXT },
      { id, label: "x/../y", text: TEXT },
      { id, label: "working-on-it", text: "  " },
      { id, label: "working-on-it", text: "x".repeat(reply.MAX_REPLY + 1) },
      { id, label: "working-on-it", text: "hi ‮ there" },
      { id, label: "working-on-it", text: TEXT, subject: "Hi\nBcc: x@example.com" },
    ]) assert.equal((await post(body)).status, 422, JSON.stringify(body).slice(0, 80));
    assert.equal((await post("not json")).status, 400);
    assert.equal((await post(`id=${id}&label=working-on-it&text=hi`, { type: "application/x-www-form-urlencoded" })).status, 415);
    assert.equal((await post({ id, label: "working-on-it", text: TEXT }, { headers: { origin: "https://evil.example", host: "test.example" } })).status, 403);
    assert.equal(calls.length, 0);
  });

  test("a failed send records nothing and can be retried; a send in progress isn't doubled", async () => {
    const id = await entry({ email: "sender@example.com" });
    answer = () => new Response('{"message":"nope"}', { status: 500 });
    const r = await post({ id, label: "working-on-it", text: TEXT });
    assert.equal(r.status, 502);
    assert.equal(JSON.parse((await s.get(lib.entryKey(id))).text).replies, undefined);
    assert.equal(await s.get(reply.replyKey(id, "working-on-it")), null);
    answer = () => { throw new Error("offline"); };
    assert.equal((await post({ id, label: "working-on-it", text: TEXT })).status, 502);
    answer = () => new Response("{}", { status: 200 });
    assert.equal((await post({ id, label: "working-on-it", text: TEXT })).status, 201);
    assert.equal(calls.length, 3);

    // A claim another request holds: 409, until it's stale.
    await s.put(reply.replyKey(id, "released"), JSON.stringify({ state: "sending", at: Date.now() }));
    assert.equal((await post({ id, label: "released", text: TEXT })).status, 409);
    assert.equal(calls.length, 3);
    const old = await s.get(reply.replyKey(id, "released"));
    await s.put(reply.replyKey(id, "released"), JSON.stringify({ state: "sending", at: Date.now() - reply.STALE_MS - 1 }), { ifMatch: old.etag });
    assert.equal((await post({ id, label: "released", text: TEXT })).status, 201);
    assert.equal(calls.length, 4);
  });

  test("two requests at once send one email", async () => {
    const id = await entry({ email: "sender@example.com" });
    const [a, b] = await Promise.all([post({ id, label: "working-on-it", text: TEXT }), post({ id, label: "working-on-it", text: TEXT })]);
    assert.deepEqual([a.status, b.status].sort(), [201, 409]);
    assert.equal(calls.length, 1);
  });

  test("without a mail key it says so and sends nothing", async () => {
    const id = await entry({ email: "sender@example.com" });
    delete process.env.RESEND_API_KEY;
    const r = await post({ id, label: "working-on-it", text: TEXT });
    assert.equal(r.status, 503);
    assert.equal(calls.length, 0);
  });

  test("rate-limited per visitor", async () => {
    const none = await entry();
    for (let i = 0; i < LIMITS.feedbackReply; i++) await post({ id: none, label: "working-on-it", text: TEXT }, { from: "198.51.100.30" });
    assert.equal((await post({ id: none, label: "working-on-it", text: TEXT }, { from: "198.51.100.30" })).status, 429);
  });
});

describe("replies on /admin/feedback", () => {
  const page = async () => (await feedback.GET(req("/admin/feedback?view=admin", { headers: ADMIN }))).text();
  const form = (body, headers = { origin: BASE, host: "test.example" }) =>
    feedback.POST(req("/admin/feedback?view=admin", { method: "POST", body, type: "application/x-www-form-urlencoded", headers: { ...ADMIN, ...headers } }));

  test("the form sends a reply, the entry shows it, and that label can't be picked again", async () => {
    const id = await entry({ email: "sender@example.com" });
    const none = await entry({ message: "no address here" });
    let html = await page();
    assert.match(html, new RegExp(`<input type="hidden" name="action" value="reply"><input type="hidden" name="id" value="${id}">`));
    assert.equal((html.match(/value="reply"/g) ?? []).length, 1, `only ${id} has a reply form, not ${none}`);

    const body = new URLSearchParams({ action: "reply", id, label: "working-on-it", subject: "", text: "We're <on> it." }).toString();
    assert.equal((await form(body, { origin: "https://evil.example", host: "test.example" })).status, 403);
    const r = await form(body);
    assert.equal(r.status, 303);
    assert.equal(r.headers.get("location"), `/admin/feedback#f-${id}`);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].body.text, "We're <on> it.");
    html = await page();
    assert.match(html, /Replied · working-on-it · \d{4}-/);
    assert.match(html, /We&#39;re &lt;on&gt; it\./);
    assert.match(html, /<option value="working-on-it" disabled>working-on-it \(sent\)<\/option>/);
    assert.equal((await form(new URLSearchParams({ action: "reply", id: none, label: "released", text: "hi" }).toString())).status, 422);

    // Deleting the entry deletes its reply records too.
    assert.equal((await form(`action=delete&id=${id}`)).status, 303);
    assert.equal((await s.list(`feedback/replies/${id}/`)).length, 0);
  });
});
