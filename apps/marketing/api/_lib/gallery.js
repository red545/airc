// The Boost gallery's records (B03; docs/dev/sharing-service.md), in the sharing store:
//   boosts/pending/<id>.json   a submission waiting for the owner: the file as it would be published, its preview, notes
//   boosts/index.json          what the gallery lists: one entry per approved Boost, newest first
//   boosts/files/<id>.json     an approved Boost's file (Airc's Boost file, without its preview)
//   boosts/previews/<id>       its preview picture (PNG or JPEG), if it has one
//   boosts/reports/<id>.json   a report about an approved Boost, until the owner dismisses it or removes the Boost
// Nothing records who sent or reported anything.
import { deflateRawSync } from "node:zlib";
import { SITE } from "./http.js";
import { getJSON, update } from "./store.js";

/** @typedef {import("./store.js").Store} Store */
/** @typedef {{ id: string, fileID: string | null, name: string, site: string, author: string | null, about: string | null,
 *   code: boolean, preview: boolean, link: string | null, approvedAt: string, revision?: number | null }} Entry */
/** @typedef {{ id: string, submittedAt: string, notes: string[], file: Record<string, any>,
 *   preview: { type: string, base64: string } | null }} Pending */
/** @typedef {{ id: string, boost: string, reason: string, note: string | null, at: string }} Report */

export const INDEX = "boosts/index.json";
/** @param {string} id */
export const pendingKey = (id) => `boosts/pending/${id}.json`;
/** @param {string} id */
export const fileKey = (id) => `boosts/files/${id}.json`;
/** @param {string} id */
export const previewKey = (id) => `boosts/previews/${id}`;
/** @param {string} id */
export const reportKey = (id) => `boosts/reports/${id}.json`;

export const REASONS = { broken: "It doesn't work", harmful: "It's harmful or deceptive", spam: "Spam or a copy", other: "Something else" };

/** The Boost link Airc installs from (BoostLink: https://aircbrowser.com/boost#1.<deflated file>), or null when the
 *  file is too large for a link (Airc then fetches the file). @param {string} published */
export function boostLink(published) {
  const url = `${SITE}/boost#1.${deflateRawSync(Buffer.from(published, "utf8"), { level: 9 }).toString("base64url")}`;
  return url.length <= 8000 ? url : null;
}

/** @param {Store} s @returns {Promise<Entry[]>} */
export async function entries(s) {
  const r = await getJSON(s, INDEX);
  return r ? r.value.entries ?? [] : [];
}

/** @param {Store} s @returns {Promise<Pending[]>} */
export async function pending(s) {
  const keys = (await s.list("boosts/pending/")).sort((a, b) => +a.uploadedAt - +b.uploadedAt);
  const out = await Promise.all(keys.map(async (k) => (await getJSON(s, k.key))?.value));
  return out.filter(Boolean);
}

/** @param {Store} s @returns {Promise<Report[]>} */
export async function reports(s) {
  const keys = await s.list("boosts/reports/");
  const out = await Promise.all(keys.map(async (k) => (await getJSON(s, k.key))?.value));
  return out.filter(Boolean).sort((a, b) => a.at.localeCompare(b.at));
}

/** Publishes a submission: its file and preview, then its entry (replacing an earlier revision of the same Boost, by
 *  its file id), then the submission is gone. @param {Store} s @param {string} id */
export async function approve(s, id) {
  const r = await getJSON(s, pendingKey(id));
  if (!r) return false;
  /** @type {Pending} */
  const p = r.value;
  const published = JSON.stringify(p.file);
  await s.put(fileKey(id), published, { overwrite: true });
  if (p.preview) await s.put(previewKey(id), Buffer.from(p.preview.base64, "base64"), { overwrite: true, contentType: p.preview.type });
  const f = p.file;
  /** @type {Entry} */
  const entry = {
    id,
    fileID: typeof f.id === "string" ? f.id : null,
    name: f.name.trim(),
    site: f.site,
    author: typeof f.author === "string" ? f.author.trim() : null,
    about: typeof f.about === "string" ? f.about.trim() : null,
    code: f.js.trim() !== "",
    preview: !!p.preview,
    link: boostLink(published),
    approvedAt: new Date().toISOString(),
    // Airc offers Update, not Review, when this is a later revision of the Boost someone installed (entries listed
    // before this field existed have none, and Airc offers Review for them).
    revision: Number.isInteger(f.revision) ? f.revision : null,
  };
  /** @type {Entry[]} */
  let replaced = [];
  await update(s, INDEX, (/** @type {{ entries: Entry[] } | null} */ old) => {
    const list = old?.entries ?? [];
    replaced = list.filter((e) => e.id === id || (entry.fileID && e.fileID === entry.fileID));
    return { entries: [entry, ...list.filter((e) => !replaced.includes(e))] };
  });
  for (const e of replaced) if (e.id !== id) await dropFiles(s, e.id);
  await s.del(pendingKey(id));
  return true;
}

/** Takes a Boost out of the gallery, with its files and its reports. @param {Store} s @param {string} id */
export async function remove(s, id) {
  await update(s, INDEX, (/** @type {{ entries: Entry[] } | null} */ old) => ({ entries: (old?.entries ?? []).filter((e) => e.id !== id) }));
  await dropFiles(s, id);
  const mine = (await reports(s)).filter((r) => r.boost === id).map((r) => reportKey(r.id));
  await s.del(mine);
}

/** @param {Store} s @param {string} id */
async function dropFiles(s, id) {
  await s.del([fileKey(id), previewKey(id)]);
}
