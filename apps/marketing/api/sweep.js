// Daily at 03:17 UTC (vercel.json "crons"): deletes the rate-limit counters of every hour but the current one (most are
// gone already: rate.js deletes a visitor's last hour on their next request), and submissions the owner hasn't
// reviewed in 30 days, feedback's resend markers older than that, feedback whose pictures never all arrived within a day, and Easel links whose pictures never all arrived within a day (api/easel.js). Vercel's cron sends CRON_SECRET as a bearer token when it's set; anyone else gets 401.
import { guarded, json, problem, sameSecret } from "./_lib/http.js";
import { sweep } from "./_lib/rate.js";
import { getJSON, store } from "./_lib/store.js";
import { easelAssetKey, easelKey } from "./easel.js";
import { entryKey, picturesOf } from "./_lib/feedback.js";

export const STALE_DAYS = 30;

/** @param {Request} request */
export function GET(request) {
  return guarded(async () => {
    const secret = process.env.CRON_SECRET;
    if (secret && !sameSecret(request.headers.get("authorization") ?? "", `Bearer ${secret}`)) return problem(401, "unauthorized", "Not for you.");
    const s = await store();
    const counters = await sweep(s);
    const cutoff = Date.now() - STALE_DAYS * 86_400_000;
    const stale = (await s.list("boosts/pending/")).filter((b) => +b.uploadedAt < cutoff).map((b) => b.key);
    await s.del(stale);
    const unfinished = await sweepUnpublishedEasels(s);
    // Feedback's resend markers (api/feedback.js) only matter while a queued message may still be retried.
    const markers = (await s.list("feedback/clients/")).filter((b) => +b.uploadedAt < cutoff).map((b) => b.key);
    await s.del(markers);
    const feedbackUnfinished = await sweepUnfinishedFeedback(s);
    return json({ counters, submissions: stale.length, easels: unfinished, feedbackMarkers: markers.length, feedbackUnfinished });
  });
}

export const UNPUBLISHED_HOURS = 24;

/** Feedback whose pictures never all arrived (api/feedback.js) a day after it was sent: the entry, the pictures that
 *  came, and its resend marker. Never a published entry. @param {import("./_lib/store.js").Store} s */
export async function sweepUnfinishedFeedback(s) {
  const cutoff = Date.now() - UNPUBLISHED_HOURS * 3_600_000;
  let swept = 0;
  for (const b of await s.list("feedback/entries/")) {
    if (+b.uploadedAt >= cutoff) continue;
    const id = b.key.slice("feedback/entries/".length, -".json".length);
    const r = await getJSON(s, entryKey(id));
    if (!r || r.value.pending !== true) continue;
    const arrived = (await s.list(`feedback/images/${id}/`)).map((x) => x.key);
    await s.del([...new Set([entryKey(id), ...picturesOf(r.value).map((p) => p.key), ...arrived, ...(r.value.client ? [r.value.client] : [])])]);
    swept++;
  }
  return swept;
}

/** Easel links never published (their pictures didn't all arrive) a day after they were made: the record and whatever
 *  pictures came. @param {import("./_lib/store.js").Store} s */
export async function sweepUnpublishedEasels(s) {
  const cutoff = Date.now() - UNPUBLISHED_HOURS * 3_600_000;
  const records = (await s.list("easels/")).filter((b) => /^easels\/[A-Za-z0-9]{12}\.json$/.test(b.key) && +b.uploadedAt < cutoff);
  let swept = 0;
  for (const b of records) {
    const id = b.key.slice("easels/".length, -".json".length);
    const r = await getJSON(s, easelKey(id));
    if (!r || r.value.published === true) continue;
    await s.del(easelKey(id));
    const pictures = (await s.list(easelAssetKey(id))).map((x) => x.key);
    if (pictures.length) await s.del(pictures);
    swept++;
  }
  return swept;
}
