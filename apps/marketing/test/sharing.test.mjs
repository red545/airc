// The sharing functions (api/share.js, s.js, boosts.js, admin.js, sweep.js) against the in-memory store:
//   cd apps/marketing && node --test test/
// The same requests run against a Preview deployment with scripts/sharing-smoke.mjs.
import assert from "node:assert/strict";
import { beforeEach, describe, test } from "node:test";
import { inflateRawSync } from "node:zlib";

process.env.SHARING_MEMORY_STORE = "1";
process.env.SHARING_ADMIN_SECRET = "test-admin-secret-0123456789abcdef";
delete process.env.SHARING_READ_WRITE_TOKEN;
delete process.env.VERCEL_ENV;
delete process.env.CRON_SECRET;

const share = await import("../api/share.js");
const viewer = await import("../api/s.js");
const boosts = await import("../api/boosts.js");
const admin = await import("../api/admin.js");
const sweeper = await import("../api/sweep.js");
const { resetMemoryStore } = await import("../api/_lib/store.js");
const { LIMITS, windowOf } = await import("../api/_lib/rate.js");

const BASE = "https://test.example";
let ip = 0;
/** A request from its own visitor address (so rate limits don't carry between tests) unless `from` is given. */
function req(path, { method = "GET", body, headers = {}, from } = {}) {
  return new Request(BASE + path, {
    method,
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    headers: { "x-real-ip": from ?? `10.0.${Math.floor(++ip / 250)}.${ip % 250}`, ...headers },
  });
}
const call = (fn, path, o) => fn(req(path, o));

const space = {
  kind: "space",
  name: "Trip to Lisbon",
  icon: "🧳",
  items: [
    { type: "tab", url: "https://www.visitlisboa.com/", title: "Visit Lisboa" },
    { type: "folder", name: "Food", items: [{ type: "tab", url: "https://example.com/pasteis" }] },
    { type: "split", axis: "horizontal", items: [{ type: "tab", url: "https://maps.example.com/", title: "Map" }, { type: "tab", url: "https://example.com/plan" }] },
  ],
};

const UUID = "5b0e5c56-8a43-4c4f-9b1f-0d6f0a6c1e11";
const boostFile = (over = {}) => ({
  version: 2,
  name: "Calm Example",
  site: "example.com",
  createdAt: "2026-11-09T20:00:00Z",
  colors: { hue: 0.1, tint: 0.2, brightness: 1, contrast: 1, invert: false, saturation: 1 },
  font: { size: 1, family: "charter" },
  zaps: [{ selector: ".ad-banner", label: "Ad" }],
  css: "main { line-height: 1.6 !important; }\n.logo { background: url(/img/logo.png); }",
  js: "",
  id: UUID,
  revision: 1,
  author: "Tester",
  about: "Makes it calm.",
  ...over,
});
const PNG = Buffer.from("89504e470d0a1a0a0000000d4948445200000001000000010806000000", "hex").toString("base64");

const auth = (password = process.env.SHARING_ADMIN_SECRET) => ({ authorization: `Basic ${Buffer.from(`owner:${password}`).toString("base64")}` });
const adminPost = (action, id, headers = { origin: BASE, host: "test.example" }) =>
  call(admin.POST, "/api/admin", { method: "POST", body: `action=${action}&id=${id}`, headers: { ...auth(), "content-type": "application/x-www-form-urlencoded", ...headers } });

beforeEach(() => resetMemoryStore());

describe("share links", () => {
  test("create, read, view, revoke; a revoked link 404s", async () => {
    const created = await call(share.POST, "/api/share", { method: "POST", body: space });
    assert.equal(created.status, 201);
    const { id, url, token } = await created.json();
    assert.match(id, /^[A-Za-z0-9]{12}$/);
    assert.equal(url, `${BASE}/s/${id}`);
    assert.ok(token.length >= 40);

    const got = await call(share.GET, `/api/share?id=${id}`);
    assert.equal(got.status, 200);
    const body = await got.json();
    assert.deepEqual(body.snapshot, space, "order, nesting, splits and titles round-trip exactly, with no extra keys");

    const html = await call(viewer.GET, `/api/s?id=${id}`);
    assert.equal(html.status, 200);
    const text = await html.text();
    assert.match(text, /Trip to Lisbon/);
    assert.match(text, new RegExp(`href="airc://share/${id}"`));
    assert.match(text, /4 tabs in 1 folder/);
    assert.match(html.headers.get("content-security-policy"), /default-src 'none'/);

    const wrong = await call(share.DELETE, `/api/share?id=${id}`, { method: "DELETE", headers: { authorization: `Bearer ${"x".repeat(43)}` } });
    assert.equal(wrong.status, 403);
    const none = await call(share.DELETE, `/api/share?id=${id}`, { method: "DELETE" });
    assert.equal(none.status, 403);
    const ok = await call(share.DELETE, `/api/share?id=${id}`, { method: "DELETE", headers: { authorization: `Bearer ${token}` } });
    assert.equal(ok.status, 204);
    assert.equal((await call(share.GET, `/api/share?id=${id}`)).status, 404);
    assert.equal((await call(viewer.GET, `/api/s?id=${id}`)).status, 404);
    const again = await call(share.DELETE, `/api/share?id=${id}`, { method: "DELETE", headers: { authorization: `Bearer ${token}` } });
    assert.equal(again.status, 404);
  });

  test("unknown and malformed ids are 404s", async () => {
    for (const id of ["AAAAAAAAAAAA", "../index", "", "a".repeat(13)]) {
      assert.equal((await call(share.GET, `/api/share?id=${encodeURIComponent(id)}`)).status, 404);
      assert.equal((await call(viewer.GET, `/api/s?id=${encodeURIComponent(id)}`)).status, 404);
    }
  });

  test("unsafe addresses are refused whole", async () => {
    for (const url of ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "https://user:pw@example.com/", "blob:https://x/1", "airc://share/x"]) {
      const r = await call(share.POST, "/api/share", { method: "POST", body: { kind: "folder", name: "F", items: [{ type: "tab", url }] } });
      assert.equal(r.status, 422, url);
      assert.equal((await r.json()).error, "unsafeAddress", url);
    }
  });

  test("tampered, oversized and wrong-kind payloads are refused", async () => {
    const cases = [
      [{ ...space, extra: 1 }, 422, "damaged"],
      [{ ...space, items: [] }, 422, "damaged"],
      [{ kind: "space", name: "S", items: [{ type: "tab", url: "https://a.example/", title: null }] }, 422, "damaged"],
      [{ kind: "space", name: "S", items: [{ type: "split", items: [{ type: "tab", url: "https://a.example/" }] }] }, 422, "damaged"],
      [{ kind: "boost", boost: boostFile() }, 422, "damaged"],
      ["{not json", 422, "damaged"],
    ];
    for (const [body, status, error] of cases) {
      const r = await call(share.POST, "/api/share", { method: "POST", body });
      assert.equal(r.status, status, JSON.stringify(body).slice(0, 60));
      assert.equal((await r.json()).error, error);
    }
    const big = { kind: "folder", name: "Big", items: Array.from({ length: 2001 }, (_, i) => ({ type: "tab", url: `https://example.com/${i}` })) };
    assert.equal((await call(share.POST, "/api/share", { method: "POST", body: big })).status, 413, "over 2,000 tabs");
    const huge = "x".repeat(524_289);
    assert.equal((await call(share.POST, "/api/share", { method: "POST", body: huge })).status, 413, "over 512 KB");
    let deep = { type: "tab", url: "https://example.com/" };
    for (let i = 0; i < 12; i++) deep = { type: "folder", name: `L${i}`, items: [deep] };
    assert.equal((await call(share.POST, "/api/share", { method: "POST", body: { kind: "folder", name: "Deep", items: [deep] } })).status, 413);
  });

  test("everything from a snapshot is text on the page", async () => {
    const evil = { kind: "folder", name: '<img src=x onerror=alert(1)>', items: [{ type: "tab", url: 'https://example.com/"><script>alert(1)</script>', title: "</a><script>x()</script>" }] };
    const { id } = await (await call(share.POST, "/api/share", { method: "POST", body: evil })).json();
    const text = await (await call(viewer.GET, `/api/s?id=${id}`)).text();
    assert.ok(!text.includes("<img src=x"), "name escaped");
    assert.ok(!text.includes("<script>alert"), "url escaped");
    assert.ok(!text.includes("<script>x()"), "title escaped");
    assert.match(text, /&lt;img src=x onerror=alert\(1\)&gt;/);
  });

  test("rate limit: 30 new links an hour from one address", async () => {
    for (let i = 0; i < LIMITS.share; i++) {
      assert.equal((await call(share.POST, "/api/share", { method: "POST", body: space, from: "203.0.113.9" })).status, 201);
    }
    const r = await call(share.POST, "/api/share", { method: "POST", body: space, from: "203.0.113.9" });
    assert.equal(r.status, 429);
    assert.ok(Number(r.headers.get("retry-after")) > 0);
    assert.equal((await call(share.POST, "/api/share", { method: "POST", body: space, from: "203.0.113.10" })).status, 201, "another address");
  });
});

describe("boost gallery", () => {
  test("submit, review queue, approve, list, install link, file, preview", async () => {
    const sent = await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile({ preview: PNG }) });
    assert.equal(sent.status, 202);
    const { id, status } = await sent.json();
    assert.equal(status, "pending");
    assert.deepEqual((await (await call(boosts.GET, "/api/boosts")).json()).boosts, [], "nothing listed before approval");
    assert.equal((await call(boosts.GET, `/api/boosts?id=${id}`)).status, 404, "not installable before approval");

    const queue = await call(admin.GET, "/admin/boosts", { headers: auth() });
    assert.equal(queue.status, 200);
    const q = await queue.text();
    assert.match(q, /Calm Example/);
    assert.match(q, /line-height: 1.6/);
    assert.match(q, /data:image\/png;base64,/);

    assert.equal((await adminPost("approve", id)).status, 303);
    const list = (await (await call(boosts.GET, "/api/boosts")).json()).boosts;
    assert.equal(list.length, 1);
    const e = list[0];
    assert.deepEqual({ ...e, approvedAt: undefined, link: undefined }, {
      id, fileID: UUID, name: "Calm Example", site: "example.com", author: "Tester", about: "Makes it calm.",
      code: false, preview: true, approvedAt: undefined, link: undefined, revision: 1,
    });
    assert.match(e.link, /^https:\/\/aircbrowser\.com\/boost#1\.[A-Za-z0-9_-]+$/);
    const fromLink = JSON.parse(inflateRawSync(Buffer.from(e.link.split("#1.")[1], "base64url")).toString());
    const { preview: _p, ...expected } = boostFile();
    assert.deepEqual(fromLink, expected, "the link carries the file without its preview");
    assert.deepEqual(await (await call(boosts.GET, `/api/boosts?id=${id}`)).json(), expected);
    const img = await call(boosts.GET, `/api/boosts?preview=${id}`);
    assert.equal(img.headers.get("content-type"), "image/png");
    assert.equal(Buffer.from(await img.arrayBuffer()).toString("base64"), PNG);
  });

  test("a new revision of the same Boost replaces the listed one", async () => {
    const a = (await (await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile() })).json()).id;
    await adminPost("approve", a);
    const b = (await (await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile({ revision: 2, name: "Calmer Example" }) })).json()).id;
    await adminPost("approve", b);
    const list = (await (await call(boosts.GET, "/api/boosts")).json()).boosts;
    assert.deepEqual(list.map((x) => x.name), ["Calmer Example"]);
    assert.deepEqual(list.map((x) => x.revision), [2], "the entry says its revision (Airc offers Update for it)");
    assert.equal((await call(boosts.GET, `/api/boosts?id=${a}`)).status, 404);
  });

  test("the static review refuses what the gallery doesn't take", async () => {
    const refused = [
      ["@import of another site", { css: '@import "https://evil.example/x.css";' }],
      ["url() on another site", { css: "body { background: url(https://tracker.example/p.gif); }" }],
      ["protocol-relative url", { css: "body { background: url(//cdn.example/p.gif); }" }],
      ["image-set on another site", { css: 'body { background-image: image-set("https://cdn.example/a.png" 1x); }' }],
      ["css escape", { css: "body { background: \\75rl(https://evil.example/); }" }],
      ["css expression", { css: "body { width: expression(alert(1)); }" }],
      ["js fetch", { js: "fetch('/api')" }],
      ["js script element", { js: "const s = document.createElement('script');" }],
      ["js dynamic import", { js: "import('/x.js')" }],
      ["js eval", { js: "eval(atob('YQ=='))" }],
      ["js address", { js: "const u = 'https://evil.example/c';" }],
      ["js escape", { js: "window['\\u0066etch']('/x')" }],
      ["js comment trick", { js: 'const a = "/*"; fetch("/x"); const b = "*/";' }],
      ["js minified", { js: "a();".repeat(120) }],
      ["js src", { js: "document.querySelector('img').src = location.hash;" }],
      ["css too large", { css: `/* ${"x".repeat(128 * 1024)} */` }],
      ["hidden bidi text", { js: "const ok = 1; // \u202e evil" }],
      ["version 1", { version: 1 }],
      ["unknown key", { extra: true }],
      ["bad site", { site: "Example.COM" }],
      ["ip site", { site: "127.0.0.1" }],
      ["bad range", { colors: { hue: 2, tint: 0, brightness: 1, contrast: 1, invert: false } }],
      ["unknown font", { font: { size: 0, family: "comic" } }],
      ["id without revision", { revision: undefined }],
      ["preview not an image", { preview: Buffer.from("<svg onload=alert(1)>").toString("base64") }],
      ["bad zap", { zaps: [{ selector: "a { }", label: "x" }] }],
    ];
    for (const [what, over] of refused) {
      const body = JSON.parse(JSON.stringify(boostFile(over)));
      const r = await call(boosts.POST, "/api/boosts", { method: "POST", body });
      assert.equal(r.status, 422, what);
      assert.equal((await r.json()).error, "rejected", what);
    }
    const allowed = [
      ["code that changes the page", { js: "document.querySelectorAll('.ad').forEach((e) => e.remove());" }],
      ["data: css import", { css: '@import "data:text/css,body{color:red}";' }],
      ["same-site image", { css: "body { background: url(https://static.example.com/bg.png); }" }],
      ["scroll-behavior", { css: "html { scroll-behavior: smooth; }" }],
      ["mailto selector", { css: 'a[href^="mailto:"] { color: red; }' }],
    ];
    for (const [what, over] of allowed) {
      const r = await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile(over) });
      assert.equal(r.status, 202, what);
    }
  });

  test("reports reach the admin page; remove takes the Boost and its reports away", async () => {
    const id = (await (await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile() })).json()).id;
    assert.equal((await call(boosts.POST, `/api/boosts?report=${id}`, { method: "POST", body: { reason: "spam" } })).status, 404, "not listed yet");
    await adminPost("approve", id);
    assert.equal((await call(boosts.POST, `/api/boosts?report=${id}`, { method: "POST", body: { reason: "nope" } })).status, 422);
    assert.equal((await call(boosts.POST, `/api/boosts?report=${id}`, { method: "POST", body: { reason: "harmful", note: "it <b>hides</b> prices" } })).status, 202);
    const page = await (await call(admin.GET, "/admin/boosts", { headers: auth() })).text();
    assert.match(page, /It&#39;s harmful or deceptive/);
    assert.match(page, /it &lt;b&gt;hides&lt;\/b&gt; prices/);
    assert.equal((await adminPost("remove", id)).status, 303);
    assert.deepEqual((await (await call(boosts.GET, "/api/boosts")).json()).boosts, []);
    assert.equal((await call(boosts.GET, `/api/boosts?id=${id}`)).status, 404);
    assert.doesNotMatch(await (await call(admin.GET, "/admin/boosts", { headers: auth() })).text(), /harmful or deceptive/);
  });

  test("reject deletes the submission", async () => {
    const id = (await (await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile() })).json()).id;
    await adminPost("reject", id);
    assert.doesNotMatch(await (await call(admin.GET, "/admin/boosts", { headers: auth() })).text(), /Calm Example/);
    await adminPost("approve", id);
    assert.deepEqual((await (await call(boosts.GET, "/api/boosts")).json()).boosts, [], "a rejected submission can't be approved later");
  });

  test("rate limit: 10 submissions an hour from one address", async () => {
    for (let i = 0; i < LIMITS.submit; i++) {
      assert.equal((await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile(), from: "198.51.100.7" })).status, 202);
    }
    assert.equal((await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile(), from: "198.51.100.7" })).status, 429);
  });
});

describe("admin page", () => {
  test("closed without its secret; asks for the password; counts failures", async () => {
    const saved = process.env.SHARING_ADMIN_SECRET;
    delete process.env.SHARING_ADMIN_SECRET;
    assert.equal((await call(admin.GET, "/admin/boosts", { headers: auth("anything") })).status, 503);
    process.env.SHARING_ADMIN_SECRET = saved;

    const plain = await call(admin.GET, "/admin/boosts");
    assert.equal(plain.status, 401);
    assert.match(plain.headers.get("www-authenticate"), /^Basic /);
    for (let i = 0; i < LIMITS.admin; i++) {
      assert.equal((await call(admin.GET, "/admin/boosts", { headers: auth("wrong"), from: "192.0.2.1" })).status, 401);
    }
    assert.equal((await call(admin.GET, "/admin/boosts", { headers: auth("wrong"), from: "192.0.2.1" })).status, 429);
  });

  test("actions need the page's own origin", async () => {
    const id = (await (await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile() })).json()).id;
    assert.equal((await adminPost("approve", id, { origin: "https://evil.example", host: "test.example" })).status, 403);
    assert.equal((await adminPost("approve", id, { origin: "null", host: "test.example" })).status, 403);
    assert.equal((await adminPost("approve", id, { host: "test.example" })).status, 403);
    assert.deepEqual((await (await call(boosts.GET, "/api/boosts")).json()).boosts, []);
  });
});

describe("lazy expiry", () => {
  test("a visitor's first request in a new hour deletes their counter of the hour before", async () => {
    const { store } = await import("../api/_lib/store.js");
    const s = await store();
    const realNow = Date.now;
    try {
      Date.now = () => realNow() - 3_600_000;
      await call(share.POST, "/api/share", { method: "POST", body: space, from: "203.0.113.50" });
      await call(share.POST, "/api/share", { method: "POST", body: space, from: "203.0.113.51" });
      assert.equal((await s.list(`rate/${windowOf()}/`)).length, 2);
    } finally {
      Date.now = realNow;
    }
    await call(share.POST, "/api/share", { method: "POST", body: space, from: "203.0.113.50" });
    const left = (await s.list("rate/")).map((b) => b.key.split("/")[1]);
    assert.deepEqual(left.sort(), [String(windowOf() - 1), String(windowOf())], "only the other visitor's old counter is left, for the daily sweep");
  });
});

describe("sweep", () => {
  test("drops past rate windows and month-old submissions, keeps the current hour", async () => {
    const { store } = await import("../api/_lib/store.js");
    const s = await store();
    await s.put(`rate/${windowOf() - 1}/share-old.json`, '{"n":3}');
    await s.put(`rate/${windowOf()}/share-now.json`, '{"n":1}');
    await call(boosts.POST, "/api/boosts", { method: "POST", body: boostFile() });
    const r = await (await call(sweeper.GET, "/api/sweep")).json();
    assert.equal(r.counters, 1);
    assert.equal(r.submissions, 0);
    assert.deepEqual((await s.list("rate/")).map((b) => b.key).filter((k) => k.includes("share-")), [`rate/${windowOf()}/share-now.json`]);
    process.env.CRON_SECRET = "cron-secret";
    assert.equal((await call(sweeper.GET, "/api/sweep")).status, 401);
    assert.equal((await call(sweeper.GET, "/api/sweep", { headers: { authorization: "Bearer cron-secret" } })).status, 200);
    delete process.env.CRON_SECRET;
  });
});

describe("store", () => {
  test("Preview records live under their own prefix, invisible to Production's keys", async () => {
    const { memoryStore, prefixed } = await import("../api/_lib/store.js");
    const shared = memoryStore();
    const preview = prefixed(shared, "preview/");
    await preview.put("boosts/index.json", '{"entries":[1]}');
    assert.equal(await shared.get("boosts/index.json"), null);
    assert.equal((await shared.get("preview/boosts/index.json")).text, '{"entries":[1]}');
    assert.deepEqual((await preview.list("boosts/")).map((b) => b.key), ["boosts/index.json"]);
    await preview.del("boosts/index.json");
    assert.deepEqual(await shared.list(""), []);
  });
});
