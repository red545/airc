// Feedback end to end against a deployment (a Preview, or `vercel dev`), with its real store:
//   SHARING_ADMIN_PASSWORD=… [VERCEL_BYPASS=…] node scripts/feedback-smoke.mjs https://<deployment>
// VERCEL_BYPASS is the project's protection-bypass secret, for Previews behind Vercel Authentication. Everything it
// sends is deleted again from the admin page. A Preview keeps its records under its own prefix and never mails the
// owner (api/feedback.js mails from Production only). Never point it at Production: it refuses aircbrowser.com.
import assert from "node:assert/strict";

const base = (process.argv[2] ?? "").replace(/\/$/, "");
if (!/^https?:\/\//.test(base) || /aircbrowser\.com/.test(base)) throw new Error("usage: feedback-smoke.mjs <preview or dev URL> (not Production)");
const bypass = process.env.VERCEL_BYPASS ? { "x-vercel-protection-bypass": process.env.VERCEL_BYPASS } : {};
const admin = { authorization: `Basic ${Buffer.from(`owner:${process.env.SHARING_ADMIN_PASSWORD ?? ""}`).toString("base64")}` };
const go = (path, { method = "GET", body, headers = {} } = {}) =>
  fetch(base + path, { method, body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body), headers: { ...bypass, ...headers }, redirect: "manual" });
const post = (body) => go("/api/feedback", { method: "POST", body, headers: { "content-type": "application/json" } });
const act = (action, id) =>
  go("/admin/feedback", { method: "POST", body: `action=${action}&id=${id}`, headers: { ...admin, "content-type": "application/x-www-form-urlencoded", origin: base } });
const step = async (name, f) => {
  const t = Date.now();
  await f();
  console.log(`ok   ${name} (${Date.now() - t} ms)`);
};

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
const client = crypto.randomUUID();
const message = `Smoke test ${new Date().toISOString()}: the feedback service works.`;
const made = [];

try {
  await step("GET /api/feedback is 405", async () => {
    const r = await go("/api/feedback");
    assert.equal(r.status, 405);
    assert.equal(r.headers.get("allow"), "POST");
  });
  await step("a bad POST is 400/422/415, nothing stored", async () => {
    assert.equal((await post("{not json")).status, 400);
    assert.equal((await post({ version: 1, message: "" })).status, 422);
    assert.equal((await post({ version: 1, message: "x", url: "https://example.com" })).status, 422);
    assert.equal((await go("/api/feedback", { method: "POST", body: "message=x", headers: { "content-type": "text/plain" } })).status, 415);
  });
  let id;
  await step("POST /api/feedback stores it with its screenshot", async () => {
    const r = await post({ version: 1, message, email: "smoke@example.com", client,
      app: { version: "0.0.1", build: "1", engine: "webkit", macOS: "26.6", model: "Mac16,1", locale: "en" },
      screenshot: { type: "image/png", base64: PNG.toString("base64") } });
    assert.equal(r.status, 201, await r.clone().text());
    id = (await r.json()).id;
    made.push(id);
    assert.match(id, /^[A-Za-z0-9]{12}$/);
  });
  await step("a resend of the same message is the same entry", async () => {
    const r = await post({ version: 1, message, client });
    assert.equal(r.status, 200);
    assert.equal((await r.json()).id, id);
  });
  await step("/admin/feedback needs the password", async () => {
    assert.equal((await go("/admin/feedback")).status, 401);
    assert.equal((await go(`/admin/feedback?shot=${id}`)).status, 401);
  });
  await step("/admin/feedback lists it with its screenshot", async () => {
    const r = await go("/admin/feedback", { headers: admin });
    assert.equal(r.status, 200);
    const html = await r.text();
    assert.ok(html.includes(message), "the message is listed");
    assert.match(html, new RegExp(`/admin/feedback\\?shot=${id}`));
    const pic = await go(`/admin/feedback?shot=${id}`, { headers: admin });
    assert.equal(pic.status, 200);
    assert.equal(pic.headers.get("content-type"), "image/png");
    assert.deepEqual(Buffer.from(await pic.arrayBuffer()), PNG);
  });
  await step("pictures sent after the message: a 3.9 MB one too (under Vercel's 4.5 MB cap), metadata stripped", async () => {
    const { createHash } = await import("node:crypto");
    const sha = (b) => createHash("sha256").update(b).digest("hex");
    // A JPEG with an Exif segment, and a large PNG (a 3.9 MB private chunk the server keeps; a real file's size).
    const seg = (m, p) => Buffer.concat([Buffer.from([0xff, m, (p.length + 2) >> 8, (p.length + 2) & 0xff]), p]);
    const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8]), seg(0xe1, Buffer.from("Exif\0\0GPS 48.2 16.3")), seg(0xda, Buffer.from([1, 1, 0, 0, 0x3f, 0])),
      Buffer.from([1, 2, 3]), Buffer.from([0xff, 0xd9])]);
    const big = Buffer.alloc(3_900_000, 7);
    const chunk = Buffer.concat([Buffer.alloc(4), Buffer.from("prVt"), big, Buffer.alloc(4)]);
    chunk.writeUInt32BE(big.length, 0);
    const png = Buffer.concat([PNG.subarray(0, PNG.length - 12), chunk, PNG.subarray(PNG.length - 12)]);
    const pclient = crypto.randomUUID();
    const r = await post({ version: 1, message: message + " (pictures)", client: pclient, images: [
      { type: "image/jpeg", size: jpeg.length, sha256: sha(jpeg) }, { type: "image/png", size: png.length, sha256: sha(png) }] });
    assert.equal(r.status, 201, await r.clone().text());
    const { id: pid, missing } = await r.json();
    made.push(pid);
    assert.deepEqual(missing, [0, 1]);
    const auth = { authorization: `Bearer ${pclient}` };
    assert.equal((await go(`/api/feedback?id=${pid}&publish=1`, { method: "POST", headers: auth })).status, 409);
    for (const [n, b, type] of [[0, jpeg, "image/jpeg"], [1, png, "image/png"]]) {
      const u = await fetch(`${base}/api/feedback?id=${pid}&image=${n}`, { method: "PUT", body: b, headers: { ...bypass, ...auth, "content-type": type } });
      assert.equal(u.status, 204, `picture ${n}: ${u.status} ${await u.text()}`);
    }
    const pub = await go(`/api/feedback?id=${pid}&publish=1`, { method: "POST", headers: auth });
    assert.equal(pub.status, 200, await pub.clone().text());
    const html = await (await go("/admin/feedback", { headers: admin })).text();
    assert.ok(html.includes(`shot=${pid}&amp;n=1`), "both pictures listed");
    const stored = Buffer.from(await (await go(`/admin/feedback?shot=${pid}`, { headers: admin })).arrayBuffer());
    assert.ok(!stored.includes(Buffer.from("Exif")) && stored.subarray(-5).equals(Buffer.from([1, 2, 3, 0xff, 0xd9])), "Exif stripped, scan kept");
    const storedPNG = await go(`/admin/feedback?shot=${pid}&n=1`, { headers: admin });
    assert.equal(storedPNG.status, 200);
    assert.equal(Buffer.from(await storedPNG.arrayBuffer()).length, png.length);
  });
  await step("mark done, then reopen", async () => {
    assert.equal((await act("done", id)).status, 303);
    assert.match(await (await go("/admin/feedback", { headers: admin })).text(), new RegExp(`id="f-${id}">\\s*<h3>Done · `));
    assert.equal((await act("open", id)).status, 303);
  });
} finally {
  for (const id of made) {
    const r = await act("delete", id);
    console.log(r.status === 303 ? `ok   deleted ${id}` : `FAIL delete ${id}: ${r.status}`);
  }
}
await step("deleted: gone from the list and its picture 404s", async () => {
  for (const id of made) {
    assert.equal((await go(`/admin/feedback?shot=${id}`, { headers: admin })).status, 404);
    assert.equal((await go(`/admin/feedback?shot=${id}&n=1`, { headers: admin })).status, 404);
    assert.doesNotMatch(await (await go("/admin/feedback", { headers: admin })).text(), new RegExp(`f-${id}`));
  }
});
console.log("feedback smoke: all passed");
