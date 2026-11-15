// The Boost gallery's public side (B03; docs/dev/sharing-service.md).
//   GET  /api/boosts                → { boosts: Entry[] }: the approved Boosts, newest first (gallery/_lib.js Entry)
//   GET  /api/boosts?id=<id>        → the Boost's file (Airc's Boost file v2, no preview) | 404
//   GET  /api/boosts?preview=<id>   → its preview picture | 404
//   POST /api/boosts                the Boost file (with an optional preview) → 202 { id, status: "pending" }, or 422
//                                   with why the static review refused it. The owner approves it before it's listed.
//   POST /api/boosts?report=<id>    { reason, note? } → 202. The owner sees reports on the admin page.
import { guarded, ID, json, newID, problem, readText } from "./_lib/http.js";
import { MAX_FILE, MAX_PREVIEW, Rejected, reviewBoost } from "./_lib/boost-review.js";
import { entries, fileKey, pendingKey, previewKey, REASONS, reportKey } from "./_lib/gallery.js";
import { limit } from "./_lib/rate.js";
import { store } from "./_lib/store.js";

/** Submissions waiting at most, from everyone together: past it, new ones wait until the owner catches up. */
export const MAX_QUEUE = 200;
// Cached at the edge for a minute: a removed Boost is gone from every answer within about two.
const LISTED = { "Cache-Control": "public, max-age=60, s-maxage=60, stale-while-revalidate=60" };

/** @param {Request} request */
export function GET(request) {
  return guarded(async () => {
    const q = new URL(request.url).searchParams;
    const s = await store();
    const id = q.get("id"), preview = q.get("preview");
    if (id !== null || preview !== null) {
      const which = /** @type {string} */ (id ?? preview);
      if (!ID.test(which) || !(await entries(s)).some((e) => e.id === which)) return problem(404, "notFound", "This Boost isn't in the gallery.");
      if (id !== null) {
        const r = await s.get(fileKey(which));
        if (!r) return problem(404, "notFound", "This Boost isn't in the gallery.");
        return new Response(r.text, {
          headers: { "Content-Type": "application/json; charset=utf-8", "X-Content-Type-Options": "nosniff", ...LISTED },
        });
      }
      const img = await s.getBytes(previewKey(which));
      if (!img || !/^image\/(png|jpeg)$/.test(img.contentType)) return problem(404, "notFound", "This Boost has no preview.");
      return new Response(img.bytes, {
        headers: {
          "Content-Type": img.contentType,
          "X-Content-Type-Options": "nosniff",
          "Content-Security-Policy": "default-src 'none'; sandbox",
          ...LISTED,
        },
      });
    }
    return json({ boosts: await entries(s) }, 200, LISTED);
  });
}

/** @param {Request} request */
export function POST(request) {
  return guarded(async () => {
    const report = new URL(request.url).searchParams.get("report");
    const s = await store();
    if (report !== null) {
      const limited = await limit(s, request, "report");
      if (limited) return limited;
      if (!ID.test(report) || !(await entries(s)).some((e) => e.id === report)) return problem(404, "notFound", "This Boost isn't in the gallery.");
      /** @type {any} */
      let body;
      try {
        body = JSON.parse(await readText(request, 4096));
      } catch {
        return problem(400, "damaged", "Send { reason, note }.");
      }
      const reason = body?.reason;
      if (typeof reason !== "string" || !(reason in REASONS)) return problem(422, "reason", `The reason must be one of: ${Object.keys(REASONS).join(", ")}.`);
      const note = typeof body.note === "string" ? body.note.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ").trim().slice(0, 300) : "";
      const rid = newID();
      await s.put(reportKey(rid), JSON.stringify({ id: rid, boost: report, reason, note: note || null, at: new Date().toISOString() }));
      return json({ status: "received", message: "Thanks. The report goes to whoever runs the gallery." }, 202);
    }

    const limited = await limit(s, request, "submit");
    if (limited) return limited;
    if ((await s.list("boosts/pending/")).length >= MAX_QUEUE) {
      return problem(503, "queueFull", "The gallery has too many Boosts waiting for review. Try again in a few days.", { "Retry-After": "86400" });
    }
    const text = await readText(request, MAX_FILE + Math.ceil(MAX_PREVIEW / 3) * 4 + 1024);
    let reviewed;
    try {
      reviewed = reviewBoost(text);
    } catch (e) {
      if (e instanceof Rejected) return problem(422, "rejected", e.message);
      throw e;
    }
    const id = newID();
    const record = {
      id,
      submittedAt: new Date().toISOString(),
      notes: reviewed.notes,
      file: reviewed.file,
      preview: reviewed.preview ? { type: reviewed.preview.type, base64: reviewed.preview.bytes.toString("base64") } : null,
    };
    await s.put(pendingKey(id), JSON.stringify(record));
    return json({ id, status: "pending", message: "Sent. It's listed in the gallery once it's been reviewed." }, 202);
  });
}
