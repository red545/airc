// The sharing service end to end against a deployment (a Preview, or `vercel dev`), with its real store:
//   SHARING_ADMIN_PASSWORD=… [VERCEL_BYPASS=…] node scripts/sharing-smoke.mjs https://<deployment> [--easel-only]
// VERCEL_BYPASS is the project's protection-bypass secret, for Previews behind Vercel Authentication. Everything it
// creates is removed again (the link revoked, the Boost removed). Never point it at Production: it writes there.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { inflateRawSync } from "node:zlib";

const base = (process.argv[2] ?? "").replace(/\/$/, "");
if (!/^https?:\/\//.test(base) || /aircbrowser\.com/.test(base)) throw new Error("usage: sharing-smoke.mjs <preview or dev URL> (not Production)");
const bypass = process.env.VERCEL_BYPASS ? { "x-vercel-protection-bypass": process.env.VERCEL_BYPASS } : {};
const admin = { authorization: `Basic ${Buffer.from(`owner:${process.env.SHARING_ADMIN_PASSWORD ?? ""}`).toString("base64")}` };

// Every request gets its own cache key: the gallery's answers are cached at the edge for a minute.
const fresh = (path) => `${path}${path.includes("?") ? "&" : "?"}_=${Date.now()}${Math.random().toString(36).slice(2)}`;
const go = (path, { method = "GET", body, headers = {} } = {}) =>
  fetch(base + (method === "GET" && path.startsWith("/api/boosts") ? fresh(path) : path), { method, body: body === undefined ? undefined : typeof body === "string" || body instanceof Uint8Array ? body : JSON.stringify(body), headers: { ...bypass, ...headers }, redirect: "manual" });
const step = async (name, f) => {
  const t = Date.now();
  await f();
  console.log(`ok   ${name} (${Date.now() - t} ms)`);
};

const space = {
  kind: "space", name: "Smoke test", icon: "🧪",
  items: [
    { type: "tab", url: "https://example.com/", title: "Example" },
    { type: "folder", name: "Nested", items: [{ type: "tab", url: "https://example.org/a" }] },
    { type: "split", axis: "vertical", items: [{ type: "tab", url: "https://example.net/1" }, { type: "tab", url: "https://example.net/2", title: "Two" }] },
  ],
};

// P19c: an Easel link, end to end: the Easel, its picture, publish, the /e page and picture, take back → 404.
const PNG = Buffer.from("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360f8cf00000301010018dd8db40000000049454e44ae426082", "hex");
const pngName = `${createHash("sha256").update(PNG).digest("hex")}.png`;
const easel = {
  kind: "easel", version: 1, title: "Smoke board", background: "#FEFDFE",
  blocks: [
    { frame: { x: 0, y: 0, width: 280, height: 40 }, content: { type: "text", font: "clean", size: 17, color: "#141414", alignment: "left", paragraphs: [{ kind: "heading1", runs: [{ text: "Smoke" }] }] } },
    { frame: { x: 300, y: 0, width: 100, height: 100 }, content: { type: "image", asset: pngName } },
    { frame: { x: 0, y: 60, width: 320, height: 96 }, content: { type: "link", url: "https://example.com/", title: "Example" } },
  ],
  assets: [{ name: pngName, size: PNG.length }],
};
let board;
await step("POST /api/easel, PUT its picture, publish", async () => {
  const r = await go("/api/easel", { method: "POST", body: easel });
  assert.equal(r.status, 201, await r.clone().text());
  board = await r.json();
  assert.match(board.url, /\/e\/[A-Za-z0-9]{12}$/);
  assert.deepEqual(board.missing, [pngName]);
  assert.equal((await go(`/e/${board.id}`)).status, 404, "nothing shows before publishing");
  const auth = { authorization: `Bearer ${board.token}` };
  assert.equal((await go(`/api/easel?id=${board.id}&asset=${pngName}`, { method: "PUT", body: PNG, headers: { ...auth, "content-type": "image/png" } })).status, 204);
  assert.equal((await go(`/api/easel?id=${board.id}&publish=1`, { method: "POST", headers: auth })).status, 200);
});
await step("GET /e/<id> renders it; its picture and the API answer", async () => {
  const page = await go(`/e/${board.id}`);
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /Smoke board/);
  assert.match(html, new RegExp(`/e/${board.id}/a/${pngName}`));
  assert.match(page.headers.get("content-security-policy") ?? "", /default-src 'none'/);
  const pic = await go(`/e/${board.id}/a/${pngName}`);
  assert.equal(pic.status, 200);
  assert.equal(pic.headers.get("content-type"), "image/png");
  assert.deepEqual(Buffer.from(await pic.arrayBuffer()), PNG);
  assert.deepEqual((await (await go(`/api/easel?id=${board.id}`)).json()).easel, easel);
});
await step("an Easel with a javascript: link is refused", async () => {
  const bad = { ...easel, blocks: [{ frame: { x: 0, y: 0, width: 1, height: 1 }, content: { type: "link", url: "javascript:alert(1)" } }], assets: [] };
  assert.equal((await go("/api/easel", { method: "POST", body: bad })).status, 422);
});
await step("revoking the Easel link makes the page, picture and API 404", async () => {
  assert.equal((await go(`/api/easel?id=${board.id}`, { method: "DELETE", headers: { authorization: `Bearer ${"A".repeat(43)}` } })).status, 403);
  assert.equal((await go(`/api/easel?id=${board.id}`, { method: "DELETE", headers: { authorization: `Bearer ${board.token}` } })).status, 204);
  assert.equal((await go(`/e/${board.id}`)).status, 404);
  assert.equal((await go(`/e/${board.id}/a/${pngName}`)).status, 404);
  assert.equal((await go(`/api/easel?id=${board.id}`)).status, 404);
});
if (process.argv.includes("--easel-only")) {
  console.log("all passed (Easel links)");
  process.exit(0);
}

let link;
await step("POST /api/share creates a link", async () => {
  const r = await go("/api/share", { method: "POST", body: space });
  assert.equal(r.status, 201, await r.clone().text());
  link = await r.json();
  assert.match(link.url, /\/s\/[A-Za-z0-9]{12}$/);
});
await step("GET /api/share returns the snapshot exactly", async () => {
  const r = await go(`/api/share?id=${link.id}`);
  assert.equal(r.status, 200);
  assert.deepEqual((await r.json()).snapshot, space);
});
await step("GET /s/<id> shows it (rewrite to api/s)", async () => {
  const r = await go(`/s/${link.id}`);
  assert.equal(r.status, 200);
  const html = await r.text();
  assert.match(html, /Smoke test/);
  assert.match(html, new RegExp(`airc://share/${link.id}`));
  assert.match(r.headers.get("content-security-policy") ?? "", /default-src 'none'/);
});
await step("the fragment viewer /s still serves", async () => {
  const r = await go("/s");
  assert.equal(r.status, 200);
  assert.match(await r.text(), /Reading the link/);
});
await step("unsafe addresses are refused", async () => {
  for (const url of ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts"]) {
    const r = await go("/api/share", { method: "POST", body: { kind: "folder", name: "x", items: [{ type: "tab", url }] } });
    assert.equal(r.status, 422, url);
  }
});
await step("revoke needs the token; then the link 404s", async () => {
  assert.equal((await go(`/api/share?id=${link.id}`, { method: "DELETE", headers: { authorization: `Bearer ${"A".repeat(43)}` } })).status, 403);
  assert.equal((await go(`/api/share?id=${link.id}`, { method: "DELETE", headers: { authorization: `Bearer ${link.token}` } })).status, 204);
  assert.equal((await go(`/api/share?id=${link.id}`)).status, 404);
  assert.equal((await go(`/s/${link.id}`)).status, 404);
});

const note = `smoke test ${Date.now()}`;
const boost = {
  version: 2, name: "Smoke Boost", site: "example.com", createdAt: "2026-11-09T20:00:00Z",
  colors: { hue: 0.1, tint: 0.2, brightness: 1, contrast: 1, invert: false, saturation: 1 }, font: { size: 0 },
  zaps: [], css: "body { line-height: 1.6 !important; }", js: "", author: "Smoke", about: "A test Boost, removed right away.",
  id: crypto.randomUUID(), revision: 3,
  preview: Buffer.from("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489", "hex").toString("base64"),
};
let submitted;
await step("POST /api/boosts queues a submission; a refused one says why", async () => {
  const bad = await go("/api/boosts", { method: "POST", body: { ...boost, css: '@import "https://evil.example/x.css";' } });
  assert.equal(bad.status, 422);
  assert.match((await bad.json()).message, /another site/);
  const r = await go("/api/boosts", { method: "POST", body: boost });
  assert.equal(r.status, 202, await r.clone().text());
  submitted = (await r.json()).id;
  const list = await (await go("/api/boosts")).json();
  assert.ok(!list.boosts.some((e) => e.id === submitted), "not listed before approval");
});
await step("/admin/boosts asks for the password, then shows the queue", async () => {
  const anon = await go("/admin/boosts");
  assert.equal(anon.status, 401);
  const r = await go("/admin/boosts", { headers: admin });
  assert.equal(r.status, 200, "set SHARING_ADMIN_PASSWORD to the deployment's SHARING_ADMIN_SECRET");
  assert.match(await r.text(), /Smoke Boost/);
  const forged = await go("/admin/boosts", { method: "POST", body: `action=approve&id=${submitted}`, headers: { ...admin, origin: "https://evil.example", "content-type": "application/x-www-form-urlencoded" } });
  assert.equal(forged.status, 403);
});
await step("approve lists it, with an install link, the file and the preview", async () => {
  const host = new URL(base).host;
  const r = await go("/admin/boosts", { method: "POST", body: `action=approve&id=${submitted}`, headers: { ...admin, origin: `https://${host}`, "content-type": "application/x-www-form-urlencoded" } });
  assert.equal(r.status, 303);
  const e = (await (await go("/api/boosts")).json()).boosts.find((x) => x.id === submitted);
  assert.ok(e, "listed");
  assert.equal(e.revision, 3, "the entry says the file's revision (Airc offers Update for a later one)");
  const { preview: _p, ...file } = boost;
  assert.deepEqual(JSON.parse(inflateRawSync(Buffer.from(e.link.split("#1.")[1], "base64url")).toString()), file);
  assert.deepEqual(await (await go(`/api/boosts?id=${submitted}`)).json(), file);
  const img = await go(`/api/boosts?preview=${submitted}`);
  assert.equal(img.headers.get("content-type"), "image/png");
});
await step("report, then remove: gone from the list, its file 404s", async () => {
  assert.equal((await go(`/api/boosts?report=${submitted}`, { method: "POST", body: { reason: "other", note } })).status, 202);
  assert.ok((await (await go("/admin/boosts", { headers: admin })).text()).includes(note));
  const host = new URL(base).host;
  const r = await go("/admin/boosts", { method: "POST", body: `action=remove&id=${submitted}`, headers: { ...admin, origin: `https://${host}`, "content-type": "application/x-www-form-urlencoded" } });
  assert.equal(r.status, 303);
  assert.ok(!(await (await go("/api/boosts")).json()).boosts.some((x) => x.id === submitted));
  assert.equal((await go(`/api/boosts?id=${submitted}`)).status, 404);
  assert.ok(!(await (await go("/admin/boosts", { headers: admin })).text()).includes(note), "its report is gone too");
});
await step("the gallery page serves", async () => {
  const r = await go("/boosts");
  assert.equal(r.status, 200);
  assert.match(await r.text(), /Boost Gallery/);
});
console.log("all passed");
