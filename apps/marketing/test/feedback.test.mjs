// The feedback function (api/feedback.js) against the in-memory store: validation, the resend marker, storage, the
// rate limit, the owner's notice and the admin page's sign-in.
//   cd apps/marketing && node --test test/
// The same requests run against a Preview deployment with scripts/feedback-smoke.mjs.
import assert from "node:assert/strict";
import { beforeEach, describe, test } from "node:test";

process.env.SHARING_MEMORY_STORE = "1";
process.env.SHARING_ADMIN_SECRET = "test-admin-secret-0123456789abcdef";
delete process.env.SHARING_READ_WRITE_TOKEN;
delete process.env.VERCEL_ENV;
delete process.env.RESEND_API_KEY;

const feedback = await import("../api/feedback.js");
const lib = await import("../api/_lib/feedback.js");
const sweeper = await import("../api/sweep.js");
const { resetMemoryStore } = await import("../api/_lib/store.js");
const { LIMITS } = await import("../api/_lib/rate.js");

const BASE = "https://test.example";
let ip = 0;
function req(path, { method = "GET", body, headers = {}, from, type = "application/json" } = {}) {
  return new Request(BASE + path, {
    method,
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    headers: { "x-real-ip": from ?? `10.1.${Math.floor(++ip / 250)}.${ip % 250}`, ...(body !== undefined && type ? { "content-type": type } : {}), ...headers },
  });
}
const send = (body, o = {}) => feedback.POST(req("/api/feedback", { method: "POST", body, ...o }));
const ADMIN = { authorization: `Basic ${Buffer.from("owner:test-admin-secret-0123456789abcdef").toString("base64")}` };
const admin = (o = {}) => req("/admin/feedback?view=admin", { ...o, headers: { ...ADMIN, ...(o.headers ?? {}) } });

// A real 1×1 PNG and the start of a JPEG.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(200, 1)]);
const APP = { version: "0.1.9", build: "202611120930", engine: "chromium", macOS: "26.6", model: "Mac16,1", locale: "en_AT" };
const good = (over = {}) => ({ version: 1, message: "The sidebar flickers when I switch Spaces.", ...over });

let s;
beforeEach(() => {
  s = resetMemoryStore();
});

describe("POST /api/feedback", () => {
  test("a message alone is stored with a random id", async () => {
    const r = await send(good());
    assert.equal(r.status, 201);
    const { id } = await r.json();
    assert.match(id, /^[A-Za-z0-9]{12}$/);
    const e = JSON.parse((await s.get(lib.entryKey(id))).text);
    assert.equal(e.message, "The sidebar flickers when I switch Spaces.");
    assert.equal(e.email, null);
    assert.equal(e.app, null);
    assert.equal(e.shot, null);
    assert.equal(e.done, false);
    // Nothing about the sender beyond what they typed: no address, no headers.
    assert.doesNotMatch(JSON.stringify(e), /10\.1\.|x-real-ip/);
  });

  test("reply address, app details and a screenshot are kept when included", async () => {
    const r = await send(good({ email: "someone@example.com", app: APP, screenshot: { type: "image/png", base64: PNG.toString("base64") }, writtenAt: "2026-11-12T10:00:00Z" }));
    assert.equal(r.status, 201);
    const { id } = await r.json();
    const e = JSON.parse((await s.get(lib.entryKey(id))).text);
    assert.equal(e.email, "someone@example.com");
    assert.deepEqual(e.app, APP);
    assert.equal(e.shot, `feedback/shots/${id}.png`);
    assert.equal(e.writtenAt, "2026-11-12T10:00:00.000Z");
    assert.deepEqual(Buffer.from((await s.getBytes(e.shot)).bytes), PNG);
    const jpeg = await send(good({ screenshot: { type: "image/jpeg", base64: JPEG.toString("base64") } }));
    assert.equal(jpeg.status, 201);
  });

  test("refuses what Airc never sends", async () => {
    const cases = [
      [good({ message: "" }), 422, /Write a message/],
      [good({ message: "   \n " }), 422, /Write a message/],
      [{ message: "hi" }, 422, /format/],
      [good({ version: 2 }), 422, /format/],
      [good({ message: "x".repeat(lib.MAX_MESSAGE + 1) }), 422, /longer/],
      [good({ message: "evil ‮ txt" }), 422, /hidden/],
      [good({ email: "not an address" }), 422, /email/],
      [good({ email: "a@b.c\r\nBcc: x@y.z" }), 422, /email/],
      [good({ url: "https://example.com" }), 422, /field/],
      [good({ app: { ...APP, url: "https://example.com" } }), 422, /field/],
      [good({ app: { ...APP, version: "0.1.9; drop" } }), 422, /version/],
      [good({ app: { ...APP, engine: "gecko" } }), 422, /engine/],
      [good({ screenshot: { type: "image/gif", base64: PNG.toString("base64") } }), 422, /PNG or JPEG/],
      [good({ screenshot: { type: "image/jpeg", base64: PNG.toString("base64") } }), 422, /type it says/],
      [good({ screenshot: { type: "image/png", base64: Buffer.from("<svg onload=alert(1)>").toString("base64") } }), 422, /type it says/],
      [good({ screenshot: { type: "image/png", base64: "!!!!" } }), 422, /base64/],
      [good({ screenshot: { type: "image/png", base64: PNG.toString("base64"), name: "x" } }), 422, /field/],
      [good({ client: "short" }), 422, /id/],
      [good({ writtenAt: "yesterday" }), 422, /time/],
      ["{not json", 400, /JSON/],
      ["[1,2]", 422, /feedback message/],
    ];
    for (const [body, status, why] of cases) {
      const r = await send(body);
      assert.equal(r.status, status, JSON.stringify(body).slice(0, 120));
      assert.match((await r.json()).message, why);
    }
    assert.equal((await s.list("feedback/")).length, 0);
  });

  test("a screenshot over 2 MB is refused, and so is a body over the cap", async () => {
    const big = Buffer.concat([PNG.subarray(0, 8), Buffer.alloc(lib.MAX_SHOT, 0)]);
    const r = await send(good({ screenshot: { type: "image/png", base64: big.toString("base64") } }));
    assert.equal(r.status, 422);
    assert.match((await r.json()).message, /2 MB/);
    const huge = await send(JSON.stringify(good({ message: "x" })) + " ".repeat(lib.MAX_BODY));
    assert.equal(huge.status, 413);
    const declared = await send(good(), { headers: { "content-length": String(lib.MAX_BODY + 1) } });
    assert.equal(declared.status, 413);
  });

  test("only JSON", async () => {
    const r = await send("message=hi", { type: "application/x-www-form-urlencoded" });
    assert.equal(r.status, 415);
  });

  test("a resend of the same message (its client id) is one entry", async () => {
    const client = "6a1f0c3e-2b7d-4a8e-9c11-0f5e3d2a1b77";
    const a = await send(good({ client }));
    const b = await send(good({ client }));
    assert.equal(a.status, 201);
    assert.equal(b.status, 200);
    const [ja, jb] = [await a.json(), await b.json()];
    assert.equal(jb.id, ja.id);
    assert.equal(jb.duplicate, true);
    assert.equal((await s.list("feedback/entries/")).length, 1);
    // The marker holds a hash, not the app's id.
    assert.ok(!(await s.list("feedback/clients/"))[0].key.includes(client));
  });

  test("rate limited per visitor, like sharing", async () => {
    for (let i = 0; i < LIMITS.feedback; i++) assert.equal((await send(good(), { from: "192.0.2.7" })).status, 201);
    const r = await send(good(), { from: "192.0.2.7" });
    assert.equal(r.status, 429);
    assert.ok(Number(r.headers.get("retry-after")) > 0);
    assert.equal((await send(good(), { from: "192.0.2.8" })).status, 201);
    // The counter is under a keyed hash, never the address.
    assert.ok((await s.list("rate/")).every((b) => !b.key.includes("192.0.2")));
  });

  test("GET answers 405 and reads nothing back", async () => {
    await send(good());
    const r = await feedback.GET(req("/api/feedback"));
    assert.equal(r.status, 405);
    assert.equal(r.headers.get("allow"), "POST");
    assert.doesNotMatch(await r.text(), /sidebar flickers/);
  });

  test("no store configured: 503, nothing written", async () => {
    // (store() caches; a fresh import isn't needed: the rate limiter checks its salt the same way.)
    const saved = process.env.SHARING_MEMORY_STORE;
    delete process.env.SHARING_MEMORY_STORE;
    try {
      const r = await send(good());
      assert.equal(r.status, 503);
    } finally {
      process.env.SHARING_MEMORY_STORE = saved;
    }
  });
});

describe("the owner's notice", () => {
  test("outside Production nothing is mailed", async () => {
    const real = globalThis.fetch;
    let called = 0;
    globalThis.fetch = async () => (called++, new Response("{}"));
    process.env.RESEND_API_KEY = "re_test";
    try {
      process.env.VERCEL_ENV = "preview";
      assert.equal((await send(good())).status, 201);
      delete process.env.VERCEL_ENV;
      assert.equal((await send(good())).status, 201);
      assert.equal(called, 0);
    } finally {
      globalThis.fetch = real;
      delete process.env.RESEND_API_KEY;
      delete process.env.VERCEL_ENV;
    }
  });

  test("notify mails hello@ through Resend with the message, Reply-To the sender, and no picture", async () => {
    /** @type {any[]} */
    const calls = [];
    const fake = async (url, init) => (calls.push({ url, init }), new Response("{}", { status: 200 }));
    const ok = await lib.notify({ id: "AbCdEfGhIjKl", message: "Line one\nmore", email: "someone@example.com", app: APP, shot: "feedback/shots/x.png" }, { fetch: fake, key: "re_test" });
    assert.equal(ok, true);
    assert.equal(calls[0].url, "https://api.resend.com/emails");
    const body = JSON.parse(calls[0].init.body);
    assert.equal(body.to, "hello@aircbrowser.com");
    assert.equal(body.reply_to, "someone@example.com");
    assert.equal(body.subject, "Feedback: Line one");
    assert.match(body.text, /Line one\nmore/);
    assert.match(body.text, /Airc 0\.1\.9 \(202611120930\) · Chromium · macOS 26\.6 · Mac16,1 · en_AT/);
    assert.match(body.text, /admin\/feedback#f-AbCdEfGhIjKl/);
    assert.equal(body.attachments, undefined);
    assert.equal(calls[0].init.headers["Idempotency-Key"], "feedback-AbCdEfGhIjKl");
    // A failed send never fails the feedback.
    assert.equal(await lib.notify({ id: "x", message: "m", email: null, app: null, shot: null }, { fetch: async () => { throw new Error("offline"); }, key: "k" }), false);
    assert.equal(await lib.notify({ id: "x", message: "m", email: null, app: null, shot: null }, { fetch: fake, key: "" }), false);
  });
});

describe("/admin/feedback", () => {
  test("closed without the password, behind the same sign-in as /admin/boosts", async () => {
    assert.equal((await feedback.GET(req("/admin/feedback?view=admin"))).status, 401);
    const wrong = { authorization: `Basic ${Buffer.from("owner:wrong").toString("base64")}` };
    assert.equal((await feedback.GET(req("/admin/feedback?view=admin", { headers: wrong }))).status, 401);
    for (let i = 0; i < LIMITS.admin; i++) await feedback.GET(req("/admin/feedback?view=admin", { headers: wrong, from: "198.51.100.9" }));
    assert.equal((await feedback.GET(req("/admin/feedback?view=admin", { headers: wrong, from: "198.51.100.9" }))).status, 429);
    const saved = process.env.SHARING_ADMIN_SECRET;
    delete process.env.SHARING_ADMIN_SECRET;
    try {
      assert.equal((await feedback.GET(admin())).status, 503);
    } finally {
      process.env.SHARING_ADMIN_SECRET = saved;
    }
    // The picture and the actions are behind it too.
    assert.equal((await feedback.GET(req("/admin/feedback?view=admin&shot=AbCdEfGhIjKl"))).status, 401);
    assert.equal((await feedback.POST(req("/admin/feedback?view=admin", { method: "POST", body: "action=delete&id=AbCdEfGhIjKl", type: "application/x-www-form-urlencoded" }))).status, 401);
  });

  test("lists entries with their screenshots, escaped; mark done, reopen, delete", async () => {
    const { id } = await (await send(good({ message: "<script>alert(1)</script> it broke", email: "someone@example.com", app: APP, screenshot: { type: "image/png", base64: PNG.toString("base64") } }))).json();
    const { id: other } = await (await send(good({ message: "second one" }))).json();
    let r = await feedback.GET(admin());
    assert.equal(r.status, 200);
    let html = await r.text();
    assert.match(html, /2 open, 0 done/);
    assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt; it broke/);
    assert.doesNotMatch(html, /<script>alert/);
    assert.match(html, new RegExp(`src="/admin/feedback\\?shot=${id}"`));
    assert.match(html, /mailto:someone@example.com/);
    assert.match(html, /Airc 0\.1\.9/);
    assert.match(r.headers.get("content-security-policy") ?? "", /default-src 'none'/);

    const pic = await feedback.GET(req(`/admin/feedback?view=admin&shot=${id}`, { headers: ADMIN }));
    assert.equal(pic.status, 200);
    assert.equal(pic.headers.get("content-type"), "image/png");
    assert.deepEqual(Buffer.from(await pic.arrayBuffer()), PNG);
    assert.equal((await feedback.GET(req(`/admin/feedback?view=admin&shot=${other}`, { headers: ADMIN }))).status, 404);

    const act = (body, headers = { origin: BASE, host: "test.example" }) =>
      feedback.POST(req("/admin/feedback?view=admin", { method: "POST", body, type: "application/x-www-form-urlencoded", headers: { ...ADMIN, ...headers } }));
    assert.equal((await act(`action=done&id=${id}`, { origin: "https://evil.example", host: "test.example" })).status, 403);
    assert.equal((await act(`action=done&id=${id}`)).status, 303);
    html = await (await feedback.GET(admin())).text();
    assert.match(html, /1 open, 1 done/);
    assert.equal((await act(`action=open&id=${id}`)).status, 303);
    assert.match(await (await feedback.GET(admin())).text(), /2 open, 0 done/);
    assert.equal((await act(`action=explode&id=${id}`)).status, 400);
    assert.equal((await act(`action=delete&id=nope`)).status, 400);
    assert.equal((await act(`action=delete&id=${id}`)).status, 303);
    assert.equal(await s.get(lib.entryKey(id)), null);
    assert.equal((await s.list("feedback/shots/")).length, 0);
    assert.equal((await act(`action=delete&id=${id}`)).status, 404);
    assert.match(await (await feedback.GET(admin())).text(), /1 open, 0 done/);
  });
});

describe("the sweep", () => {
  test("drops resend markers older than 30 days, never entries", async () => {
    await send(good({ client: "6a1f0c3e-2b7d-4a8e-9c11-0f5e3d2a1b77" }));
    const r = await sweeper.GET(req("/api/sweep"));
    assert.equal(r.status, 200);
    assert.equal((await r.json()).feedbackMarkers, 0);
    const realNow = Date.now;
    Date.now = () => realNow() + 31 * 86_400_000;
    try {
      assert.equal((await (await sweeper.GET(req("/api/sweep"))).json()).feedbackMarkers, 1);
    } finally {
      Date.now = realNow;
    }
    assert.equal((await s.list("feedback/entries/")).length, 1);
  });
});

// feedback2: up to five pictures, each sent on its own after the message (Vercel takes at most 4.5 MB a request).
import { createHash } from "node:crypto";
const sha = (b) => createHash("sha256").update(b).digest("hex");
const CLIENT = "0d7c1b9e-5a4f-4c2e-8b3d-7e6f5a4b3c21";
const listed = (b, type = "image/png") => ({ type, size: b.length, sha256: sha(b) });
const put = (id, n, bytes, { type = "image/png", token = CLIENT } = {}) =>
  feedback.PUT(new Request(`${BASE}/api/feedback?id=${id}&image=${n}`, {
    method: "PUT", body: bytes, headers: { "content-type": type, "x-real-ip": "10.9.0.1", ...(token ? { authorization: `Bearer ${token}` } : {}) },
  }));
const publish = (id, token = CLIENT) =>
  feedback.POST(new Request(`${BASE}/api/feedback?id=${id}&publish=1`, { method: "POST", headers: { authorization: `Bearer ${token}`, "x-real-ip": "10.9.0.2" } }));
/** A JPEG with what a phone puts in it: Exif with GPS, XMP, a comment; then a tiny scan. */
const seg = (m, payload) => Buffer.concat([Buffer.from([0xff, m, (payload.length + 2) >> 8, (payload.length + 2) & 0xff]), payload]);
const EXIF_JPEG = Buffer.concat([
  Buffer.from([0xff, 0xd8]),
  seg(0xe0, Buffer.from("JFIF\0\x01\x01\0\0\x01\0\x01\0\0", "latin1")),
  seg(0xe1, Buffer.from("Exif\0\0GPSLatitude 48.2082 N GPSLongitude 16.3738 E", "latin1")),
  seg(0xe1, Buffer.from("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>Vienna</x:xmpmeta>", "latin1")),
  seg(0xe2, Buffer.from("ICC_PROFILE\0\x01\x01profile-bytes", "latin1")),
  seg(0xfe, Buffer.from("taken at home", "latin1")),
  seg(0xdb, Buffer.alloc(65, 1)),
  seg(0xda, Buffer.from([1, 1, 0, 0, 0x3f, 0])), Buffer.from([0x12, 0x34, 0xff, 0x00, 0x56]),
  Buffer.from([0xff, 0xd9]),
]);
/** The 1×1 PNG with a text chunk (a location written by some editor) before its end. */
const TEXT_PNG = (() => {
  const end = PNG.length - 12;
  const text = Buffer.from("Location\0Vienna, Austria", "latin1");
  const chunk = Buffer.concat([Buffer.from([0, 0, 0, text.length]), Buffer.from("tEXt"), text, Buffer.alloc(4)]);
  return Buffer.concat([PNG.subarray(0, end), chunk, PNG.subarray(end)]);
})();

describe("pictures sent after the message", () => {
  test("listed, sent one by one, then published: stored without metadata, shown on the admin page", async () => {
    const r = await send(good({ client: CLIENT, images: [listed(PNG), listed(EXIF_JPEG, "image/jpeg"), listed(TEXT_PNG)] }));
    assert.equal(r.status, 201);
    const { id, missing } = await r.json();
    assert.deepEqual(missing, [0, 1, 2]);
    // Not on the admin page until every picture is there.
    assert.match(await (await feedback.GET(admin())).text(), /0 open, 0 done/);
    assert.equal((await publish(id)).status, 409);
    assert.equal((await put(id, 0, PNG)).status, 204);
    assert.equal((await put(id, 1, EXIF_JPEG, { type: "image/jpeg" })).status, 204);
    const early = await publish(id);
    assert.equal(early.status, 409);
    assert.deepEqual((await early.json()).missing, [2]);
    // A resend of the message (its answer was lost) says what's still missing.
    const again = await send(good({ client: CLIENT, images: [listed(PNG), listed(EXIF_JPEG, "image/jpeg"), listed(TEXT_PNG)] }));
    assert.deepEqual(await again.json(), { id, duplicate: true, missing: [2] });
    assert.equal((await put(id, 2, TEXT_PNG)).status, 204);
    const done = await publish(id);
    assert.equal(done.status, 200);
    assert.deepEqual(await done.json(), { id });
    assert.equal((await publish(id)).status, 200);   // twice is fine
    // A late repeat of a picture changes nothing.
    assert.equal((await put(id, 0, PNG)).status, 204);

    const e = JSON.parse((await s.get(lib.entryKey(id))).text);
    assert.equal(e.pending, false);
    assert.equal(e.images.length, 3);
    const jpeg = Buffer.from((await s.getBytes(e.images[1].key)).bytes);
    assert.doesNotMatch(jpeg.toString("latin1"), /Exif|GPS|xmpmeta|Vienna|taken at home/);
    assert.match(jpeg.toString("latin1"), /JFIF/);
    assert.match(jpeg.toString("latin1"), /ICC_PROFILE/);
    assert.deepEqual(jpeg.subarray(-7), Buffer.from([0x12, 0x34, 0xff, 0x00, 0x56, 0xff, 0xd9]));
    const png = Buffer.from((await s.getBytes(e.images[2].key)).bytes);
    assert.deepEqual(png, PNG);
    assert.deepEqual(Buffer.from((await s.getBytes(e.images[0].key)).bytes), PNG);

    const html = await (await feedback.GET(admin())).text();
    assert.match(html, /1 open, 0 done/);
    assert.match(html, new RegExp(`src="/admin/feedback\\?shot=${id}"`));
    assert.match(html, new RegExp(`src="/admin/feedback\\?shot=${id}&amp;n=2"`));
    const pic = await feedback.GET(req(`/admin/feedback?view=admin&shot=${id}&n=1`, { headers: ADMIN }));
    assert.equal(pic.headers.get("content-type"), "image/jpeg");
    assert.deepEqual(Buffer.from(await pic.arrayBuffer()), jpeg);
    assert.equal((await feedback.GET(req(`/admin/feedback?view=admin&shot=${id}&n=3`, { headers: ADMIN }))).status, 404);

    // Delete takes every picture with it.
    const del = await feedback.POST(req("/admin/feedback?view=admin", { method: "POST", body: `action=delete&id=${id}`, type: "application/x-www-form-urlencoded", headers: { ...ADMIN, origin: BASE, host: "test.example" } }));
    assert.equal(del.status, 303);
    assert.equal((await s.list("feedback/images/")).length, 0);
  });

  test("only the message's own Airc may send its pictures, and only the ones it listed", async () => {
    const { id } = await (await send(good({ client: CLIENT, images: [listed(PNG)] }))).json();
    assert.equal((await put(id, 0, PNG, { token: null })).status, 403);
    assert.equal((await put(id, 0, PNG, { token: "ffffffff-ffff-4fff-8fff-ffffffffffff" })).status, 403);
    assert.equal((await publish(id, "ffffffff-ffff-4fff-8fff-ffffffffffff")).status, 403);
    assert.equal((await put("AAAAAAAAAAAA", 0, PNG)).status, 404);
    assert.equal((await put(id, 1, PNG)).status, 404);
    assert.equal((await put(id, 0, PNG, { type: "image/jpeg" })).status, 415);
    assert.equal((await put(id, 0, TEXT_PNG)).status, 422);   // not the bytes it listed
    assert.equal((await s.list("feedback/images/")).length, 0);
  });

  test("the listed pictures: PNG or JPEG, five at most, 4 MB each, a message id; real pictures only", async () => {
    const cases = [
      [good({ images: [listed(PNG)] }), /id/],
      [good({ client: CLIENT, images: Array(6).fill(listed(PNG)) }), /At most 5/],
      [good({ client: CLIENT, images: [{ ...listed(PNG), type: "image/heic" }] }), /PNG or JPEG/],
      [good({ client: CLIENT, images: [{ ...listed(PNG), size: lib.MAX_IMAGE + 1 }] }), /4 MB/],
      [good({ client: CLIENT, images: [{ ...listed(PNG), size: 0 }] }), /size/],
      [good({ client: CLIENT, images: [{ ...listed(PNG), sha256: "nothex" }] }), /checksum/],
      [good({ client: CLIENT, images: [{ ...listed(PNG), name: "x.png" }] }), /doesn't send/],
      [good({ client: CLIENT, images: "x" }), /format/],
      [good({ client: CLIENT, images: [listed(PNG)], screenshot: { type: "image/png", base64: PNG.toString("base64") } }), /format/],
    ];
    for (const [body, why] of cases) {
      const r = await send(body);
      assert.equal(r.status, 422, JSON.stringify(body).slice(0, 120));
      assert.match((await r.json()).message, why);
    }
    // Bytes that say JPEG but aren't a well-formed one.
    const broken = Buffer.from([0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff, 1, 2]);
    const { id } = await (await send(good({ client: CLIENT, images: [listed(broken, "image/jpeg")] }))).json();
    const r = await put(id, 0, broken, { type: "image/jpeg" });
    assert.equal(r.status, 422);
    assert.match((await r.json()).message, /well-formed/);
    // Over the cap, refused while reading.
    const { id: big } = await (await send(good({ client: "1d7c1b9e-5a4f-4c2e-8b3d-7e6f5a4b3c21", images: [{ type: "image/png", size: lib.MAX_IMAGE, sha256: "0".repeat(64) }] }))).json();
    const huge = Buffer.concat([PNG.subarray(0, 8), Buffer.alloc(lib.MAX_IMAGE + 10)]);
    assert.equal((await put(big, 0, huge, { token: "1d7c1b9e-5a4f-4c2e-8b3d-7e6f5a4b3c21" })).status, 413);
  });

  test("the owner's mail counts the pictures", async () => {
    let sent;
    await lib.notify({ id: "AAAAAAAAAAAA", message: "hi", email: null, app: null, images: [{ key: "k", type: "image/png" }, { key: "j", type: "image/jpeg" }] },
      { key: "k", fetch: async (_u, o) => { sent = JSON.parse(o.body); return new Response("{}"); } });
    assert.match(sent.text, /Pictures: 2, on the admin page/);
  });

  test("the sweep drops a message whose pictures never all arrived, a day later; never a published one", async () => {
    const { id } = await (await send(good({ client: CLIENT, images: [listed(PNG), listed(TEXT_PNG)] }))).json();
    await put(id, 0, PNG);
    const { id: kept } = await (await send(good({ message: "no pictures" }))).json();
    assert.equal((await (await sweeper.GET(req("/api/sweep"))).json()).feedbackUnfinished, 0);
    const realNow = Date.now;
    Date.now = () => realNow() + 25 * 3_600_000;
    try {
      assert.equal((await (await sweeper.GET(req("/api/sweep"))).json()).feedbackUnfinished, 1);
    } finally {
      Date.now = realNow;
    }
    assert.equal(await s.get(lib.entryKey(id)), null);
    assert.equal((await s.list("feedback/images/")).length, 0);
    assert.equal((await s.list("feedback/clients/")).length, 0);
    assert.notEqual(await s.get(lib.entryKey(kept)), null);
  });

  test("stripMetadata keeps a picture without metadata as it is", () => {
    assert.deepEqual(lib.stripMetadata(PNG, "image/png"), PNG);
    assert.throws(() => lib.stripMetadata(PNG.subarray(0, 20), "image/png"), /well-formed/);
    assert.throws(() => lib.stripMetadata(PNG, "image/jpeg"), /well-formed/);
  });
});
