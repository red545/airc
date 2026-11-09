// Copies the marketing screenshots the site uses from assets/screenshots/ (the real app on a synthetic demo setup,
// made by scripts/marketing-shots.sh; see its README) into src/assets/screens/, and makes the crops. It runs before
// every build. Vercel only receives apps/marketing, so there the history is absent and the committed copies are used;
// commit them whenever they change.
//
// The site shows only what's released, so the shots come from git, not the working tree: a released feature's shot as
// of the source of the newest published release (its notes in src/content/changelog end with "Source: `<commit>`"),
// and a next-release feature's (`upcoming`) as of HEAD. A shot retaken since the release waits for the next one by
// itself, and nobody's uncommitted shot reaches the site.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";

const sharp = createRequire(import.meta.url)("sharp");

const used = [
  "media-controls", // Spaces demo: Personal (Mint), on Wikivoyage
  "split-view-3", // Spaces demo: Travel (Sky), and Split View
  "pinned-split", // Spaces demo: Studio (Peach)
  "hero-dark", // Spaces demo: Work (Grape, dark)
  "spaces", // Colours: four Spaces, four colours; also the social card
  "profiles",
  "command-bar-light",
  "command-bar-dark",
  "onboarding-import",
  "peek",
  "split-view-2",
  "picture-in-picture",
  "settings-privacy", // the privacy page
  "settings-privacy-events",
  // /features
  "sidebar-right",
  "multiple-windows",
  "copy-quote",
  "show-toolbar",
  "remembered-profiles",
  "settings-links",
  "favorite-split",
  "private-window",
  "onboarding-import-browsers",
  "arc-import-checklist",
  "boosts",
  "boosts-font",
  "boosts-zap",
  "boost-import",
  "developer-mode",
  "developer-mode-dark",
  "capture",
  "notes", // /features only, since "next": production shows it once that release is published
  "boosts-gallery", // the same, for Boosts at Arc parity (22e48ba)
  "boosts-share",
  "boosts-review",
  "command-bar-site-search", // the same, for Site Search (6d81e1a)
  "settings-site-search",
  "sidebar-files", // the same, for files dropped on the sidebar (2a24413)
  "quote-link", // the same, for a link to copied text and Help's shortcuts (3d8fde4)
  "essential-shortcuts",
  "notes-split", // the same, for New Note in Split (758a4d6)
  "theme-palette", // the same, for Space colors on pages (34b19d4)
  "theme-palette-dark",
  "arc-import-logins", // the same, for Arc import's results (693f747)
  "capture-full-page", // the same, for Capture Full Page (56314d3)
  "capture-portrait", // the same, for Capture in Portrait Mode (9bff2dc)
  "developer-mode-site-controls", // the same, for Developer Mode per site (80d0c28)
  "library-media",
  "library-recent",
  "downloads-library",
  "settings-shortcuts",
  "settings-app-icon", // the same, for the app icon choice (f742f48)
];

// The next release's shots, shown on /features as "next" (and the crops made from them): taken from HEAD.
// (0.1.3's own shots, Notes, Site Search, Boosts' gallery and the rest, now come from its source like any released shot.)
const upcoming = new Set([
  "capture-portrait", "developer-mode-site-controls",
  "update-whats-new", "update-playing", "settings-app-icon"]);

// Crops: the part of a shot that shows the feature, without the page behind it when that page is someone else's
// artwork (Apple's product page, Spotify's covers). Boxes are in the 2400 px shot; each crop gets its own rounded
// corners. Re-made whenever the source shot is newer than the crop.
const crops = [
  { from: "archive-library", to: "archive-library-panel", box: { left: 126, top: 95, width: 620, height: 600 }, radius: 22 },
  { from: "manage-spaces", to: "manage-spaces-card", box: { left: 917, top: 466, width: 888, height: 548 }, radius: 22 },
  { from: "little-arc", to: "little-arc-window", box: { left: 877, top: 421, width: 1253, height: 913 }, radius: 26 },
  // A Favorite split's own icon (Change Icon…, after 0.1.2: /features shows it from the next release): the sidebar's
  // Favorites only, leaving out the Linear and Apple Developer pages in the split.
  { from: "favorite-split-icon", to: "favorite-split-icon-card", box: { left: 126, top: 96, width: 336, height: 350 }, radius: 18 },
  // Arc's tab and folder menus (P01a, after 0.1.2: "next" on /features): the sidebar and the menu, not the Apple page.
  { from: "tab-menu", to: "tab-menu-card", box: { left: 126, top: 832, width: 515, height: 536 }, radius: 18 },
  { from: "folder-markdown", to: "folder-markdown-card", box: { left: 126, top: 380, width: 555, height: 375 }, radius: 18 },
  // Developer Mode's new toolbar (80d0c28): the sidebar's top from the retaken developer-mode, whose released copy the
  // 0.1.2 rows keep. `next` takes the source from HEAD.
  { from: "developer-mode", to: "developer-mode-toolbar-card", box: { left: 126, top: 96, width: 448, height: 250 }, radius: 18, next: true },
  // Extensions in the toolbar (aee6132, "next"): the toolbar's top right and ⌘E's list, not the linear.app page.
  { from: "toolbar-extensions", to: "toolbar-extensions-card", box: { left: 1806, top: 110, width: 464, height: 345 }, radius: 18 },
  // Site previews (10c6a8f, "next"): the Favorites and the Linear card, not the Apple Developer page behind them.
  { from: "site-preview", to: "site-preview-card", box: { left: 126, top: 236, width: 720, height: 462 }, radius: 18, next: true },
  // Little Arc's Open In menu (3dc145b, after 0.1.2: /features shows it from the next release), same window, same box.
  { from: "little-arc-menu", to: "little-arc-menu-window", box: { left: 877, top: 421, width: 1253, height: 913 }, radius: 26 },
  { from: "tab-preview", to: "tab-preview-card", box: { left: 125, top: 770, width: 780, height: 470 }, radius: 18 },
  { from: "multi-select", to: "multi-select-menu", box: { left: 126, top: 822, width: 522, height: 470 }, radius: 18 },
  { from: "calendar", to: "calendar-card", box: { left: 472, top: 230, width: 406, height: 264 }, radius: 22 },
  { from: "drm-site-controls", to: "drm-site-controls-panel", box: { left: 138, top: 228, width: 446, height: 678 }, radius: 24 },
  { from: "site-controls", to: "site-controls-panel", box: { left: 138, top: 228, width: 440, height: 790 }, radius: 24 },
  // The homepage's 0.1.2 cells: the Boost panel over the page it changed (one box, three states) and the top of Site
  // Controls on Spotify (Safari's engine on). Square: the cell's card rounds the top itself. (Capture plays the real
  // motion instead: scripts/make-motion.mjs.)
  { from: "boosts", to: "boosts-card", box: { left: 1300, top: 122, width: 925, height: 724 }, radius: 0 },
  { from: "boosts-font", to: "boosts-font-card", box: { left: 1300, top: 122, width: 925, height: 724 }, radius: 0 },
  { from: "boosts-zap", to: "boosts-zap-card", box: { left: 1300, top: 122, width: 925, height: 724 }, radius: 0 },
  // Updates that wait and See What's New (f742f48, "next"): the sidebar's foot with the update and its menu or its
  // question, not the Apple page behind them.
  { from: "update-whats-new", to: "update-whats-new-card", box: { left: 126, top: 1290, width: 560, height: 144 }, radius: 18 },
  { from: "update-playing", to: "update-playing-card", box: { left: 126, top: 900, width: 340, height: 534 }, radius: 18 },
  { from: "drm-site-controls", to: "drm-site-controls-top", box: { left: 138, top: 228, width: 446, height: 330 }, radius: 24 },
];

const repo = new URL("../../../", import.meta.url).pathname;
const dst = new URL("../src/assets/screens/", import.meta.url).pathname;
const notesDir = new URL("../src/content/changelog/", import.meta.url).pathname;
mkdirSync(dst, { recursive: true });

const git = (args) => execFileSync("git", args, { cwd: repo, stdio: ["ignore", "pipe", "ignore"], maxBuffer: 64 << 20 });
const semver = (v) => v.split(".").map(Number);
const newer = (a, b) => { const [x, y] = [semver(a), semver(b)]; for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return y[i] - x[i]; return 0; };
const release = readdirSync(notesDir)
  .filter((f) => /^\d+\.\d+\.\d+\.md$/.test(f))
  .map((f) => ({ version: f.slice(0, -3), source: readFileSync(notesDir + f, "utf8").match(/^Source: `([0-9a-f]{7,40})`/m)?.[1] }))
  .filter((r) => r.source)
  .sort((a, b) => newer(a.version, b.version))[0];
try {
  if (!release) throw new Error("no published notes");
  git(["rev-parse", "--verify", "--quiet", `${release.source}^{commit}`]);
} catch {
  console.log("screenshots: no history here, using the committed copies");
  process.exit(0);
}

// A shot as the site should show it, or null if that version of the repo doesn't have it.
const shot = (name, next = upcoming.has(name)) => {
  try {
    return git(["show", `${next ? "HEAD" : release.source}:assets/screenshots/${name}.webp`]);
  } catch {
    return null;
  }
};
const missing = (name, to) => {
  if (existsSync(to)) return console.log(`screenshots: ${name}.webp isn't in ${upcoming.has(name) ? "HEAD" : release.version}; keeping the committed copy`);
  console.error(`screenshots: ${name}.webp is in neither ${upcoming.has(name) ? "HEAD" : release.version} nor src/assets/screens`);
  process.exit(1);
};
const write = (to, bytes) => {
  if (existsSync(to) && readFileSync(to).equals(bytes)) return 0;
  writeFileSync(to, bytes);
  return 1;
};

let copied = 0;
for (const name of used) {
  const bytes = shot(name);
  const to = `${dst}${name}.webp`;
  if (!bytes) missing(name, to);
  else copied += write(to, bytes);
}

for (const c of crops) {
  const bytes = shot(c.from, c.next || upcoming.has(c.from));
  const to = `${dst}${c.to}.webp`;
  if (!bytes) {
    missing(c.from, to);
    continue;
  }
  const { width, height } = c.box;
  const mask = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"><rect width="${width}" height="${height}" rx="${c.radius}" fill="#fff"/></svg>`,
  );
  const part = await sharp(bytes).extract(c.box).ensureAlpha().png().toBuffer();
  copied += write(to, await sharp(part).composite([{ input: mask, blend: "dest-in" }]).webp({ quality: 94, alphaQuality: 100 }).toBuffer());
}

console.log(`screenshots: released shots as of ${release.version} (${release.source.slice(0, 7)}), next-release shots as of HEAD: ${copied ? `${copied} updated` : "up to date"}`);
