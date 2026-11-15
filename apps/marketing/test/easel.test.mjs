// Easel links (P19c: api/easel.js, api/e.js, easel-core.js) against the in-memory store:
//   cd apps/marketing && node --test test/
// The same requests run against a Preview deployment with scripts/sharing-smoke.mjs.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { beforeEach, describe, test } from "node:test";

process.env.SHARING_MEMORY_STORE = "1";
delete process.env.SHARING_READ_WRITE_TOKEN;
delete process.env.VERCEL_ENV;
delete process.env.CRON_SECRET;

const easel = await import("../api/easel.js");
const viewer = await import("../api/e.js");
const share = await import("../api/share.js");
const sweeper = await import("../api/sweep.js");
const { resetMemoryStore } = await import("../api/_lib/store.js");
const { LIMITS } = await import("../api/_lib/rate.js");
const { decodeEasel, EaselRefused, MAX_BLOCKS } = await import("../src/lib/easel-core.js");

const BASE = "https://test.example";
let ip = 0;
function req(path, { method = "GET", body, headers = {}, from } = {}) {
  return new Request(BASE + path, {
    method,
    body: body === undefined ? undefined : typeof body === "string" || body instanceof Uint8Array ? body : JSON.stringify(body),
    headers: { "x-real-ip": from ?? `10.1.${Math.floor(++ip / 250)}.${ip % 250}`, ...headers },
  });
}
const call = (fn, path, o) => fn(req(path, o));
const bearer = (token) => ({ authorization: `Bearer ${token}` });

// A real 1×1 PNG and a 1×1 JPEG's first bytes (enough for the type check).
const PNG = Buffer.from("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360f8cf00000301010018dd8db40000000049454e44ae426082", "hex");
const JPEG = Buffer.from("ffd8ffe000104a46494600010100000100010000ffd9", "hex");
const nameOf = (bytes, ext) => `${createHash("sha256").update(bytes).digest("hex")}.${ext}`;
const PNG_NAME = nameOf(PNG, "png");
const JPEG_NAME = nameOf(JPEG, "jpg");

const board = (over = {}) => ({
  kind: "easel",
  version: 1,
  title: "Trip board",
  background: "#FEFDFE",
  blocks: [
    { frame: { x: 0, y: 0, width: 280, height: 60 }, content: { type: "text", font: "clean", size: 17, color: "#141414", alignment: "left",
      paragraphs: [{ kind: "heading1", runs: [{ text: "Lisbon", bold: true }] }, { kind: "bullet", runs: [{ text: "Pastéis", link: "https://example.com/p" }] },
        { kind: "checkbox", checked: true, runs: [{ text: "Book" }] }] } },
    { frame: { x: 300, y: 0, width: 200, height: 120 }, rotation: 0.1, content: { type: "image", asset: PNG_NAME, alt: "A tram" } },
    { frame: { x: 0, y: 140, width: 160, height: 90 }, content: { type: "shape", kind: "ellipse", fill: "#D0D87F", strokeWidth: 2.5, cornerRadius: 0 } },
    { frame: { x: 10, y: 250, width: 100, height: 40 }, content: { type: "line", from: { x: 10, y: 250 }, to: { x: 110, y: 290 }, startHead: false, endHead: true, color: "#55A2BD", width: 3 } },
    { frame: { x: 200, y: 160, width: 320, height: 96 }, content: { type: "link", url: "https://www.visitlisboa.com/", title: "Visit Lisboa", detail: "The city's guide" } },
    { frame: { x: 540, y: 0, width: 300, height: 200 }, content: { type: "capture", asset: JPEG_NAME, url: "https://example.com/map", title: "Map" } },
  ],
  assets: [{ name: PNG_NAME, size: PNG.length }, { name: JPEG_NAME, size: JPEG.length }],
  ...over,
});

beforeEach(() => resetMemoryStore());

async function create(body = board()) {
  const r = await call(easel.POST, "/api/easel", { method: "POST", body });
  assert.equal(r.status, 201, await r.clone().text());
  return r.json();
}
const put = (id, name, bytes, token) => call(easel.PUT, `/api/easel?id=${id}&asset=${name}`, { method: "PUT", body: new Uint8Array(bytes), headers: bearer(token) });
const publish = (id, token) => call(easel.POST, `/api/easel?id=${id}&publish=1`, { method: "POST", headers: bearer(token) });

describe("easel links", () => {
  test("create, upload pictures, publish, view, revoke; nothing shows before publishing or after revoking", async () => {
    const { id, url, token, missing } = await create();
    assert.match(id, /^[A-Za-z0-9]{12}$/);
    assert.equal(url, `${BASE}/e/${id}`);
    assert.ok(token.length >= 40);
    assert.deepEqual(missing.sort(), [PNG_NAME, JPEG_NAME].sort());

    // Unpublished: no page, no API answer, no pictures.
    assert.equal((await call(easel.GET, `/api/easel?id=${id}`)).status, 404);
    assert.equal((await call(viewer.GET, `/api/e?id=${id}`)).status, 404);

    // Pictures need the token, the exact bytes and the right type.
    assert.equal((await put(id, PNG_NAME, PNG, "A".repeat(43))).status, 403);
    assert.equal((await put(id, PNG_NAME, PNG.subarray(0, 20), token)).status, 422);
    assert.equal((await put(id, nameOf(Buffer.from("other"), "png"), Buffer.from("other"), token)).status, 422, "not on the Easel");
    assert.equal((await put(id, PNG_NAME, PNG, token)).status, 204);
    assert.equal((await put(id, PNG_NAME, PNG, token)).status, 204, "a retry is fine");

    const early = await publish(id, token);
    assert.equal(early.status, 409);
    assert.deepEqual((await early.json()).missing, [JPEG_NAME]);
    assert.equal((await put(id, JPEG_NAME, JPEG, token)).status, 204);
    assert.equal((await publish(id, "B".repeat(43))).status, 403);
    const done = await publish(id, token);
    assert.equal(done.status, 200);
    assert.equal((await done.json()).url, `${BASE}/e/${id}`);
    assert.equal((await put(id, PNG_NAME, PNG, token)).status, 409, "published links don't change");

    const got = await call(easel.GET, `/api/easel?id=${id}`);
    assert.equal(got.status, 200);
    assert.deepEqual((await got.json()).easel, board());

    const page = await call(viewer.GET, `/api/e?id=${id}`);
    assert.equal(page.status, 200);
    const html = await page.text();
    assert.match(html, /Shared Easel/);
    assert.match(html, /Trip board/);
    assert.match(html, /<h1><strong>Lisbon<\/strong><\/h1>/);
    assert.match(html, /href="https:\/\/example\.com\/p" target="_blank" rel="noopener noreferrer nofollow"/);
    assert.match(html, /☑/);
    assert.match(html, new RegExp(`src="/e/${id}/a/${PNG_NAME}"`));
    assert.match(html, /Visit Lisboa/);
    assert.match(html, /visitlisboa\.com/);
    assert.match(html, /<svg viewBox=/);
    assert.match(html, /transform:rotate\(0\.1rad\)/);
    assert.ok(!/<script/i.test(html), "no scripts at all");
    assert.match(html, new RegExp(`<a class="btn-open" href="airc://easel/${id}">Add to Airc</a>`), "P19d: Add to Airc");
    const csp = page.headers.get("content-security-policy") ?? "";
    assert.match(csp, /default-src 'none'/);
    assert.match(csp, /img-src 'self'(;|$)/);

    const pic = await call(viewer.GET, `/api/e?id=${id}&asset=${PNG_NAME}`);
    assert.equal(pic.status, 200);
    assert.equal(pic.headers.get("content-type"), "image/png");
    assert.equal(pic.headers.get("x-content-type-options"), "nosniff");
    assert.deepEqual(Buffer.from(await pic.arrayBuffer()), PNG);
    assert.equal((await call(viewer.GET, `/api/e?id=${id}&asset=${"0".repeat(64)}.png`)).status, 404);

    assert.equal((await call(easel.DELETE, `/api/easel?id=${id}`, { method: "DELETE", headers: bearer("C".repeat(43)) })).status, 403);
    assert.equal((await call(easel.DELETE, `/api/easel?id=${id}`, { method: "DELETE", headers: bearer(token) })).status, 204);
    assert.equal((await call(easel.GET, `/api/easel?id=${id}`)).status, 404);
    assert.equal((await call(viewer.GET, `/api/e?id=${id}`)).status, 404);
    assert.match(await (await call(viewer.GET, `/api/e?id=${id}`)).text(), /taken back/);
    assert.equal((await call(viewer.GET, `/api/e?id=${id}&asset=${PNG_NAME}`)).status, 404);
    assert.equal((await call(easel.DELETE, `/api/easel?id=${id}`, { method: "DELETE", headers: bearer(token) })).status, 404);
  });

  test("an Easel without pictures is published at once", async () => {
    const b = board({ blocks: board().blocks.filter((x) => !["image", "capture"].includes(x.content.type)), assets: [] });
    const { id, missing } = await create(b);
    assert.deepEqual(missing, []);
    assert.equal((await call(viewer.GET, `/api/e?id=${id}`)).status, 200);
  });

  test("an Easel link isn't a Space link, and the other way round", async () => {
    const { id } = await create(board({ blocks: [board().blocks[0]], assets: [] }));
    assert.equal((await call(share.GET, `/api/share?id=${id}`)).status, 404);
    assert.equal((await call(share.POST, "/api/share", { method: "POST", body: board() })).status, 422);
  });

  test("unknown and malformed ids are 404s", async () => {
    for (const id of ["", "short", "../../etc/pa", "AAAAAAAAAAAA"]) {
      assert.equal((await call(easel.GET, `/api/easel?id=${encodeURIComponent(id)}`)).status, 404, id);
      assert.equal((await call(viewer.GET, `/api/e?id=${encodeURIComponent(id)}`)).status, 404, id);
    }
    assert.equal((await call(viewer.GET, `/api/e?id=AAAAAAAAAAAA&asset=..%2F..%2Fx.png`)).status, 404);
  });

  test("addresses that aren't web addresses are refused whole", async () => {
    const text = (link) => ({ frame: { x: 0, y: 0, width: 10, height: 10 }, content: { type: "text", font: "clean", size: 17, color: "#141414", alignment: "left", paragraphs: [{ kind: "paragraph", runs: [{ text: "x", link }] }] } });
    for (const bad of ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts", "https://user:pw@example.com/", "airc://share/x", "https://exa mple.com"]) {
      for (const block of [
        { frame: { x: 0, y: 0, width: 10, height: 10 }, content: { type: "link", url: bad } },
        { frame: { x: 0, y: 0, width: 10, height: 10 }, content: { type: "capture", asset: PNG_NAME, url: bad } },
        text(bad),
      ]) {
        const assets = block.content.type === "capture" ? [{ name: PNG_NAME, size: PNG.length }] : [];
        const r = await call(easel.POST, "/api/easel", { method: "POST", body: board({ blocks: [block], assets }) });
        assert.equal(r.status, 422, `${bad} in ${block.content.type}`);
        assert.equal((await r.json()).error, "unsafeAddress");
      }
    }
  });

  test("tampered, oversized and inconsistent Easels are refused", async () => {
    const cases = {
      "extra top key": board({ owner: "me" }),
      "extra block key": board({ blocks: [{ ...board().blocks[0], id: "x" }], assets: [] }),
      "unknown kind": board({ blocks: [{ frame: { x: 0, y: 0, width: 1, height: 1 }, content: { type: "video", url: "https://x.example/" } }], assets: [] }),
      "a live source": board({ blocks: [{ frame: { x: 0, y: 0, width: 1, height: 1 }, content: { type: "capture", asset: PNG_NAME, live: { profileID: "p" } } }], assets: [{ name: PNG_NAME, size: PNG.length }] }),
      "picture not listed": board({ assets: [{ name: PNG_NAME, size: PNG.length }] }),
      "listed but unused": board({ assets: [...board().assets, { name: nameOf(Buffer.from("x"), "gif"), size: 1 }] }),
      "a heic picture": board({ blocks: [{ frame: { x: 0, y: 0, width: 1, height: 1 }, content: { type: "image", asset: `${"a".repeat(64)}.heic` } }], assets: [{ name: `${"a".repeat(64)}.heic`, size: 10 }] }),
      "bad colour": board({ blocks: [{ frame: { x: 0, y: 0, width: 1, height: 1 }, content: { type: "shape", kind: "rectangle", fill: "red;background:url(x)", strokeWidth: 1, cornerRadius: 0 } }], assets: [] }),
      "infinite frame": '{"kind":"easel","version":1,"title":"","background":"#FFFFFF","blocks":[{"frame":{"x":1e999,"y":0,"width":1,"height":1},"content":{"type":"shape","kind":"rectangle","strokeWidth":1,"cornerRadius":0}}],"assets":[]}',
      "control characters": board({ title: "a\u0000b" }),
      "direction override": board({ title: "abc‮gpj.exe" }),
      "no blocks": board({ blocks: [], assets: [] }),
      "null": board({ title: null }),
      "not JSON": "{",
    };
    for (const [why, body] of Object.entries(cases)) {
      const r = await call(easel.POST, "/api/easel", { method: "POST", body });
      assert.equal(r.status, 422, why);
    }
    const newer = await call(easel.POST, "/api/easel", { method: "POST", body: board({ version: 2 }) });
    assert.equal(newer.status, 422);
    assert.equal((await newer.json()).error, "newerVersion");
    const many = board({ blocks: Array.from({ length: MAX_BLOCKS + 1 }, () => board().blocks[2]), assets: [] });
    assert.equal((await call(easel.POST, "/api/easel", { method: "POST", body: many })).status, 413);
    const heavy = board({ assets: [{ name: PNG_NAME, size: 4_000_000 }, { name: JPEG_NAME, size: 4_000_000 }], blocks: [...board().blocks, ...Array.from({ length: 4 }, (_, i) => ({ frame: { x: 0, y: 0, width: 1, height: 1 }, content: { type: "image", asset: nameOf(Buffer.from(String(i)), "png") } }))] });
    heavy.assets.push(...Array.from({ length: 4 }, (_, i) => ({ name: nameOf(Buffer.from(String(i)), "png"), size: 4_000_000 })));
    assert.equal((await call(easel.POST, "/api/easel", { method: "POST", body: heavy })).status, 413, "over 20 MB of pictures");
    const huge = "x".repeat(1_100_000);
    assert.equal((await call(easel.POST, "/api/easel", { method: "POST", body: huge })).status, 413);
  });

  test("a picture must be the type its name says", async () => {
    const fake = Buffer.concat([JPEG, Buffer.from("pad")]);
    const name = nameOf(fake, "png");
    const { id, token } = await create(board({ blocks: [{ frame: { x: 0, y: 0, width: 1, height: 1 }, content: { type: "image", asset: name } }], assets: [{ name, size: fake.length }] }));
    assert.equal((await put(id, name, fake, token)).status, 422);
  });

  test("everything from an Easel is text on the page", async () => {
    const evil = '<img src=x onerror=alert(1)>"\'';
    const b = board({
      title: `<script>alert(1)</script>`,
      blocks: [
        { frame: { x: 0, y: 0, width: 100, height: 40 }, content: { type: "text", font: "mono", size: 12, color: "#000000", alignment: "center", paragraphs: [{ kind: "paragraph", runs: [{ text: evil }] }] } },
        { frame: { x: 0, y: 50, width: 320, height: 96 }, content: { type: "link", url: 'https://example.com/"><script>x</script>', title: evil, detail: evil } },
      ],
      assets: [],
    });
    const { id } = await create(b);
    const html = await (await call(viewer.GET, `/api/e?id=${id}`)).text();
    assert.ok(!html.includes("<script"), "no script element");
    assert.ok(!html.includes("<img src=x"), "no injected element");
    assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;&quot;&#39;/);
    assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  });

  test("rate limit: Easel links count with Space and folder links, 30 an hour from one address", async () => {
    const small = board({ blocks: [board().blocks[2]], assets: [] });
    const from = "10.9.9.9";
    for (let i = 0; i < LIMITS.share; i++) assert.equal((await call(easel.POST, "/api/easel", { method: "POST", body: small, from })).status, 201);
    const r = await call(easel.POST, "/api/easel", { method: "POST", body: small, from });
    assert.equal(r.status, 429);
    assert.ok(Number(r.headers.get("retry-after")) > 0);
    assert.equal((await call(easel.POST, "/api/easel", { method: "POST", body: small })).status, 201, "others aren't limited");
  });

  test("the sweep drops a day-old link whose pictures never arrived, and keeps published ones", async () => {
    const s = resetMemoryStore();
    const unfinished = await create();
    await put(unfinished.id, PNG_NAME, PNG, unfinished.token);
    const finished = await create(board({ blocks: [board().blocks[2]], assets: [] }));
    const recent = await create();
    // Age the first two records (the memory store's upload time).
    const old = new Date(Date.now() - 25 * 3_600_000);
    const list = s.list;
    s.list = async (prefix) => (await list(prefix)).map((b) => (b.key.includes(unfinished.id) || b.key.includes(finished.id) ? { ...b, uploadedAt: old } : b));
    const r = await call(sweeper.GET, "/api/sweep");
    assert.equal((await r.json()).easels, 1);
    s.list = list;
    assert.deepEqual((await s.list(`easels/${unfinished.id}`)).map((b) => b.key), []);
    assert.equal((await call(viewer.GET, `/api/e?id=${finished.id}`)).status, 200);
    assert.ok(await s.get(`easels/${recent.id}.json`), "a recent unfinished link stays");
  });
});

describe("easel-core", () => {
  test("decodes what it encodes, exactly", () => {
    assert.deepEqual(decodeEasel(JSON.stringify(board())), board());
  });
  test("refusals carry a reason", () => {
    assert.throws(() => decodeEasel("[]"), (e) => e instanceof EaselRefused && e.why === "damaged");
  });
});
