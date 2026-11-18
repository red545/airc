// Feedback from Airc (Help › Send Feedback…; docs/dev/feedback-service.md), and the owner's list of it.
//   POST /api/feedback               JSON (api/_lib/feedback.js decodeFeedback) → 201 { id, missing }; a resend of the
//                                    same message (its "client" id) → 200 { id, duplicate: true, missing }
//   PUT  /api/feedback?id=<id>&image=<n>   Bearer <client id>, picture n's bytes as listed in the message → 204
//   POST /api/feedback?id=<id>&publish=1   Bearer <client id> → 200 { id } once every picture is there; only then
//                                    does the entry show on the admin page (and mail the owner). `missing` lists the
//                                    pictures still to send; a message without pictures is published at once.
//   GET  /api/feedback               → 405: nothing is ever read back from here
//   GET  /admin/feedback             the owner's list (vercel.json rewrites it to ?view=admin), behind the same
//                                    sign-in as /admin/boosts (api/_lib/admin-gate.js); ?shot=<id> is an entry's picture
//   POST /admin/feedback             action=done|open|delete&id=<entry>, from that page only (Origin)
// Each entry is a record in the sharing store (api/_lib/store.js) under feedback/, with a random id; its picture is a
// file of its own. The owner gets an email per entry (Production only). Requests count per visitor like sharing's.
// A message whose pictures never all arrived is swept a day later (api/sweep.js).
import { gate, sameOrigin } from "./_lib/admin-gate.js";
import {
  clientKey, decodeFeedback, entryHTML, entryKey, imageKey, imageType, Invalid, MAX_BODY, MAX_IMAGE, notify, picturesOf, shotKey,
  stripMetadata,
} from "./_lib/feedback.js";
import { guarded, ID, json, newID, problem, readBytes, readText, sameSecret, sha256 } from "./_lib/http.js";
import { page } from "./_lib/page.js";
import { limit } from "./_lib/rate.js";
import { Conflict, getJSON, store, update } from "./_lib/store.js";

const PATH = "/admin/feedback";
/** The newest entries the list shows. */
export const LIST_MAX = 300;

/** @param {Request} request */
const isAdmin = (request) => new URL(request.url).searchParams.get("view") === "admin";

const notAllowed = () =>
  new Response(JSON.stringify({ error: "method", message: "Send feedback from Airc: Help › Send Feedback…" }), {
    status: 405,
    headers: { Allow: "POST", "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

/** @param {Request} request */
export function POST(request) {
  if (isAdmin(request)) return adminAction(request);
  return new URL(request.url).searchParams.get("publish") === "1" ? publishRequest(request) : submit(request);
}

/** @param {Request} request */
export function PUT(request) {
  return isAdmin(request) ? Promise.resolve(notAllowed()) : upload(request);
}

/** The pictures of `e` not stored yet, by number. @param {import("./_lib/store.js").Store} s @param {any} e */
async function missingOf(s, e) {
  if (!e.pending) return [];
  const have = new Set((await s.list(`feedback/images/${e.id}/`)).map((b) => b.key));
  return /** @type {any[]} */ (e.images ?? []).map((_, n) => n).filter((n) => !have.has(e.images[n].key));
}

/** The pending entry `id` when `request` carries its message's id: `{ entry, etag }`, or `{ answer }` to send instead.
 *  @param {import("./_lib/store.js").Store} s @param {Request} request @param {string} id */
async function owned(s, request, id) {
  const none = { answer: problem(404, "notFound", "No such message.") };
  if (!ID.test(id)) return none;
  const r = await getJSON(s, entryKey(id));
  if (!r) return none;
  const token = /^Bearer ([A-Za-z0-9-]{16,64})$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!token || !r.value.client || !sameSecret(clientKey(token), String(r.value.client))) {
    return { answer: problem(403, "forbidden", "Only the copy of Airc that sent this message can add its pictures.") };
  }
  return { entry: r.value, etag: r.etag };
}

/** One picture of a message, as it listed it. @param {Request} request */
function upload(request) {
  return guarded(async () => {
    const q = new URL(request.url).searchParams;
    const s = await store();
    const limited = await limit(s, request, "feedbackImage");
    if (limited) return limited;
    const o = await owned(s, request, q.get("id") ?? "");
    if (o.answer) return o.answer;
    const e = o.entry;
    const n = /^[0-4]$/.test(q.get("image") ?? "") ? Number(q.get("image")) : -1;
    const listed = Array.isArray(e.images) ? e.images[n] : undefined;
    if (!listed) return problem(404, "notFound", "This message has no such picture.");
    if (!e.pending) return new Response(null, { status: 204 });
    const type = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
    if (type !== listed.type) return problem(415, "type", "Send the picture with the type the message gave it.");
    const bytes = await readBytes(request, MAX_IMAGE);
    if (bytes.length !== listed.size || sha256(bytes) !== listed.sha256) {
      return problem(422, "invalid", "This picture isn't the one the message listed.");
    }
    if (imageType(bytes) !== listed.type) return problem(422, "invalid", "The picture isn't the type it says it is.");
    let clean;
    try {
      clean = stripMetadata(bytes, listed.type);
    } catch (x) {
      if (x instanceof Invalid) return problem(422, "invalid", x.message);
      throw x;
    }
    await s.put(listed.key, clean, { overwrite: true, contentType: listed.type });
    return new Response(null, { status: 204 });
  });
}

/** Shows a message once its pictures are all there. @param {import("./_lib/store.js").Store} s @param {any} e */
async function publish(s, e) {
  if (!e.pending) return null;
  const missing = await missingOf(s, e);
  if (missing.length) return missing;
  const done = await update(s, entryKey(e.id), (old) => ({ ...(old ?? e), pending: false }));
  if (process.env.VERCEL_ENV === "production") await notify(done ?? { ...e, pending: false });
  return null;
}

/** @param {Request} request */
function publishRequest(request) {
  return guarded(async () => {
    const s = await store();
    const o = await owned(s, request, new URL(request.url).searchParams.get("id") ?? "");
    if (o.answer) return o.answer;
    const missing = await publish(s, o.entry);
    if (missing) return json({ error: "missing", message: "Some pictures haven't arrived yet.", missing }, 409);
    return json({ id: o.entry.id }, 200);
  });
}

/** @param {Request} request */
export function GET(request) {
  return isAdmin(request) ? adminPage(request) : Promise.resolve(notAllowed());
}

/** @param {Request} request */
function submit(request) {
  return guarded(async () => {
    const type = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
    if (type !== "application/json") return problem(415, "type", "Feedback is sent as JSON.");
    const s = await store();
    const limited = await limit(s, request, "feedback");
    if (limited) return limited;
    let f;
    try {
      f = decodeFeedback(await readText(request, MAX_BODY));
    } catch (e) {
      if (e instanceof Invalid) return problem(e.message === "This isn't valid JSON." ? 400 : 422, "invalid", e.message);
      throw e;
    }
    if (f.client) {
      const seen = await getJSON(s, clientKey(f.client));
      if (seen) {
        const e = (await getJSON(s, entryKey(seen.value.id)))?.value;
        return json({ id: seen.value.id, duplicate: true, missing: e ? await missingOf(s, e) : [] }, 200);
      }
    }
    for (let i = 0; i < 3; i++) {
      const id = newID();
      const shot = f.shot ? shotKey(id, f.shot.type) : null;
      const images = f.images.map((i, n) => ({ key: imageKey(id, n, i.type), type: i.type, size: i.size, sha256: i.sha256 }));
      const entry = {
        version: 1, id, receivedAt: new Date().toISOString(), writtenAt: f.writtenAt,
        message: f.message, email: f.email, app: f.app, shot, shotType: f.shot?.type ?? null, images,
        client: f.client ? clientKey(f.client) : null, done: false, pending: images.length > 0,
      };
      // The picture first, so an entry never names a picture that isn't there.
      try {
        if (f.shot && shot) await s.put(shot, f.shot.bytes, { contentType: f.shot.type });
        await s.put(entryKey(id), JSON.stringify(entry));
      } catch (e) {
        if (!(e instanceof Conflict)) throw e;
        if (shot) await s.del(shot).catch(() => {});
        continue;
      }
      if (f.client) {
        try {
          await s.put(clientKey(f.client), JSON.stringify({ id }));
        } catch (e) {
          if (!(e instanceof Conflict)) throw e;
        }
      }
      if (!entry.pending && process.env.VERCEL_ENV === "production") await notify(entry);
      return json({ id, missing: images.map((_, n) => n) }, 201);
    }
    throw new Conflict("feedback id");
  });
}

/** Every entry, newest first. @param {import("./_lib/store.js").Store} s */
export async function entries(s) {
  const listed = (await s.list("feedback/entries/")).sort((a, b) => +b.uploadedAt - +a.uploadedAt).slice(0, LIST_MAX);
  const out = await Promise.all(listed.map(async (b) => (await getJSON(s, b.key))?.value ?? null));
  return out.filter(Boolean).sort((a, b) => String(b.receivedAt).localeCompare(String(a.receivedAt)));
}

/** @param {Request} request */
function adminPage(request) {
  return guarded(async () => {
    const closed = await gate(request);
    if (closed) return closed;
    const s = await store();
    const q = new URL(request.url).searchParams;
    const shotID = q.get("shot");
    if (shotID !== null) {
      const e = ID.test(shotID) ? (await getJSON(s, entryKey(shotID)))?.value : null;
      const n = /^[0-9]$/.test(q.get("n") ?? "0") ? Number(q.get("n") ?? "0") : -1;
      const pic = e ? picturesOf(e)[n] : undefined;
      const r = pic ? await s.getBytes(pic.key) : null;
      if (!r || !pic) return problem(404, "notFound", "No such picture.");
      return new Response(Buffer.from(r.bytes), {
        headers: {
          "Content-Type": pic.type,
          "Cache-Control": "private, no-store",
          "X-Content-Type-Options": "nosniff",
          "Content-Security-Policy": "default-src 'none'",
        },
      });
    }
    // A message whose pictures are still arriving isn't shown yet.
    const all = (await entries(s)).filter((e) => !e.pending);
    const open = all.filter((e) => !e.done), done = all.filter((e) => e.done);
    const body = `<p class="tag">Feedback · admin</p>
<h1>Feedback <span>${open.length} open, ${done.length} done.</span></h1>
<p class="lede">Sent from Airc with Help › Send Feedback…. Each one has only what its sender typed and chose to add.
Delete what you've dealt with, and anything someone asks you to delete.</p>
<h2>Open</h2>${open.map((e) => entryHTML(e, PATH)).join("") || `<p class="lede">Nothing open.</p>`}
<h2>Done</h2>${done.map((e) => entryHTML(e, PATH)).join("") || `<p class="lede">Nothing here.</p>`}`;
    return page({ title: "Feedback · Airc", body, wide: true });
  });
}

/** @param {Request} request */
function adminAction(request) {
  return guarded(async () => {
    const closed = await gate(request);
    if (closed) return closed;
    if (!sameOrigin(request)) return problem(403, "origin", "Actions only come from the admin page itself.");
    const form = new URLSearchParams(await readText(request, 4096));
    const action = form.get("action") ?? "", id = form.get("id") ?? "";
    if (!ID.test(id)) return problem(400, "damaged", "No such entry.");
    const s = await store();
    const r = await getJSON(s, entryKey(id));
    if (!r) return problem(404, "notFound", "No such entry.");
    if (action === "done" || action === "open") {
      await update(s, entryKey(id), (old) => ({ ...(old ?? r.value), done: action === "done" }));
    } else if (action === "delete") {
      await s.del([entryKey(id), ...picturesOf(r.value).map((p) => p.key), ...(r.value.client ? [r.value.client] : [])]);
    } else return problem(400, "damaged", "No such action.");
    return new Response(null, { status: 303, headers: { Location: `${PATH}${action === "delete" ? "" : `#f-${id}`}`, "Cache-Control": "no-store" } });
  });
}
