// Hosted share links for Spaces and folders (H01, H02; docs/dev/sharing-service.md).
//   POST   /api/share            the snapshot JSON (docs/dev/share-links.md, kind "space" or "folder")
//                                → 201 { id, url, token }: the link https://aircbrowser.com/s/<id>, and the secret that
//                                revokes it (Airc keeps it in the Keychain; only its hash is stored here)
//   GET    /api/share?id=<id>    → 200 { id, createdAt, snapshot } | 404
//   DELETE /api/share?id=<id>    with "Authorization: Bearer <token>" → 204; the link 404s from then on
// A snapshot is checked exactly as Airc and the viewer check one (share-core.js): titles and http(s) addresses only;
// anything else refuses it whole. Nothing about the person sharing it is stored: no account, no address, no name.
import { decodeSnapshot, MAX_JSON, messages, Refused, treeJSON } from "../src/lib/share-core.js";
import { guarded, ID, json, newID, newToken, origin, problem, readText, sameSecret, sha256 } from "./_lib/http.js";
import { limit } from "./_lib/rate.js";
import { Conflict, getJSON, store } from "./_lib/store.js";

/** @param {string} id */
export const shareKey = (id) => `shares/${id}.json`;

/** @param {Request} request */
export function POST(request) {
  return guarded(async () => {
    const s = await store();
    const limited = await limit(s, request, "share");
    if (limited) return limited;
    const text = await readText(request, MAX_JSON);
    let snapshot;
    try {
      snapshot = decodeSnapshot(text);
    } catch (e) {
      if (e instanceof Refused) return problem(e.why === "tooLarge" ? 413 : 422, e.why, messages[e.why]);
      throw e;
    }
    if (snapshot.kind === "boost") return problem(422, "damaged", "Boosts are shared through the Boost Gallery or a Boost link.");
    const { token, hash } = newToken();
    const record = { version: 1, createdAt: new Date().toISOString(), tokenHash: hash, snapshot: treeJSON(snapshot) };
    for (let i = 0; i < 3; i++) {
      const id = newID();
      try {
        await s.put(shareKey(id), JSON.stringify(record));
        return json({ id, url: `${origin(request)}/s/${id}`, token }, 201);
      } catch (e) {
        if (!(e instanceof Conflict)) throw e;
      }
    }
    throw new Conflict("share id");
  });
}

/** @param {Request} request */
export function GET(request) {
  return guarded(async () => {
    const id = new URL(request.url).searchParams.get("id") ?? "";
    const r = ID.test(id) ? await readShare(id) : null;
    if (!r) return problem(404, "notFound", "This link was taken back, or it never existed.");
    // The snapshot exactly as Airc reads it (strict keys): without the viewer's counts.
    return json({ id, createdAt: r.createdAt, snapshot: treeJSON(r.snapshot) });
  });
}

/** @param {Request} request */
export function DELETE(request) {
  return guarded(async () => {
    const s = await store();
    const limited = await limit(s, request, "revoke");
    if (limited) return limited;
    const id = new URL(request.url).searchParams.get("id") ?? "";
    const token = /^Bearer ([A-Za-z0-9_-]{20,100})$/.exec(request.headers.get("authorization") ?? "")?.[1];
    if (!ID.test(id)) return problem(404, "notFound", "This link was taken back, or it never existed.");
    const r = await getJSON(s, shareKey(id));
    if (!r) return problem(404, "notFound", "This link was taken back, or it never existed.");
    if (!token || !sameSecret(sha256(token), String(r.value.tokenHash))) {
      return problem(403, "forbidden", "Only the copy of Airc that made this link can take it back.");
    }
    await s.del(shareKey(id));
    return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  });
}

/** The stored share, checked again on the way out (so a damaged record never reaches a viewer), or null.
 *  @param {string} id */
export async function readShare(id) {
  const s = await store();
  const r = await getJSON(s, shareKey(id));
  if (!r) return null;
  try {
    const snapshot = decodeSnapshot(JSON.stringify(r.value.snapshot));
    if (snapshot.kind === "boost") return null;
    return { createdAt: String(r.value.createdAt), snapshot };
  } catch {
    return null;
  }
}
