// Hosted Easel links (P19c, Arc's Easel sharing; docs/dev/sharing-service.md, "Easel links"): a read-only snapshot of
// an Easel at https://aircbrowser.com/e/<id>, next to the Space and folder links of api/share.js, with the same rules:
// no accounts, a token whose SHA-256 alone is stored, the same Blob store, retries and rate limits.
//   POST   /api/easel                     the Easel (easel-core.js) → 201 { id, url, token, missing: [picture names] }
//   PUT    /api/easel?id=<id>&asset=<name>   Bearer token, the picture's bytes → 204 (its name is the SHA-256 of them)
//   POST   /api/easel?id=<id>&publish=1   Bearer token → 200 { id, url } once every picture is there; the link works from then on
//   GET    /api/easel?id=<id>             → 200 { id, createdAt, easel } | 404 (not published yet, taken back, never was)
//   DELETE /api/easel?id=<id>             Bearer token → 204; the page and its pictures 404 from then on
// A link whose pictures never all arrived stays unpublished and is swept a day later (api/sweep.js).
import { assetTypes, decodeEasel, EaselRefused, easelMessages, MAX_ASSET_BYTES, MAX_EASEL_JSON, sniff } from "../src/lib/easel-core.js";
import { guarded, ID, json, newID, newToken, origin, problem, readBytes, readText, sameSecret, sha256 } from "./_lib/http.js";
import { limit } from "./_lib/rate.js";
import { Conflict, getJSON, store } from "./_lib/store.js";
import { createHash } from "node:crypto";

/** @param {string} id */
export const easelKey = (id) => `easels/${id}.json`;
/** @param {string} id @param {string} [name] */
export const easelAssetKey = (id, name = "") => `easels/${id}/${name}`;

const notFound = () => problem(404, "notFound", "This link was taken back, or it never existed.");

/** The Bearer token of a request, if it has one of the right form. @param {Request} request */
const bearer = (request) => /^Bearer ([A-Za-z0-9_-]{20,100})$/.exec(request.headers.get("authorization") ?? "")?.[1];

/** The record of `id` when `request` carries its token: `{ record }`, or `{ answer }` to send instead.
 *  @param {import("./_lib/store.js").Store} s @param {Request} request @param {string} id */
async function owned(s, request, id) {
  if (!ID.test(id)) return { answer: notFound() };
  const r = await getJSON(s, easelKey(id));
  if (!r) return { answer: notFound() };
  const token = bearer(request);
  if (!token || !sameSecret(sha256(token), String(r.value.tokenHash))) {
    return { answer: problem(403, "forbidden", "Only the copy of Airc that made this link can change it or take it back.") };
  }
  return { record: r };
}

/** @param {Request} request */
export function POST(request) {
  return guarded(async () => {
    const url = new URL(request.url);
    const s = await store();
    if (url.searchParams.get("publish") === "1") return publish(s, request, url.searchParams.get("id") ?? "");
    const limited = await limit(s, request, "share");
    if (limited) return limited;
    const text = await readText(request, MAX_EASEL_JSON);
    let easel;
    try {
      easel = decodeEasel(text);
    } catch (e) {
      if (e instanceof EaselRefused) return problem(e.why === "tooLarge" ? 413 : 422, e.why, easelMessages[e.why]);
      throw e;
    }
    const { token, hash } = newToken();
    const record = { version: 1, createdAt: new Date().toISOString(), tokenHash: hash, published: easel.assets.length === 0, easel };
    for (let i = 0; i < 3; i++) {
      const id = newID();
      try {
        await s.put(easelKey(id), JSON.stringify(record));
        return json({ id, url: `${origin(request)}/e/${id}`, token, missing: easel.assets.map((a) => a.name) }, 201);
      } catch (e) {
        if (!(e instanceof Conflict)) throw e;
      }
    }
    throw new Conflict("easel id");
  });
}

/** One picture of an unpublished link: exactly the bytes its name and size promise, of the type its name says.
 *  @param {Request} request */
export function PUT(request) {
  return guarded(async () => {
    const q = new URL(request.url).searchParams;
    const s = await store();
    const limited = await limit(s, request, "asset");
    if (limited) return limited;
    const id = q.get("id") ?? "";
    const o = await owned(s, request, id);
    if (o.answer) return o.answer;
    const r = /** @type {{ value: any, etag: string }} */ (o.record);
    if (r.value.published) return problem(409, "published", "This link is published already; share the Easel again to change it.");
    const name = q.get("asset") ?? "";
    const listed = /** @type {{ name: string, size: number }[]} */ (r.value.easel.assets).find((a) => a.name === name);
    if (!listed) return problem(422, "damaged", "This picture isn't on the shared Easel.");
    const bytes = await readBytes(request, MAX_ASSET_BYTES);
    const ext = /** @type {keyof typeof assetTypes} */ (name.split(".")[1]);
    if (bytes.byteLength !== listed.size || createHash("sha256").update(bytes).digest("hex") !== name.split(".")[0] || sniff(bytes) !== ext) {
      return problem(422, "damaged", "This picture didn't arrive whole. Try sharing again.");
    }
    // The same bytes under the same name: a retry overwrites with what's already there.
    await s.put(easelAssetKey(id, name), bytes, { overwrite: true, contentType: assetTypes[ext] });
    return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  });
}

/** @param {import("./_lib/store.js").Store} s @param {Request} request @param {string} id */
async function publish(s, request, id) {
  const o = await owned(s, request, id);
  if (o.answer) return o.answer;
  const r = /** @type {{ value: any, etag: string }} */ (o.record);
  if (!r.value.published) {
    const have = new Set((await s.list(easelAssetKey(id))).map((b) => b.key.slice(easelAssetKey(id).length)));
    const missing = /** @type {{ name: string }[]} */ (r.value.easel.assets).map((a) => a.name).filter((n) => !have.has(n));
    if (missing.length) return json({ error: "incomplete", message: "Some pictures haven't arrived yet.", missing }, 409);
    await s.put(easelKey(id), JSON.stringify({ ...r.value, published: true }), { ifMatch: r.etag });
  }
  return json({ id, url: `${origin(request)}/e/${id}` });
}

/** @param {Request} request */
export function GET(request) {
  return guarded(async () => {
    const id = new URL(request.url).searchParams.get("id") ?? "";
    const r = ID.test(id) ? await readEasel(id) : null;
    if (!r) return notFound();
    return json({ id, createdAt: r.createdAt, easel: r.easel });
  });
}

/** @param {Request} request */
export function DELETE(request) {
  return guarded(async () => {
    const s = await store();
    const limited = await limit(s, request, "revoke");
    if (limited) return limited;
    const id = new URL(request.url).searchParams.get("id") ?? "";
    const o = await owned(s, request, id);
    if (o.answer) return o.answer;
    // The record first: from this moment the page and every picture are 404s, whatever happens to the rest.
    await s.del(easelKey(id));
    const pictures = (await s.list(easelAssetKey(id))).map((b) => b.key);
    if (pictures.length) await s.del(pictures);
    return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  });
}

/** A published link's Easel, checked again on the way out (a damaged record never reaches a viewer), or null.
 *  @param {string} id */
export async function readEasel(id) {
  const s = await store();
  const r = await getJSON(s, easelKey(id));
  if (!r || r.value.published !== true) return null;
  try {
    return { createdAt: String(r.value.createdAt), easel: decodeEasel(JSON.stringify(r.value.easel)) };
  } catch {
    return null;
  }
}

/** A published link's picture, or null. @param {string} id @param {string} name */
export async function readEaselAsset(id, name) {
  const e = await readEasel(id);
  if (!e || !e.easel.assets.some((a) => a.name === name)) return null;
  const s = await store();
  return s.getBytes(easelAssetKey(id, name));
}
