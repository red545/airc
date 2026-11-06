// Turns the rendered shots (.shots/png, 2880 × 1800) into WebP masters in src/assets/shots.
// Astro makes the responsive sizes from these at build time.
import { mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const app = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = join(app, ".shots/png");
const out = join(app, "src/assets/shots");
mkdirSync(out, { recursive: true });

const webp = { quality: 84, effort: 6, smartSubsample: true };

for (const file of readdirSync(src).filter((f) => f.endsWith(".png"))) {
  const name = file.replace(/\.png$/, "");
  await sharp(join(src, file)).webp(webp).toFile(join(out, `${name}.webp`));
  console.log(`${name}.webp`);
}

// The sidebar alone (228 pt, the left edge of the window), for the sidebar section.
for (const name of ["space-personal"]) {
  await sharp(join(src, `${name}.png`))
    .extract({ left: 0, top: 0, width: 456, height: 1800 })
    .webp({ ...webp, quality: 88 })
    .toFile(join(out, `${name.replace("space", "sidebar")}.webp`));
  console.log(`${name.replace("space", "sidebar")}.webp`);
}
