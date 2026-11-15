// A hosted share link's page, https://aircbrowser.com/s/<id> (vercel.json rewrites it here): the shared Space or
// folder, rendered on the server as text. "Add to Airc" opens airc://share/<id>, where Airc fetches the same snapshot
// and shows its import preview. A link that was taken back, or never existed, is a 404.
import { addresses, hostOf } from "../src/lib/share-core.js";
import { guarded, ID } from "./_lib/http.js";
import { esc, page } from "./_lib/page.js";
import { readShare } from "./share.js";

/** @typedef {import("../src/lib/share-core.js").Node} Node */

const COPY = `document.querySelector("[data-copy]").addEventListener("click",async e=>{const b=e.currentTarget,t=[...document.querySelectorAll(".tree a.t")].map(a=>a.href).join("\\n");try{await navigator.clipboard.writeText(t)}catch{return}const o=b.textContent;b.textContent="Copied";setTimeout(()=>b.textContent=o,2200)});`;

/** @param {number} n @param {string} one @param {string} many */
const plural = (n, one, many) => `${n.toLocaleString("en-US")} ${n === 1 ? one : many}`;

/** @param {string} url @param {string} [title] */
function tab(url, title) {
  const host = hostOf(url);
  const mark = (host.replace(/^www\./, "")[0] ?? "·").toUpperCase();
  return `<a class="t" href="${esc(url)}" target="_blank" rel="noopener noreferrer nofollow" title="${esc(url)}">` +
    `<span class="t-mark">${esc(mark)}</span><span class="t-title">${esc(title ?? host)}</span>` +
    (title ? `<span class="t-host">${esc(host)}</span>` : "") + `</a>`;
}

/** @param {Node[]} nodes @returns {string} */
function tree(nodes) {
  return nodes.map((n) => {
    if (n.type === "tab") return `<li class="tab">${tab(n.url, n.title)}</li>`;
    if (n.type === "folder") {
      const inner = n.items.length ? tree(n.items) : `<li class="empty">Empty</li>`;
      return `<li class="folder"><div class="f-name">${esc(n.name)}</div><ul>${inner}</ul></li>`;
    }
    return `<li class="split ${n.axis}"><span class="s-label">${n.axis === "vertical" ? "Split, stacked" : "Split"}</span>` +
      `<div class="s-row">${n.items.map((t) => tab(t.url, t.title)).join("")}</div></li>`;
  }).join("");
}

export const gone = () =>
  page({
    status: 404,
    title: "Link not found · Airc",
    body: `<p class="tag gone">Shared from Airc</p>
<h1>This link was taken back, or it never existed.</h1>
<p class="lede">Whoever shared it can share it again from Airc and send you the new link.</p>
<p class="foot"><a href="/">What's Airc?</a></p>`,
  });

/** @param {Request} request */
export function GET(request) {
  return guarded(async () => {
    const id = new URL(request.url).searchParams.get("id") ?? "";
    const r = ID.test(id) ? await readShare(id) : null;
    if (!r || r.snapshot.kind === "boost") return gone();
    const s = r.snapshot;
    const when = new Date(r.createdAt).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" });
    const count = `${plural(s.tabs, "tab", "tabs")}${s.folders ? ` in ${plural(s.folders, "folder", "folders")}` : ""}`;
    const body = `<p class="tag">${s.kind === "space" ? "Shared Space" : "Shared folder"}</p>
<h1>${esc(`${s.icon ? `${s.icon} ` : ""}${s.name}`)} <span>${esc(count)}.</span></h1>
<p class="actions">
<a class="btn-open" href="airc://share/${esc(id)}">Add to Airc</a>
<button type="button" class="btn-quiet" data-copy>Copy all ${esc(plural(addresses(s.items).length, "link", "links"))}</button>
<a class="btn-quiet" href="/">Get Airc</a>
</p>
<p class="snap">A snapshot shared on ${esc(when)}: later changes don't reach it. Only titles and addresses are in it, and
whoever shared it can take the link back.</p>
<ul class="tree">${tree(s.items)}</ul>
<p class="foot">Add to Airc shows what it holds before anything is added. <a href="/">What's Airc?</a></p>`;
    return page({ title: `${s.name} · Shared from Airc`, body, script: COPY });
  });
}
