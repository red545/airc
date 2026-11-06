// Copies the marketing screenshots the site uses from assets/screenshots/ (the real app on a synthetic demo setup,
// made by scripts/marketing-shots.sh; see its README) into src/assets/screens/. It runs before every build. Vercel only
// receives apps/marketing, so there the source folder is absent and the committed copies are used; commit them
// whenever the shots are refreshed.
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { createRequire } from "node:module";

const sharp = createRequire(import.meta.url)("sharp");

// Crops: a part of a shot on its own, with its own rounded corners (measured in the 2400 px shot). Re-made whenever
// the source shot is newer than the crop.
const crops = [
  // Site Controls on Spotify: just the panel with the "Safari's engine" switch, none of the page behind it.
  { from: "drm-site-controls", to: "drm-site-controls-panel", box: { left: 138, top: 228, width: 446, height: 678 }, radius: 24 },
];

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
  "boosts", // Boosts: Colors
  "boosts-font",
  "boosts-zap",
  "settings-privacy", // the privacy page
  "settings-privacy-events",
];

const src = new URL("../../../assets/screenshots/", import.meta.url);
const dst = new URL("../src/assets/screens/", import.meta.url);
mkdirSync(dst, { recursive: true });

let copied = 0;
for (const name of used) {
  const from = new URL(`${name}.webp`, src);
  const to = new URL(`${name}.webp`, dst);
  if (existsSync(from)) {
    if (!existsSync(to) || !readFileSync(from).equals(readFileSync(to))) {
      copyFileSync(from, to);
      copied++;
    }
  } else if (!existsSync(to)) {
    console.error(`screenshots: ${name}.webp is in neither assets/screenshots nor src/assets/screens`);
    process.exit(1);
  }
}
for (const c of crops) {
  const from = new URL(`${c.from}.webp`, src);
  const to = new URL(`${c.to}.webp`, dst);
  if (!existsSync(from)) {
    if (existsSync(to)) continue;
    console.error(`screenshots: ${c.from}.webp is missing, so ${c.to}.webp can't be made`);
    process.exit(1);
  }
  if (existsSync(to) && statSync(to).mtimeMs >= statSync(from).mtimeMs) continue;
  const { width, height } = c.box;
  const mask = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"><rect width="${width}" height="${height}" rx="${c.radius}" fill="#fff"/></svg>`,
  );
  const part = await sharp(new URL(`${c.from}.webp`, src).pathname).extract(c.box).ensureAlpha().png().toBuffer();
  await sharp(part).composite([{ input: mask, blend: "dest-in" }]).webp({ quality: 94, alphaQuality: 100 }).toFile(to.pathname);
  copied++;
}

console.log(copied ? `screenshots: copied ${copied}` : "screenshots: up to date");
