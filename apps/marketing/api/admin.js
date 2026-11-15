// The gallery's review queue, for the owner only: https://aircbrowser.com/admin/boosts (vercel.json rewrites it here).
// The browser asks for a password (HTTP Basic; any user name): it's SHARING_ADMIN_SECRET, a Vercel environment
// variable that's never in the repository. Without it set, the page is closed (503). Failed sign-ins count against
// the visitor's rate limit, and actions must come from this page itself (Origin), so another site can't trigger them.
//   GET  → the queue: each submission with everything the static review found, its preview, CSS and JavaScript;
//          then the reports, then what's listed
//   POST action=approve|reject&id=<submission>, action=remove&id=<listed Boost>, action=dismiss&id=<report>
import { gate } from "./_lib/admin-gate.js";
import { esc, guarded, ID, problem, readText } from "./_lib/http.js";
import { approve, entries, pending, pendingKey, REASONS, remove, reportKey, reports } from "./_lib/gallery.js";
import { page } from "./_lib/page.js";
import { store } from "./_lib/store.js";

const PATH = "/admin/boosts";

/** @param {Request} request */
export function GET(request) {
  return guarded(async () => {
    const closed = await gate(request);
    if (closed) return closed;
    const s = await store();
    const [queue, reported, listed] = await Promise.all([pending(s), reports(s), entries(s)]);
    const names = new Map(listed.map((e) => [e.id, e]));
    /** @param {string} action @param {string} id @param {string} label @param {string} [cls] */
    const button = (action, id, label, cls = "btn-quiet") =>
      `<form method="post" action="${PATH}"><input type="hidden" name="action" value="${action}"><input type="hidden" name="id" value="${esc(id)}"><button class="${cls}">${label}</button></form>`;

    const submissions = queue.map((p) => {
      const f = p.file;
      const updates = listed.find((e) => f.id && e.fileID === f.id);
      const zaps = Array.isArray(f.zaps) && f.zaps.length ? `<p class="meta">Zaps (hidden on the page): ${f.zaps.map((/** @type {any} */ z) => esc(z.selector)).join(", ")}</p>` : "";
      const settings = `colors ${esc(JSON.stringify(f.colors))}, font ${esc(JSON.stringify(f.font))}${f.scriptHost ? `, code on ${esc(f.scriptHost)} only` : ""}`;
      return `<div class="item">
<h3>${esc(f.name)} <span class="meta">for ${esc(f.site)}</span></h3>
<p class="meta">Sent ${esc(p.submittedAt)} · by “${esc(f.author ?? "no name")}” (not verified)${updates ? ` · replaces “${esc(updates.name)}” when approved` : ""}</p>
${f.about ? `<p class="lede">${esc(f.about)}</p>` : ""}
${p.notes.length ? `<p class="notes">Look closely: ${p.notes.map(esc).join("; ")}.</p>` : ""}
${p.preview ? `<img alt="Preview" src="data:${esc(p.preview.type)};base64,${esc(p.preview.base64)}">` : ""}
<p class="meta">${settings}</p>${zaps}
${f.css.trim() ? `<pre aria-label="CSS">${esc(f.css)}</pre>` : ""}
${f.js.trim() ? `<pre aria-label="JavaScript">${esc(f.js)}</pre>` : ""}
<p class="actions">${button("approve", p.id, "Approve and list it", "btn-open")}${button("reject", p.id, "Reject (delete it)", "btn-quiet danger")}</p>
</div>`;
    }).join("");

    const reportRows = reported.map((r) => {
      const e = names.get(r.boost);
      return `<div class="item"><h3>${esc(REASONS[/** @type {keyof typeof REASONS} */ (r.reason)] ?? r.reason)}: ${esc(e ? `${e.name} (${e.site})` : r.boost)}</h3>
<p class="meta">${esc(r.at)}${r.note ? ` · “${esc(r.note)}”` : ""}</p>
<p class="actions">${e ? button("remove", e.id, "Remove the Boost", "btn-quiet danger") : ""}${button("dismiss", r.id, "Dismiss the report")}</p></div>`;
    }).join("");

    const listedRows = listed.map((e) =>
      `<div class="item"><h3>${esc(e.name)} <span class="meta">for ${esc(e.site)}</span></h3>
<p class="meta">Listed ${esc(e.approvedAt)}${e.code ? " · has JavaScript" : ""}${e.link ? "" : " · too large for a link"}</p>
<p class="actions">${button("remove", e.id, "Remove from the gallery", "btn-quiet danger")}</p></div>`).join("");

    const body = `<p class="tag">Boost gallery · admin</p>
<h1>Review queue <span>${queue.length} waiting, ${reported.length} ${reported.length === 1 ? "report" : "reports"}, ${listed.length} listed.</span></h1>
<p class="lede">Every Boost here passed the static review (Airc's file rules, no loads from other sites, no packed code).
Approve only what you've read: a Boost changes every page of its site for whoever installs it.</p>
<h2>Waiting for review</h2>${submissions || `<p class="lede">Nothing waiting.</p>`}
<h2>Reports</h2>${reportRows || `<p class="lede">No reports.</p>`}
<h2>Listed in the gallery</h2>${listedRows || `<p class="lede">Nothing listed yet.</p>`}`;
    return page({ title: "Gallery review · Airc", body, wide: true, images: true });
  });
}

/** @param {Request} request */
export function POST(request) {
  return guarded(async () => {
    const closed = await gate(request);
    if (closed) return closed;
    const host = request.headers.get("host");
    const from = request.headers.get("origin");
    if (!from || !host || URL.parse(from)?.host !== host) return problem(403, "origin", "Actions only come from the admin page itself.");
    const form = new URLSearchParams(await readText(request, 4096));
    const action = form.get("action") ?? "", id = form.get("id") ?? "";
    if (!ID.test(id)) return problem(400, "damaged", "No such item.");
    const s = await store();
    if (action === "approve") await approve(s, id);
    else if (action === "reject") await s.del(pendingKey(id));
    else if (action === "remove") await remove(s, id);
    else if (action === "dismiss") await s.del(reportKey(id));
    else return problem(400, "damaged", "No such action.");
    return new Response(null, { status: 303, headers: { Location: PATH, "Cache-Control": "no-store" } });
  });
}
