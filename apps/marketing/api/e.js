// A shared Easel's page, https://aircbrowser.com/e/<id> (vercel.json rewrites it here), and its pictures,
// /e/<id>/a/<sha256>.<ext>: the Easel's blocks rendered on the server as HTML (easel-page.js), read-only. No scripts;
// pictures only from this site, served with a fixed type. A link that was taken back, or never published, is a 404.
// "Add to Airc" (P19d) opens airc://easel/<id>, where Airc fetches the same Easel and pictures, checks them, and shows
// what it holds before adding a copy of its own (as Space links do with airc://share/<id>).
import { assetTypes, ASSET, easelTitle } from "../src/lib/easel-core.js";
import { BOARD_CSS, board } from "./_lib/easel-page.js";
import { guarded, ID } from "./_lib/http.js";
import { esc, page } from "./_lib/page.js";
import { readEasel, readEaselAsset } from "./easel.js";
import { gone } from "./s.js";

/** @param {number} n @param {string} one @param {string} many */
const plural = (n, one, many) => `${n.toLocaleString("en-US")} ${n === 1 ? one : many}`;

/** @param {Request} request */
export function GET(request) {
  return guarded(async () => {
    const q = new URL(request.url).searchParams;
    const id = q.get("id") ?? "";
    const name = q.get("asset");
    if (name !== null) {
      const ext = /** @type {keyof typeof assetTypes} */ (name.split(".")[1]);
      const bytes = ID.test(id) && ASSET.test(name) ? await readEaselAsset(id, name) : null;
      if (!bytes) return new Response("Not found", { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
      return new Response(bytes.bytes, {
        headers: {
          "Content-Type": assetTypes[ext],
          "X-Content-Type-Options": "nosniff",
          "Content-Security-Policy": "default-src 'none'; sandbox",
          "Cross-Origin-Resource-Policy": "same-origin",
          // Not kept by shared caches: a link taken back stops showing its pictures at once.
          "Cache-Control": "private, max-age=300",
        },
      });
    }
    const r = ID.test(id) ? await readEasel(id) : null;
    if (!r) return gone();
    const e = r.easel;
    const when = new Date(r.createdAt).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" });
    const body = `<p class="tag">Shared Easel</p>
<h1>${esc(easelTitle(e))} <span>${esc(plural(e.blocks.length, "item", "items"))}.</span></h1>
<p class="actions">
<a class="btn-open" href="airc://easel/${esc(id)}">Add to Airc</a>
<a class="btn-quiet" href="/">Get Airc</a>
</p>
<p class="snap">A snapshot shared from Airc on ${esc(when)}: later changes don't reach it, and whoever shared it can take
the link back. Links open in a new tab.</p>
${board(e, (a) => `/e/${id}/a/${a}`)}
<p class="foot">Add to Airc shows the Easel before it's added, as a copy of your own. Easels are Airc's whiteboards for the web.
<a href="/">What's Airc?</a></p>`;
    return page({ title: `${easelTitle(e)} · Shared from Airc`, body, wide: true, css: BOARD_CSS });
  });
}
