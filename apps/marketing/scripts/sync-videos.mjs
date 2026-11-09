// Copies the social studio's feature videos (artifacts/social/web/<id>/: <id>.mp4, poster.jpg, meta.json; frames
// Airc rendered itself with `--script social`, no screen recording) into public/video/<id>.mp4 and <id>.jpg, and their
// meta into src/data/videos.json, for the /features/<id> pages. <id> is a group id in src/data/catalog.ts, or a single
// feature's video placed on its group's page by `placement`. It runs
// before every build; Vercel only receives apps/marketing, so there the source is absent and the committed copies are
// used: commit them. Set AIRC_SOCIAL_WEB to read another folder.
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const src = process.env.AIRC_SOCIAL_WEB ?? new URL("../../../../artifacts/social/web/", import.meta.url).pathname;
const pub = new URL("../public/video/", import.meta.url).pathname;
const data = new URL("../src/data/videos.json", import.meta.url).pathname;

// Where a loop goes when its id isn't a group's: a group's own loop under another name (no `feature`), or one feature's
// loop on its group's page, under that feature (its title in src/data/catalog.ts). A loop that's neither is left out.
const placement = {
  "developer-mode": { group: "developer" },
  "split-view": { group: "split" },
  "select-tabs": { group: "sidebar", feature: "Select several tabs" },
  "sidebar-right": { group: "sidebar", feature: "Sidebar on the right" },
  "site-previews": { group: "sidebar", feature: "Site previews" },
  "site-search": { group: "command", feature: "Site Search" },
  "private-windows": { group: "privacy", feature: "Private windows" },
  "space-colours": { group: "boosts", feature: "Pages in your Space's colours" },
  "developer-mode-toolbar": { group: "developer", feature: "Network and clearing data" },
  "capture-full-page": { group: "capture", feature: "Capture Full Page" },
  "capture-portrait": { group: "capture", feature: "Portrait Mode" },
};
const catalog = readFileSync(new URL("../src/data/catalog.ts", import.meta.url), "utf8");
const groupIds = new Set([...catalog.matchAll(/^    id: "([a-z-]+)",$/gm)].map((m) => m[1]));

// Kept off the site, with why. Drop a name once its video is fixed.
const held = new Map([
  // (Empty: the sidebar swipe and site previews were re-rendered on clean pages, 2026-11-09.)
]);

if (!existsSync(src)) {
  console.log("videos: no artifacts/social/web here, using the committed copies");
  process.exit(0);
}

mkdirSync(pub, { recursive: true });
const videos = existsSync(data) ? JSON.parse(readFileSync(data, "utf8")) : {};
let copied = 0;
const same = (a, b) => existsSync(b) && readFileSync(a).equals(readFileSync(b));
for (const id of readdirSync(src).sort()) {
  const dir = `${src}/${id}`;
  if (!existsSync(`${dir}/meta.json`) || !existsSync(`${dir}/${id}.mp4`) || !existsSync(`${dir}/poster.jpg`)) continue;
  if (held.has(id)) {
    console.log(`videos: holding ${id}: ${held.get(id)}`);
    continue;
  }
  if (!groupIds.has(id) && !placement[id]) {
    console.log(`videos: ${id} has no page (not a group, not in placement); left out`);
    continue;
  }
  const meta = JSON.parse(readFileSync(`${dir}/meta.json`, "utf8"));
  for (const [from, to] of [[`${dir}/${id}.mp4`, `${pub}${id}.mp4`], [`${dir}/poster.jpg`, `${pub}${id}.jpg`]]) {
    if (!same(from, to)) {
      copyFileSync(from, to);
      copied++;
    }
  }
  const { title, line, alt, since, released, width, height, seconds } = meta;
  videos[id] = { title, line, alt, since, released: released === true, width, height, seconds, ...placement[id] };
}
// A held video leaves the site too, if an earlier sync had copied it.
for (const id of held.keys()) {
  delete videos[id];
  rmSync(`${pub}${id}.mp4`, { force: true });
  rmSync(`${pub}${id}.jpg`, { force: true });
}
writeFileSync(data, `${JSON.stringify(videos, null, 2)}\n`);
console.log(copied ? `videos: copied ${copied} file(s); ${Object.keys(videos).join(", ")}` : "videos: up to date");
